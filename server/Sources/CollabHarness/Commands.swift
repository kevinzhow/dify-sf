import CollabCore
import Foundation

/// Unbuffered line output (stdout is a pipe/file in the harness, where print() would be fully buffered).
func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { options[key] = argv[i + 1]; i += 1 } else { flags.insert(key) }
            } else { positional.append(a) }
            i += 1
        }
    }

    func int(_ k: String, _ d: Int) -> Int { options[k].flatMap(Int.init) ?? d }
    func str(_ k: String, _ d: String) -> String { options[k] ?? d }
}

/// Slots keep concurrently running rounds on distinct ports.
actor SlotPool {
    private var free: [Int]
    private var waiters: [CheckedContinuation<Int, Never>] = []
    init(count: Int) { free = Array(0..<count) }
    func take() async -> Int {
        if let s = free.popLast() { return s }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func give(_ s: Int) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: s) } else { free.append(s) }
    }
}

public enum Bench {
    public static func main(_ argv: [String]) async {
        let args = Args(argv)
        guard let cmd = args.positional.first else { usage(); exit(2) }
        switch cmd {
        case "worker":
            guard args.positional.count > 1 else { usage(); exit(2) }
            await Worker.run(configPath: args.positional[1])
        case "chaos": await Chaos.run(args)
        case "storm": await Storm.run(args)
        case "report": Report.run(args)
        default: usage(); exit(2)
        }
    }

    static func usage() {
        print("""
        collab-bench worker <config.json>                      (internal: client host process)
        collab-bench chaos  --runs N [--seed S] [--parallel P] [--out DIR]
        collab-bench storm  --mix a|b|c [--clients N] [--duration SEC] [--profile NAME] [--out DIR]
        collab-bench storm  --ladder --mix a|b|c [--duration SEC] [--out DIR]       (10, 25, 50, 100 clients)
        collab-bench storm  --sweep [--clients N] [--duration SEC] [--out DIR]       (every network profile, mix b)
        collab-bench report --dir DIR                                                  (merge round JSON into markdown)
        """)
    }
}

// MARK: - chaos

