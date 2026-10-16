import Foundation

enum Report {
    static func f(_ x: Double, _ d: Int = 0) -> String { String(format: "%.\(d)f", x) }

    static func line(_ r: RoundResult) -> String {
        let c = r.report
        return "  \(r.passed ? "PASS" : "FAIL") head=\(c.head) issued=\(c.issued) committed=\(c.committed) conflicts=\(c.rejectedConflict) lostDisjoint=\(c.lostDisjointEdits) lostSame=\(c.lostSameValueEdits) silentOverwrites=\(c.silentOverwrites) divergence=\(c.finalDivergence) visible p50/p99=\(f(c.visibilityLatencyMs.p50))/\(f(c.visibilityLatencyMs.p99))ms cpu avg/peak=\(f(r.server.avgCpuPercent))/\(f(r.server.peakCpuPercent))% rss=\(f(r.server.peakRssMB))MB \(r.passed ? "" : String(describing: c.violations.prefix(3) + r.notes.prefix(3)))"
    }

    static func stormTable(_ results: [RoundResult]) -> String {
        var s = "| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | silent overwrites | final divergence | ack p50/p99 ms | visible p50/p99 ms | server CPU avg/peak % | RSS MB | faults | result |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in results {
            let c = r.report
            let mix = r.spec.name.split(separator: "-").dropFirst().first.map(String.init) ?? "?"
            let faults = r.injected.isEmpty ? "-" : r.injected.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            s += "| \(r.spec.name) | \(mix) | \(r.spec.clients) | \(r.spec.durationSec) | \(r.spec.profile.name) | \(c.issued) | \(c.committed) | \(c.rejectedConflict) | \(c.lostDisjointEdits) | \(c.lostSameValueEdits) | \(c.silentOverwrites) | \(c.finalDivergence) | \(f(c.ackLatencyMs.p50))/\(f(c.ackLatencyMs.p99)) | \(f(c.visibilityLatencyMs.p50))/\(f(c.visibilityLatencyMs.p99)) | \(f(r.server.avgCpuPercent))/\(f(r.server.peakCpuPercent)) | \(f(r.server.peakRssMB)) | \(faults) | \(r.passed ? "PASS" : "FAIL") |\n"
        }
        s += "\nProfiles:\n"
        for p in Set(results.map(\.spec.profile.name)).sorted() {
            if let r = results.first(where: { $0.spec.profile.name == p }) { s += "- `\(p)`: \(r.spec.profile.summary)\n" }
        }
        return s
    }

    static func chaosSummary(_ results: [RoundResult]) -> String {
        let passed = results.filter(\.passed).count
        var issued = 0, committed = 0, conflicts = 0, lost = 0, rejOther = 0
        var faults: [String: Int] = [:]
        var kinds: [String: Int] = [:]
        var snapshots = 0, streamsLost = 0, postFailures = 0
        for r in results {
            issued += r.report.issued; committed += r.report.committed; conflicts += r.report.rejectedConflict; lost += r.report.lost
            rejOther += r.report.rejectedOther.values.reduce(0, +)
            for (k, v) in r.injected { faults[k, default: 0] += v }
            for (k, v) in r.report.violationKinds { kinds[k, default: 0] += v }
            snapshots += r.report.clientStats.snapshots; streamsLost += r.report.clientStats.streamsLost; postFailures += r.report.clientStats.postFailures
        }
        var s = "## Chaos summary\n\n| | |\n|---|---|\n"
        s += "| runs | \(results.count) |\n| passed | \(passed) |\n| failed | \(results.count - passed) |\n"
        s += "| ops issued | \(issued) |\n| committed | \(committed) |\n| rejected (conflict) | \(conflicts) |\n| rejected (other) | \(rejOther) |\n| lost (volatile crash, reported) | \(lost) |\n"
        s += "| client snapshots received | \(snapshots) |\n| client streams lost | \(streamsLost) |\n| client POST failures | \(postFailures) |\n"
        for (k, v) in faults.sorted(by: { $0.key < $1.key }) { s += "| fault: \(k) | \(v) |\n" }
        if !kinds.isEmpty { s += "\nViolation kinds: \(kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n" }
        for r in results where !r.passed { s += "\nFAILED \(r.spec.name): \(r.report.violations.prefix(5)) \(r.notes.prefix(3))\n" }
        return s
    }

    static func run(_ a: Args) {
        let dir = a.str("dir", ".")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") && $0 != "results.json" }.sorted()
        var results: [RoundResult] = []
        for f in files {
            if let d = FileManager.default.contents(atPath: "\(dir)/\(f)"), let r = try? JSONDecoder().decode(RoundResult.self, from: d) { results.append(r) }
        }
        print(stormTable(results))
    }
}
