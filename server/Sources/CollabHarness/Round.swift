import CollabClientKit
import CollabCore
import CollabInvariants
import CollabStore
import Foundation
import Logging
import PostgresNIO

public struct FaultSpec: Codable, Sendable {
    public var serverKills = false
    public var clientKills = false
    public var clientPauses = false
    public var dbCuts = false
    public var networkCuts = false
    public var duplicatePostRate = 0.0
    public var replayOldRate = 0.0
    /// Seconds between server kills / client kills (random in the range).
    public var serverKillEverySec: [Int] = [4, 8]
    public var clientFaultEverySec: [Int] = [2, 5]
    public init() {}
    public var any: Bool { serverKills || clientKills || clientPauses || dbCuts || networkCuts || duplicatePostRate > 0 }
}

public struct RoundSpec: Codable, Sendable {
    public var name: String
    public var plan: PlanKind
    public var clients: Int
    public var clientsPerWorker: Int
    public var durationSec: Int
    public var editMinMs: Int
    public var editMaxMs: Int
    public var profile: NetworkProfile
    public var faults: FaultSpec
    public var timings: ClientTimings
    public var pingSeconds: Int
    public var seed: UInt64
    /// Distinguishes concurrently running rounds (ports).
    public var slot: Int
    public var volatileFraction: Double
    public var workDir: String
    /// Settle budget after the editing window.
    public var settleSec = 90
}

public struct ServerMetrics: Codable, Sendable {
    public var avgCpuPercent = 0.0
    public var peakCpuPercent = 0.0
    public var peakRssMB = 0.0
    public var samples = 0
}

public struct RoundResult: Codable, Sendable {
    public var spec: RoundSpec
    public var report: CheckReport
    public var server = ServerMetrics()
    public var injected: [String: Int] = [:]
    public var wallSeconds = 0.0
    public var notes: [String] = []
    public var passed: Bool { report.passed && notes.allSatisfy { !$0.hasPrefix("FAIL") } }
}

/// Runs one round end to end with real processes: Postgres (external), server, fault proxies, client workers,
/// fault injection, then settles and checks everything against the database and every client.
public final class RoundRunner: @unchecked Sendable {
    let spec: RoundSpec
    let env: HarnessEnv
    let toxi: Toxiproxy?
    var notes: [String] = []
    var diagStore: PostgresStore?
    // Everything that must be torn down however the round ends.
    var liveServer: ServerProcess?
    var liveWorkers: [WorkerHandle] = []
    var liveProxies: [String] = []
    var injected: [String: Int] = [:]
    let lock = NSLock()

    public init(spec: RoundSpec, env: HarnessEnv, toxi: Toxiproxy?) {
        self.spec = spec
        self.env = env
        self.toxi = toxi
    }

    private func bump(_ k: String) { lock.lock(); injected[k, default: 0] += 1; lock.unlock() }
    private func note(_ s: String) { lock.lock(); notes.append(s); lock.unlock() }

    public func run() async -> RoundResult {
        let started = ContinuousClock.now
        let dir = spec.workDir
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var result = RoundResult(spec: spec, report: CheckReport())
        do {
            result = try await execute()
        } catch {
            note("FAIL harness error: \(error)")
            result.notes = notes
            result.report.violations.append("HARNESS: \(error)")
            await cleanup()
        }
        result.wallSeconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
        return result
    }

    /// Kills whatever is still running (error paths) so that a failed round cannot poison the next one in the same slot.
    private func cleanup() async {
        for w in liveWorkers { w.kill9() }
        liveServer?.kill9()
        if let toxi { for p in liveProxies { await toxi.deleteProxy(p) } }
        if spec.profile.usesNetem, Netem.available { Netem.clear(device: env.netemDevice) }
    }

