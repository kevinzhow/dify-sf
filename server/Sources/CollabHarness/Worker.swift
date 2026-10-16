import CollabClientKit
import CollabCore
import Foundation

public struct WorkerClientSpec: Codable, Sendable {
    public var id: ClientID
    public var index: Int
    public var journaled: Bool
    public var postBase: String
    public var eventsBase: String
}

public struct ClientTimings: Codable, Sendable {
    public var retransmitAfterMs = 3000
    public var streamSilenceMs = 8000
    public var reconnectBaseMs = 200
    public var reconnectMaxMs = 3000
    public var maxBatch = 50
    public var postTimeoutMs = 4000
    public init() {}

    /// The values recommended in docs/protocol.md.
    public static var protocolDefaults: ClientTimings {
        var t = ClientTimings()
        t.retransmitAfterMs = 10_000
        t.streamSilenceMs = 30_000
        t.reconnectBaseMs = 500
        t.reconnectMaxMs = 15_000
        t.postTimeoutMs = 10_000
        return t
    }
}

public struct WorkerConfig: Codable, Sendable {
    public var workerId: String
    public var doc: String
    public var dir: String
    public var plan: PlanKind
    public var clientCount: Int
    public var clients: [WorkerClientSpec]
    public var editMinMs: Int
    public var editMaxMs: Int
    public var seed: UInt64
    public var persist: Bool
    public var incarnation: Int
    public var timings = ClientTimings()
    public var duplicatePostRate = 0.0
    public var replayOldRate = 0.0
}

