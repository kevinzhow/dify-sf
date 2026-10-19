// collab-runtime: tools around the workflow runtime.
//   collab-runtime replay [--workers N] [--only SUBSTRING] [TRACES_DIR] [FIXTURES_DIR]
//   collab-runtime bench [RUNS] | bench-iteration [RUNS] [ROUNDS] [PARALLEL]
// replays Dify's golden traces (graphon 0.7.0 with Dify's mock nodes) on the Swift engine and prints PASS/DIFF/SKIP.

import CollabRuntime
import CollabRuntimeReplay
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "bench-iteration" {
    let n = args.dropFirst().compactMap { Int($0) }
    print(try await Bench.iteration(runs: n.count > 0 ? n[0] : 20, rounds: n.count > 1 ? n[1] : 100, parallel: n.count > 2 ? n[2] : 10))
    exit(0)
}
if args.first == "bench" {
    let runs = args.count > 1 ? Int(args[1]) ?? 50 : 50
    print(try await Bench.run(runs: runs))
    exit(0)
}
guard args.first == "replay" else {
    print("usage: collab-runtime replay [--workers N] [--only SUBSTRING] [TRACES_DIR] [FIXTURES_DIR] | collab-runtime bench [RUNS]")
    exit(2)
}
args.removeFirst()
var workers = 1
var only = ""
var positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--workers", let n = args.first.flatMap(Int.init) { workers = n; args.removeFirst() }
    else if a == "--only", let s = args.first { only = s; args.removeFirst() }
    else { positional.append(a) }
}
let traces = URL(fileURLWithPath: positional.count > 0 ? positional[0] : "Tests/CollabTests/Fixtures/graphon-traces")
let fixtures = URL(fileURLWithPath: positional.count > 1 ? positional[1] : "Tests/CollabTests/Fixtures/dify")
var results = try await Replay.replayAll(tracesDir: traces, fixturesDir: fixtures, maxWorkers: workers)
if !only.isEmpty { results = results.filter { $0.name.contains(only) } }
print(Replay.table(results))
exit(results.contains { $0.outcome == .diff || $0.outcome == .error } ? 1 : 0)