    private func execute() async throws -> RoundResult {
        let dir = spec.workDir
        let docId = "r-\(spec.name)-\(UInt32.random(in: 0...UInt32.max))".lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let serverPort = 18100 + spec.slot
        let useProxy = toxi != nil

        // --- database + seed document
        var logger = Logger(label: "harness")
        logger.logLevel = .error
        var pgConfig = PostgresClient.Configuration(host: env.dbHost, port: env.dbPort, username: env.dbUser, password: env.dbPassword,
                                                    database: env.dbName, tls: .disable)
        pgConfig.options.maximumConnections = 4
        let pg = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        let pgTask = Task { await pg.run() }
        defer { pgTask.cancel() }
        let store = PostgresStore(client: pg, logger: logger)
        diagStore = store
        var migrated = false
        for _ in 0..<50 where !migrated {
            do { try await store.migrate(); migrated = true } catch { try await Task.sleep(for: .milliseconds(200)) }
        }
        guard migrated else { throw HarnessError("could not reach the database") }
        let initial = spec.plan == .chaos ? Templates.example() : StormWorkflow.make(clients: spec.clients)
        guard try await store.createDocument(id: docId, initial: initial) else { throw HarnessError("document id clash") }

        // --- server (optionally reaching Postgres through a fault proxy)
        var dbHost: String?
        var dbPort: Int?
        let pgProxy = "pg-\(spec.slot)"
        if useProxy, spec.faults.dbCuts, let toxi {
            let port = 22000 + spec.slot
            try await toxi.createProxy(name: pgProxy, listenPort: port, upstream: "\(env.dbHost):\(env.dbPort)")
            dbHost = env.toxiproxyHost
            dbPort = port
        }
        var serverEnv: [String: String] = ["COLLAB_SSE_PING_SECONDS": "\(spec.pingSeconds)", "COLLAB_DB_POOL_SIZE": "12",
                                      "COLLAB_DB_IDLE_IN_TRANSACTION_TIMEOUT_MS": "5000", "COLLAB_DB_LOCK_TIMEOUT_MS": "4000", "COLLAB_DB_OPERATION_TIMEOUT_MS": "6000"]
        if spec.profile.serverCommitDelayMs > 0 { serverEnv["COLLAB_TEST_COMMIT_DELAY_MILLIS"] = "\(spec.profile.serverCommitDelayMs)" }
        let server = ServerProcess(port: serverPort, dir: dir, env: env, dbHost: dbHost, dbPort: dbPort, extraEnv: serverEnv)
        liveServer = server
        try server.start()
        try await server.waitHealthy()
        // Protocol 1.8: every client signs in. One account for the whole run (installed on a fresh database).
        let account = HarnessAccount.standard(base: server.baseURL)
        _ = try await ServerAuth.ensureWorkspace(base: account.base, email: account.email, password: account.password, name: "Harness")

        // --- proxies per client
        var pairs: [NetworkControl.ProxyPair] = []
        var specs: [WorkerClientSpec] = []
        var rng = Rng(seed: spec.seed)
        for i in 0..<spec.clients {
            var post = "http://127.0.0.1:\(serverPort)", events = post
            if let toxi {
                let base = 21000 + spec.slot * 400 + i * 2
                let pp = "p\(spec.slot)-\(i)", ep = "e\(spec.slot)-\(i)"
                try await toxi.createProxy(name: pp, listenPort: base, upstream: "\(env.selfHost):\(serverPort)")
                try await toxi.createProxy(name: ep, listenPort: base + 1, upstream: "\(env.selfHost):\(serverPort)")
                pairs.append(.init(post: pp, events: ep))
                liveProxies += [pp, ep]
                post = "http://\(env.toxiproxyHost):\(base)"
                events = "http://\(env.toxiproxyHost):\(base + 1)"
            }
            specs.append(WorkerClientSpec(id: "c\(i)", index: i, journaled: !rng.chance(spec.volatileFraction), postBase: post, eventsBase: events))
        }
        let net = toxi.map { NetworkControl(toxi: $0, profile: spec.profile, pairs: pairs) }
        if spec.profile.usesNetem, Netem.available, let ip = Netem.resolve(host: env.toxiproxyHost) {
            let n = spec.profile.netem
            Netem.apply(Netem(delayMs: n.delayMs, jitterMs: n.jitterMs, lossPercent: n.lossPercent,
                              reorderPercent: n.reorderPercent, duplicatePercent: n.duplicatePercent), device: env.netemDevice, toIP: ip)
        } else if spec.profile.usesNetem {
            note("WARN netem unavailable here: profile \(spec.profile.name) ran without packet-level impairment")
        }
        defer { if spec.profile.usesNetem, Netem.available { Netem.clear(device: env.netemDevice) } }
        await net?.applyStatic()

        // --- workers
        var workers: [WorkerHandle] = []
        let perWorker = max(1, spec.clientsPerWorker)
        for (w, chunk) in stride(from: 0, to: specs.count, by: perWorker).map({ Array(specs[$0..<min($0 + perWorker, specs.count)]) }).enumerated() {
            let h = WorkerHandle(id: "w\(w)", clients: chunk, spec: spec, doc: docId, dir: dir, env: env, account: account)
            try h.spawn()
            workers.append(h)
            liveWorkers.append(h)
        }
        for w in workers { _ = await w.expect("ready", timeout: .seconds(30)) }

        // --- the editing window with fault injection
        let sampler = Task { await self.sampleServer(server) }
        net?.startDynamics()
        let faultTask = Task { await self.injectFaults(server: server, workers: workers, net: net, toxi: toxi, pgProxy: pgProxy) }
        try? await Task.sleep(for: .seconds(spec.durationSec))
        faultTask.cancel()
        await faultTask.value
        // Clear netem first: it also shapes the harness's own calls to the fault proxy, and restoring 200 proxies through
        // a 15%-loss link kept the editors running for minutes past the window.
        if spec.profile.usesNetem, Netem.available { Netem.clear(device: env.netemDevice) }
        await net?.restore()
        if useProxy, spec.faults.dbCuts { await toxi?.ensureClean(proxy: pgProxy) }
        // Heal everything: server up, workers alive and resumed.
        if server.pid == nil { try server.start(); try await server.waitHealthy() }
        for w in workers { try await w.healAfterFaults() }

        // --- settle: every op resolves, then everybody catches up to the final head
        var allIdle = true
        for w in workers { w.send("stop") }
        for w in workers {
            guard let r = await w.expect("idle", timeout: .seconds(spec.settleSec + 30)) else {
                allIdle = false
                note("FAIL worker \(w.id) did not become idle")
                await diagnoseStall(server: server)
                continue
            }
            if r != "idle 0" { allIdle = false; note("FAIL worker \(w.id) finished with unresolved ops: \(r)") }
        }
        guard let head = try await store.documentHead(docId) else { throw HarnessError("document vanished") }
        for w in workers { w.send("final \(head)") }
        for w in workers {
            let r = await w.expect("done", timeout: .seconds(spec.settleSec + 30))
            if r != "done ok" { note("FAIL worker \(w.id) did not converge to head \(head): \(r ?? "no answer")") }
        }
        sampler.cancel()
        let metrics = await sampler.value
        _ = allIdle

        // --- verification against the database and every client
        let clientIds = specs.map(\.id)
        let bearer = try await ServerAuth.login(base: account.base, email: account.email, password: account.password).access
        var report = try await Checker.check(doc: docId, dir: dir, clientIds: clientIds, plan: spec.plan, initial: initial,
                                             store: store, serverURL: server.baseURL, bearer: bearer)
        if let again = try await store.documentHead(docId), again != head { report.violations.append("LOG: head moved from \(head) to \(again) after the clients went idle") }

        for w in workers { w.send("exit") }
        for w in workers { await w.shutdown() }
        await server.stop()
        if let toxi {
            for p in pairs { await toxi.deleteProxy(p.post); await toxi.deleteProxy(p.events) }
            await toxi.deleteProxy(pgProxy)
        }
        var result = RoundResult(spec: spec, report: report)
        result.server = metrics
        result.injected = injected.merging(net?.injected ?? [:], uniquingKeysWith: +)
        result.notes = notes
        if let f = toxi?.failedCalls, f > 0 { result.notes.append("WARN toxiproxy admin API calls that failed after retries: \(f)") }
        return result
    }