enum Chaos {
    static func run(_ a: Args) async {
        let env = HarnessEnv()
        let runs = a.int("runs", 20)
        let baseSeed = UInt64(a.int("seed", 1))
        let parallel = max(1, a.int("parallel", 3))
        let out = a.str("out", "bench/chaos/results/\(stamp())")
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let toxi = env.toxiproxyAPI.isEmpty ? nil : Toxiproxy(api: env.toxiproxyAPI)
        let slots = SlotPool(count: parallel)

        say("chaos: \(runs) runs, seeds \(baseSeed)..<\(baseSeed + UInt64(runs)), \(parallel) in parallel, fault proxy: \(toxi == nil ? "NONE (direct)" : env.toxiproxyAPI)")
        let results = await withTaskGroup(of: RoundResult.self, returning: [RoundResult].self) { group in
            for n in 0..<runs {
                let seed = baseSeed + UInt64(n)
                group.addTask {
                    let slot = await slots.take()
                    let spec = chaosSpec(seed: seed, slot: slot, out: out, hasProxy: toxi != nil)
                    let r = await RoundRunner(spec: spec, env: env, toxi: toxi).run()
                    await slots.give(slot)
                    let status = r.passed ? "ok  " : "FAIL"
                    say("\(status) \(spec.name) clients=\(spec.clients) head=\(r.report.head) issued=\(r.report.issued) conflicts=\(r.report.rejectedConflict) lost=\(r.report.lost) faults=\(r.injected.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) \(r.passed ? "" : String(describing: r.report.violations.prefix(3) + r.notes.prefix(2)))")
                    if r.passed { try? FileManager.default.removeItem(atPath: spec.workDir) }
                    if let data = try? JSONEncoder.pretty.encode(r) { FileManager.default.createFile(atPath: "\(out)/\(spec.name).json", contents: data) }
                    return r
                }
            }
            var all: [RoundResult] = []
            for await r in group { all.append(r) }
            return all
        }
        await toxi?.shutdown()
        let summary = Report.chaosSummary(results)
        FileManager.default.createFile(atPath: "\(out)/summary.md", contents: Data(summary.utf8))
        say("\n" + summary)
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    static func chaosSpec(seed: UInt64, slot: Int, out: String, hasProxy: Bool) -> RoundSpec {
        var rng = Rng(seed: seed &* 0x9E37_79B9_7F4A_7C15)
        var faults = FaultSpec()
        faults.serverKills = rng.chance(0.75)
        faults.clientKills = rng.chance(0.75)
        faults.clientPauses = rng.chance(0.3)
        faults.dbCuts = hasProxy && rng.chance(0.45)
        faults.networkCuts = hasProxy && rng.chance(0.8)
        if rng.chance(0.6) { faults.duplicatePostRate = 0.2; faults.replayOldRate = 0.1 }
        // Debugging aid: HARNESS_FORCE_FAULTS=server,db,client,net forces those fault classes on in every run.
        let forced = (ProcessInfo.processInfo.environment["HARNESS_FORCE_FAULTS"] ?? "").split(separator: ",").map(String.init)
        if forced.contains("server") { faults.serverKills = true }
        if forced.contains("db") && hasProxy { faults.dbCuts = true }
        if forced.contains("client") { faults.clientKills = true }
        if forced.contains("net") && hasProxy { faults.networkCuts = true }
        faults.serverKillEverySec = [2, 4]
        faults.clientFaultEverySec = [1, 3]
        var t = ClientTimings()
        t.retransmitAfterMs = 2500; t.streamSilenceMs = 6000; t.reconnectBaseMs = 150; t.reconnectMaxMs = 2000; t.postTimeoutMs = 3000
        return RoundSpec(name: "chaos-\(seed)", plan: .chaos, clients: rng.int(3...5), clientsPerWorker: 1, durationSec: rng.int(6...9),
                         editMinMs: 60, editMaxMs: 260, profile: NetworkProfile.baseline, faults: faults, timings: t, pingSeconds: 2,
                         seed: seed, slot: slot, volatileFraction: 0.4, workDir: "\(out)/work-\(seed)", settleSec: 25)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

// MARK: - storm

enum Storm {
    static func run(_ a: Args) async {
        let env = HarnessEnv()
        let out = a.str("out", "bench/storm/results/\(stamp())")
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let toxi = env.toxiproxyAPI.isEmpty ? nil : Toxiproxy(api: env.toxiproxyAPI)
        let duration = a.int("duration", 120)
        let mix = a.str("mix", "b")
        var specs: [RoundSpec] = []
        let profiles = a.options["profile"].map { n in [NetworkProfile.named(n) ?? .baseline] } ?? [.baseline]
        if a.flags.contains("ladder") {
            for n in [10, 25, 50, 100] { specs.append(spec(mix: mix, clients: n, duration: duration, profile: .baseline, out: out)) }
        } else if a.flags.contains("sweep") {
            for p in NetworkProfile.catalogue { specs.append(spec(mix: "b", clients: a.int("clients", 25), duration: duration, profile: p, out: out)) }
        } else {
            for p in profiles { specs.append(spec(mix: mix, clients: a.int("clients", 100), duration: duration, profile: p, out: out)) }
        }
        var results: [RoundResult] = []
        for s in specs {
            say("== round \(s.name): \(s.clients) clients, \(s.durationSec)s, profile \(s.profile.name)")
            let r = await RoundRunner(spec: s, env: env, toxi: toxi).run()
            results.append(r)
            say(Report.line(r))
            if let data = try? JSONEncoder.pretty.encode(r) { FileManager.default.createFile(atPath: "\(out)/\(s.name).json", contents: data) }
            if r.passed { try? FileManager.default.removeItem(atPath: s.workDir) }
        }
        await toxi?.shutdown()
        let md = Report.stormTable(results)
        FileManager.default.createFile(atPath: "\(out)/results.md", contents: Data(md.utf8))
        if let data = try? JSONEncoder.pretty.encode(results) { FileManager.default.createFile(atPath: "\(out)/results.json", contents: data) }
        say("\n" + md)
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    static func spec(mix: String, clients: Int, duration: Int, profile: NetworkProfile, out: String) -> RoundSpec {
        var faults = FaultSpec()
        let plan: PlanKind = mix == "a" ? .stormDisjoint : .stormMixed
        if mix == "c" {
            faults.serverKills = true; faults.clientKills = true; faults.clientPauses = true
            faults.duplicatePostRate = 0.1; faults.replayOldRate = 0.05
            faults.serverKillEverySec = [25, 40]; faults.clientFaultEverySec = [10, 20]
        }
        var timings = ClientTimings.protocolDefaults
        var ping = 10
        if profile.dynamics == .halfOpenStream || mix == "c" {
            // Shorter keep-alive so that 15-30 s stalls are detected within the window: ping 3 s, watchdog 9 s.
            timings.streamSilenceMs = 9000
            ping = 3
        }
        let name = "storm-\(mix)-\(clients)c-\(profile.name)"
        return RoundSpec(name: name, plan: plan, clients: clients, clientsPerWorker: mix == "c" ? 20 : 100, durationSec: duration,
                         editMinMs: 1000, editMaxMs: 2000, profile: profile, faults: faults, timings: timings, pingSeconds: ping,
                         seed: 4242, slot: 0, volatileFraction: mix == "c" ? 0.3 : 0.0, workDir: "\(out)/work-\(name)", settleSec: 120)
    }
}
