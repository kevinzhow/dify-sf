import Foundation
import CollabCore
import CollabSim

// Usage: collab-sim [--runs N] [--seed S] [--profile calm|lossy|flaky|crashy|chaos]
//                   [--mutation skipStaleCheck|skipBrokenMarkers|clientNeverResends|noDedup|sameValueConflicts|lossyDisk]
//                   [--scenarios-only]
var runs = 10_000
var seed: UInt64 = 1
var profile: Profile?
var mutation: String?
var scenariosOnly = false
var traceSeed: UInt64?

var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--runs": runs = Int(args.popFirst() ?? "") ?? runs
    case "--seed": seed = UInt64(args.popFirst() ?? "") ?? seed
    case "--profile": profile = Profile.allCases.first { $0.name == args.first }; _ = args.popFirst()
    case "--mutation": mutation = args.popFirst()
    case "--scenarios-only": scenariosOnly = true
    case "--trace": traceSeed = UInt64(args.popFirst() ?? "")
    case "--verbose": break
    default: print("unknown argument \(a)"); exit(2)
    }
}

func pad(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: max(0, n - s.count)) }

if let t = traceSeed {
    let (w, p, _, _) = Fuzz.execute(seed: t, profile: profile, trace: CommandLine.arguments.contains("--verbose"))
    if CommandLine.arguments.contains("--verbose") { for l in w.traceLog where l.contains("slot1") { print(l) } }
    print("seed \(t) profile \(p.name)")
    for v in Fuzz.check(w) { print("VIOLATION \(v)") }
    print(w.debugNet)
    for sl in w.slots { print("\(sl.id) journaled=\(sl.journaled) \(sl.client?.debugOutbox ?? ["down"])") }
    for e in w.committedLog { print("\(e.seq) \(e.client)#\(e.cseq) base=\(e.base) \(e.op)") }
    exit(0)
}

if mutation == nil {
    print("== Named scenarios ==")
    var failed = 0
    for s in Scenarios.all {
        let r = s()
        let ok = r.passed
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(pad(r.name, 44)) checks \(r.checks.filter(\.ok).count)/\(r.checks.count)  invariant violations \(r.violations.count)")
        if !ok {
            for c in r.checks where !c.ok { print("      check failed: \(c.what)") }
            for v in r.violations.prefix(5) { print("      violation: \(v)") }
        }
    }
    print("scenarios: \(Scenarios.all.count - failed)/\(Scenarios.all.count) passed")
    if scenariosOnly { exit(failed == 0 ? 0 : 1) }
}

var defects: ProtocolDefects = []
var lossy = false
switch mutation {
case "skipStaleCheck": defects = .skipStaleCheck
case "skipBrokenMarkers": defects = .skipBrokenMarkers
case "clientNeverResends": defects = .clientNeverResends
case "noDedup": defects = .noDedup
case "sameValueConflicts": defects = .sameValueConflicts
case "lossyDisk": lossy = true
case nil: break
default: print("unknown mutation"); exit(2)
}

print("\n== Fuzz: \(runs) runs, seeds \(seed)..<\(seed + UInt64(runs)), profile \(profile?.name ?? "all (round-robin)")\(mutation.map { ", MUTATION \($0)" } ?? "") ==")
let report = Fuzz.runMany(from: seed, count: runs, profile: profile, defects: defects, lossyDisk: lossy)

print("runs: \(report.runs)   runs with violations: \(report.failureCount)")
for p in Profile.allCases where report.runsPerProfile[p] != nil {
    print("  \(pad(p.name, 8)) runs \(pad(String(report.runsPerProfile[p]!), 6)) violations \(report.failuresPerProfile[p] ?? 0)")
}
if !report.failureKinds.isEmpty {
    print("violation kinds (runs affected): " + report.failureKinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
}
print("totals:")
for k in report.stats.counters.keys.sorted() { print("  \(pad(k, 40)) \(report.stats[k])") }
for f in report.failures.prefix(5) {
    print("FAIL seed \(f.seed) profile \(f.profile.name) clients \(f.clients)")
    for v in f.violations.prefix(4) { print("    \(v)") }
}
exit(mutation == nil ? (report.failureCount == 0 ? 0 : 1) : 0)