    /// Evidence for a stalled round: is the server alive and answering, what is Postgres doing?
    func diagnoseStall(server: ServerProcess) async {
        let health = (try? await HarnessHTTP.get("\(server.baseURL)/healthz", timeout: .seconds(5))).map { "HTTP \($0.0) \(String(decoding: $0.1, as: UTF8.self))" } ?? "no answer"
        note("DIAG server pid=\(server.pid.map(String.init) ?? "dead") healthz=\(health)")
        note("DIAG pg_stat_activity: \(await diagnose())")
    }

    func diagnose() async -> String {
        guard let c = diagStore?.client else { return "n/a" }
        var rows: [String] = []
        do {
            for try await r in try await c.query("SELECT pid, state, wait_event_type, wait_event, now() - state_change, left(query, 70) FROM pg_stat_activity WHERE datname = current_database()", logger: Logger(label: "diag")).decode((Int, String?, String?, String?, String?, String?).self) {
                rows.append("\(r)")
            }
        } catch { return "query failed: \(error)" }
        return rows.joined(separator: " | ")
    }

    // MARK: - server metrics

    private func sampleServer(_ server: ServerProcess) async -> ServerMetrics {
        var m = ServerMetrics()
        var last: (pid: Int32, cpu: Double, t: ContinuousClock.Instant)?
        var totalCpu = 0.0, totalWall = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let pid = server.pid, let u = server.resourceUsage() else { last = nil; continue }
            let now = ContinuousClock.now
            m.peakRssMB = max(m.peakRssMB, Double(u.rssBytes) / 1_048_576)
            if let l = last, l.pid == pid {
                let wall = Double((now - l.t) / .milliseconds(1)) / 1000
                let cpu = u.cpuSeconds - l.cpu
                if wall > 0 {
                    totalCpu += cpu; totalWall += wall
                    m.peakCpuPercent = max(m.peakCpuPercent, 100 * cpu / wall)
                    m.samples += 1
                }
            }
            last = (pid, u.cpuSeconds, now)
        }
        if totalWall > 0 { m.avgCpuPercent = 100 * totalCpu / totalWall }
        return m
    }

    // MARK: - fault injection

    private func injectFaults(server: ServerProcess, workers: [WorkerHandle], net: NetworkControl?, toxi: Toxiproxy?, pgProxy: String) async {
        let f = spec.faults
        guard f.serverKills || f.clientKills || f.clientPauses || f.dbCuts || f.networkCuts else { return }
        var rng = Rng(seed: spec.seed ^ 0xFA17)
        let seeds = (0..<4).map { _ in rng.next() }
        var tasks: [Task<Void, Never>] = []
        if f.serverKills {
            tasks.append(Task {
                var r = Rng(seed: seeds[0])
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1000 * r.int(f.serverKillEverySec[0]...f.serverKillEverySec[1])))
                    if Task.isCancelled { break }
                    server.kill9()
                    self.bump("serverKill")
                    try? await Task.sleep(for: .milliseconds(r.int(200...1500)))
                    // Restarting must not be interrupted by the end of the fault window (cancellation would make the health probe fail).
                    await Task {
                        do { try server.start(); try await server.waitHealthy() } catch { self.note("FAIL server restart: \(error)") }
                    }.value
                }
            })
        }
        if f.clientKills || f.clientPauses {
            tasks.append(Task {
                var r = Rng(seed: seeds[1])
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1000 * r.int(f.clientFaultEverySec[0]...f.clientFaultEverySec[1])))
                    if Task.isCancelled { break }
                    guard let w = r.pick(workers) else { continue }
                    if f.clientKills && (!f.clientPauses || r.chance(0.6)) {
                        w.kill9()
                        self.bump("clientKill")
                        try? await Task.sleep(for: .milliseconds(r.int(200...2500)))
                        do { try w.respawn() } catch { self.note("FAIL worker respawn: \(error)") }
                    } else {
                        w.pause()
                        self.bump("clientPause")
                        try? await Task.sleep(for: .milliseconds(r.int(1000...4000)))
                        w.resume()
                    }
                }
            })
        }
        if f.dbCuts, let toxi {
            tasks.append(Task {
                var r = Rng(seed: seeds[2])
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(r.int(1500...5000)))
                    if Task.isCancelled { break }
                    await toxi.setEnabled(pgProxy, false)
                    self.bump("dbCut")
                    try? await Task.sleep(for: .milliseconds(r.int(200...1500)))
                    // Healing must run even when the fault window just ended (a cancelled HTTP call would leave the proxy down).
                    await Task { await toxi.setEnabled(pgProxy, true) }.value
                }
            })
        }
        if f.networkCuts, let net {
            tasks.append(Task {
                var r = Rng(seed: seeds[3])
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(r.int(400...1800)))
                    if Task.isCancelled { break }
                    let i = r.int(0...max(0, spec.clients - 1))
                    if r.chance(0.5) { await net.cut(i, forMs: r.int(200...2000)) } else { await net.stall(i, forMs: r.int(500...3000)) }
                }
            })
        }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        for t in tasks { t.cancel() }
        for t in tasks { await t.value }
    }
}