/// Hosts one or more independent clients (each with its own HTTP connections and state machine) in one process.
/// Controlled over stdin/stdout lines by the orchestrator:
///   stop            -> stop editing, wait for every op to resolve, reply `idle <unresolved>`
///   final <head>    -> wait to converge to `head`, write final dumps, reply `done ok|timeout`
///   exit
public enum Worker {
    public static func run(configPath: String) async {
        guard let data = FileManager.default.contents(atPath: configPath),
              let cfg = try? JSONDecoder().decode(WorkerConfig.self, from: data) else {
            FileHandle.standardError.write(Data("worker: cannot read config \(configPath)\n".utf8))
            exit(2)
        }
        try? FileManager.default.createDirectory(atPath: cfg.dir, withIntermediateDirectories: true)
        let stop = StopFlag()
        var drivers: [(spec: WorkerClientSpec, driver: ClientDriver, recorder: AppliedRecorder)] = []
        let t = cfg.timings
        let clientConfig = ClientConfig(retransmitAfter: t.retransmitAfterMs, streamSilence: t.streamSilenceMs,
                                        reconnectBase: t.reconnectBaseMs, reconnectMax: t.reconnectMaxMs, maxBatch: t.maxBatch)

        for spec in cfg.clients {
            let ledger = LedgerWriter(path: "\(cfg.dir)/\(spec.id).ledger.jsonl")
            let recorder = AppliedRecorder(client: spec.id, path: "\(cfg.dir)/\(spec.id).applied.\(cfg.incarnation).json")
            let id = spec.id
            let hooks = DriverHooks(
                issued: { cseq, base, op in
                    ledger.append(LedgerLine(k: .issued, c: id, cseq: cseq, t: wall(), base: base, op: op))
                },
                event: { ev in
                    switch ev {
                    case .committed(let cseq, let seq): ledger.append(LedgerLine(k: .committed, c: id, cseq: cseq, t: wall(), seq: seq))
                    case .rejected(let cseq, _, let r): ledger.append(LedgerLine(k: .rejected, c: id, cseq: cseq, t: wall(), reason: r))
                    case .lost(let cseq): ledger.append(LedgerLine(k: .lost, c: id, cseq: cseq, t: wall()))
                    case .conflictDetected(let cseq, _, _): ledger.append(LedgerLine(k: .early, c: id, cseq: cseq, t: wall()))
                    case .localInvalid: break
                    }
                },
                applied: { first, last, wallMs in recorder.record(first: first, last: last, wall: wallMs) })
            let transport = HTTPTransport(postBase: spec.postBase, eventsBase: spec.eventsBase, doc: cfg.doc)
            let storage: DurableStorage? = cfg.persist ? FileDurableStorage(path: "\(cfg.dir)/\(spec.id).durable.json") : nil
            let driver = ClientDriver(id: spec.id, journaled: spec.journaled, transport: transport, storage: storage, hooks: hooks,
                                      config: clientConfig,
                                      faults: DriverFaults(duplicatePostRate: cfg.duplicatePostRate, replayOldRate: cfg.replayOldRate),
                                      postTimeout: .milliseconds(t.postTimeoutMs))
            drivers.append((spec, driver, recorder))
        }
        for d in drivers { await d.driver.start() }

        // Editors
        var editors: [Task<Void, Never>] = []
        for d in drivers {
            let seedBase = cfg.seed ^ UInt64(cfg.incarnation) &* 0x1F3D_5B79
            editors.append(Task {
                var planner = EditPlanner(plan: cfg.plan, clientIndex: d.spec.index, clientCount: cfg.clientCount,
                                          clientId: d.spec.id, seed: seedBase, counterStart: cfg.incarnation * 1_000_000)
                // Desynchronise the clients' first edits.
                try? await Task.sleep(for: .milliseconds(planner.nextDelayMillis(min: 0, max: cfg.editMaxMs)))
                while !stop.isSet {
                    if await d.driver.hasState, let op = planner.next(view: await d.driver.view) { _ = await d.driver.edit(op) }
                    try? await Task.sleep(for: .milliseconds(planner.nextDelayMillis(min: cfg.editMinMs, max: cfg.editMaxMs)))
                }
            })
        }
        let flusher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                for d in drivers { d.recorder.flush() }
            }
        }

        say("ready")
        for await line in LineStream.stdin {
            let parts = line.split(separator: " ")
            switch parts.first {
            case "stop":
                stop.set()
                for e in editors { await e.value }
                var unresolved = 0
                let deadline = ContinuousClock.now + .seconds(120)
                while ContinuousClock.now < deadline {
                    unresolved = 0
                    for d in drivers { unresolved += await d.driver.unresolved }
                    if unresolved == 0 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                say("idle \(unresolved)")
            case "final":
                let head = Int(parts.dropFirst().first ?? "0") ?? 0
                var ok = false
                let deadline = ContinuousClock.now + .seconds(90)
                while ContinuousClock.now < deadline {
                    var all = true
                    for d in drivers {
                        let seq = await d.driver.lastSeq, un = await d.driver.unresolved, st = await d.driver.hasState
                        if !(st && seq >= head && un == 0) { all = false }
                    }
                    if all { ok = true; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                for d in drivers {
                    d.recorder.flush()
                    let stats = await d.driver.stats
                    let fin = ClientFinal(id: d.spec.id, lastSeq: await d.driver.lastSeq, unresolved: await d.driver.unresolved,
                                          confirmed: await d.driver.confirmed, view: await d.driver.view,
                                          violations: await d.driver.violations,
                                          stats: DriverStatsDump(posts: stats.posts, postFailures: stats.postFailures, streamsOpened: stats.streamsOpened,
                                                                 streamsLost: stats.streamsLost, snapshots: stats.snapshots, commits: stats.commits,
                                                                 postMillis: stats.postMillis))
                    if let data = try? WireJSON.encode(fin) {
                        FileManager.default.createFile(atPath: "\(cfg.dir)/\(d.spec.id).final.json", contents: data)
                    }
                    if !ok { FileHandle.standardError.write(Data("worker \(cfg.workerId) \(d.spec.id): \(await d.driver.debug)\n".utf8)) }
                }
                say(ok ? "done ok" : "done timeout")
            case "exit":
                flusher.cancel()
                for d in drivers { await d.driver.stop() }
                exit(0)
            default: break
            }
        }
        // stdin closed: the orchestrator is gone.
        exit(0)
    }

    static func wall() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func say(_ s: String) { emit(s) }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
