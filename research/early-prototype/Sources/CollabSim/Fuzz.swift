import CollabCore
import Dispatch
import Synchronization

public struct RunResult: Sendable {
    public var seed: UInt64
    public var profile: Profile
    public var clients: Int
    public var violations: [String]
    public var stats: Stats
}

public struct FuzzReport: Sendable {
    public var runs = 0
    public var failures: [RunResult] = []
    public var stats = Stats()
    public var runsPerProfile: [Profile: Int] = [:]
    public var failuresPerProfile: [Profile: Int] = [:]
    public var failureKinds: [String: Int] = [:]

    mutating func add(_ r: RunResult) {
        runs += 1
        runsPerProfile[r.profile, default: 0] += 1
        stats.merge(r.stats)
        if !r.violations.isEmpty {
            failuresPerProfile[r.profile, default: 0] += 1
            for v in Set(r.violations.map { String($0.prefix { $0 != ":" }) }) { failureKinds[v, default: 0] += 1 }
            if failures.count < 25 { failures.append(r) }
        }
    }

    mutating func merge(_ o: FuzzReport) {
        runs += o.runs
        stats.merge(o.stats)
        for (k, v) in o.runsPerProfile { runsPerProfile[k, default: 0] += v }
        for (k, v) in o.failuresPerProfile { failuresPerProfile[k, default: 0] += v }
        for (k, v) in o.failureKinds { failureKinds[k, default: 0] += v }
        failures += o.failures
        if failures.count > 25 { failures = Array(failures.sorted { $0.seed < $1.seed }.prefix(25)) }
    }

    public var failureCount: Int { failuresPerProfile.values.reduce(0, +) }
}

public enum Fuzz {
    /// One seeded run: random config from the profile, `steps` of chaos, heal, settle, check invariants.
    public static func run(seed: UInt64, profile: Profile? = nil, defects: ProtocolDefects = [],
                           lossyDisk: Bool = false) -> RunResult {
        let (w, p, settled, cfg) = execute(seed: seed, profile: profile, defects: defects, lossyDisk: lossyDisk)
        var violations = Invariants.check(w)
        if !settled { violations.insert("CONVERGENCE: did not settle", at: 0) }
        return RunResult(seed: seed, profile: p, clients: cfg.clientCount, violations: violations, stats: w.rec.stats)
    }

    /// Builds, runs and settles one world (also used to inspect a failing seed).
    public static func execute(seed: UInt64, profile: Profile? = nil, defects: ProtocolDefects = [],
                               lossyDisk: Bool = false) -> (World, Profile, Bool, SimConfig) {
        let p = profile ?? Profile.allCases[Int(seed % UInt64(Profile.allCases.count))]
        var cfgRng = Rng(seed: seed ^ 0xC0FF_EE00_DEAD_BEEF)
        var cfg = p.config(rng: &cfgRng)
        cfg.defects = defects
        cfg.lossyDisk = lossyDisk
        var w = World(seed: seed, cfg: cfg)
        for _ in 0..<cfg.steps { w.step() }
        let settled = w.settle()
        return (w, p, settled, cfg)
    }

    /// Runs seeds `from ..< from+count` across all cores.
    public static func runMany(from: UInt64, count: Int, profile: Profile? = nil, defects: ProtocolDefects = [],
                               lossyDisk: Bool = false) -> FuzzReport {
        let chunks = max(1, min(64, count))
        let result = Mutex(FuzzReport())
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var local = FuzzReport()
            var i = chunk
            while i < count {
                local.add(run(seed: from + UInt64(i), profile: profile, defects: defects, lossyDisk: lossyDisk))
                i += chunks
            }
            result.withLock { $0.merge(local) }
        }
        return result.withLock { $0 }
    }
}