// MARK: - worker processes

final class WorkerHandle: @unchecked Sendable {
    let id: String
    let clients: [WorkerClientSpec]
    let spec: RoundSpec
    let doc: String
    let dir: String
    let env: HarnessEnv
    private var proc: ManagedProcess?
    private var incarnation = 0
    private let box = LineBox()
    private var reader: Task<Void, Never>?
    private var paused = false

    let account: HarnessAccount?

    init(id: String, clients: [WorkerClientSpec], spec: RoundSpec, doc: String, dir: String, env: HarnessEnv, account: HarnessAccount? = nil) {
        self.account = account
        self.id = id
        self.clients = clients
        self.spec = spec
        self.doc = doc
        self.dir = dir
        self.env = env
    }

    func spawn() throws {
        incarnation += 1
        var cfg = WorkerConfig(workerId: id, doc: doc, dir: dir, plan: spec.plan, clientCount: spec.clients, clients: clients,
                               editMinMs: spec.editMinMs, editMaxMs: spec.editMaxMs, seed: spec.seed &+ UInt64(clients.first?.index ?? 0),
                               persist: spec.faults.clientKills, incarnation: incarnation)
        cfg.timings = spec.timings
        cfg.duplicatePostRate = spec.faults.duplicatePostRate
        cfg.replayOldRate = spec.faults.replayOldRate
        cfg.auth = account
        let path = "\(dir)/\(id).\(incarnation).config.json"
        FileManager.default.createFile(atPath: path, contents: try JSONEncoder().encode(cfg))
        let p = try ManagedProcess(name: id, executable: env.benchBinary, arguments: ["worker", path], logPath: "\(dir)/\(id).\(incarnation).log", pipes: true)
        proc = p
        if let lines = p.stdoutLines {
            let box = self.box
            reader = Task { for await l in lines { await box.add(l) } }
        }
    }

    func send(_ s: String) { proc?.send(s) }
    func kill9() { proc?.kill9(); paused = false }
    func pause() { proc?.pause(); paused = true }
    func resume() { proc?.resume(); paused = false }
    func respawn() throws {
        if proc?.isRunning == true { return }
        try spawn()
    }

    /// Makes sure the worker is running and not paused.
    func healAfterFaults() async throws {
        if paused { resume() }
        if proc?.isRunning != true { try spawn() }
    }

    func expect(_ prefix: String, timeout: Duration) async -> String? { await box.wait(prefix: prefix, timeout: timeout) }

    func shutdown() async {
        _ = await proc?.waitExit(timeout: .seconds(5))
        if proc?.isRunning == true { proc?.kill9() }
        reader?.cancel()
    }
}

actor LineBox {
    private var lines: [String] = []

    func add(_ l: String) { lines.append(l) }

    func wait(prefix: String, timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let i = lines.firstIndex(where: { $0.hasPrefix(prefix) }) {
                let l = lines[i]
                lines.remove(at: i)
                return l
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
