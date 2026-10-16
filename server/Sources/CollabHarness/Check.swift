import AsyncHTTPClient
import CollabCore
import CollabInvariants
import CollabStore
import Foundation
import NIOCore
import NIOFoundationCompat

public struct Percentiles: Codable, Sendable {
    public var count = 0
    public var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0
    public init() {}
    public init(_ values: [Double]) {
        let v = values.sorted()
        count = v.count
        guard !v.isEmpty else { return }
        func q(_ p: Double) -> Double { v[Swift.min(v.count - 1, Int(Double(v.count - 1) * p))] }
        p50 = q(0.5); p95 = q(0.95); p99 = q(0.99); max = v.last!
    }
}

/// Everything measured and verified about one chaos run or storm round.
public struct CheckReport: Codable, Sendable {
    public var head = 0
    public var violations: [String] = []
    public var violationKinds: [String: Int] = [:]
    // ledger totals
    public var issued = 0
    public var committed = 0
    public var rejectedConflict = 0
    public var rejectedOther: [String: Int] = [:]
    public var lost = 0
    public var unresolved = 0
    public var earlyWarnings = 0
    public var duplicateTerminals = 0
    // storm classification (ground truth)
    public var byClass: [String: ClassStats] = [:]
    /// Disjoint (and layout) edits that were not committed and not explicitly reported lost: must be 0.
    public var lostDisjointEdits = 0
    public var lostSameValueEdits = 0
    /// Edits explicitly reported `lost` (a non-journaled client crashed before the server saw them): not silent.
    public var reportedLostEdits = 0
    public var silentOverwrites = 0
    public var finalDivergence = 0
    public var disjointFinalMismatch = 0
    public var unexplainedDiffRejects = 0
    public var conflictNoticesMissingInLog = 0
    public var diffRegistersChecked = 0
    public var visibilityLatencyMs = Percentiles()
    /// Same, excluding the first 10 s of the round (connection storm while 100 clients download the snapshot).
    public var visibilityLatencySteadyMs = Percentiles()
    public var ackLatencyMs = Percentiles()
    public var clientStats = DriverStatsDump()
    public var passed: Bool { violations.isEmpty && unresolved == 0 }
}

public struct ClassStats: Codable, Sendable {
    public var issued = 0, committed = 0, conflict = 0, otherRejected = 0, lost = 0, noTerminal = 0
}

public enum Checker {
    public static func fetchSnapshot(baseURL: String, doc: String) async throws -> SnapshotResponse {
        let (status, data) = try await HarnessHTTP.get("\(baseURL)/v1/docs/\(doc)/snapshot", timeout: .seconds(60))
        guard status == 200 else { throw HarnessError("snapshot: HTTP \(status)") }
        return try WireJSON.decode(SnapshotResponse.self, from: data)
    }

    public static func fetchLog(store: PostgresStore, doc: String, head: Int) async throws -> [LogEntry] {
        var log: [LogEntry] = []
        var cursor = 0
        while cursor < head {
            let chunk = try await store.entries(doc, after: cursor, through: min(head, cursor + 5000))
            guard !chunk.isEmpty else { break }
            log += chunk
            cursor = chunk.last!.seq
        }
        return log
    }

    /// Builds the evidence, runs I1-I6, the recovery-equivalence check and the ground-truth ledger checks.
    public static func check(doc: String, dir: String, clientIds: [String], plan: PlanKind, initial: Document,
                             store: PostgresStore, serverURL: String, extraViolations: [String] = []) async throws -> CheckReport {
        var report = CheckReport()
        guard let head = try await store.documentHead(doc) else { throw HarnessError("document \(doc) vanished") }
        report.head = head
        let log = try await fetchLog(store: store, doc: doc, head: head)
        let snap = try await fetchSnapshot(baseURL: serverURL, doc: doc)

        var pre = extraViolations
        if snap.seq != head { pre.append("RECOVERY: GET snapshot at seq \(snap.seq) but database head is \(head)") }
        // Recovery equivalence: latest durable snapshot + replay of the tail == full replay from the seed == what the server serves.
        if let loaded = try await store.load(doc) {
            do {
                let recovered = try Sequencer(snapshot: loaded.snapshot, tail: loaded.tail)
                if recovered.doc != snap.doc || recovered.seq != snap.seq { pre.append("RECOVERY: snapshot+replay state differs from the served state") }
            } catch { pre.append("RECOVERY: durable log is not replayable: \(error)") }
        }

        // Ledgers
        let ledger = LedgerReader.read(files: clientIds.map { "\(dir)/\($0).ledger.jsonl" })
        report.earlyWarnings = ledger.earlyWarnings

        // Client finals
        var clients: [ClientEvidence] = []
        for id in clientIds {
            if let data = FileManager.default.contents(atPath: "\(dir)/\(id).final.json"),
               let fin = try? WireJSON.decode(ClientFinal.self, from: data) {
                clients.append(ClientEvidence(id: id, confirmed: fin.confirmed, view: fin.view, unresolved: fin.unresolved))
                pre += fin.violations.map { "CLIENT \(id): \($0)" }
                report.clientStats.posts += fin.stats.posts
                report.clientStats.postFailures += fin.stats.postFailures
                report.clientStats.streamsOpened += fin.stats.streamsOpened
                report.clientStats.streamsLost += fin.stats.streamsLost
                report.clientStats.snapshots += fin.stats.snapshots
                report.clientStats.commits += fin.stats.commits
            } else {
                clients.append(ClientEvidence(id: id, confirmed: nil, view: nil, unresolved: 0))
            }
        }

        var same: Set<OpKey> = []
        for (k, i) in ledger.issued where Classifier.classify(i.op, plan: plan) == .sameValue { same.insert(k) }
        let evidence = Evidence(initial: initial, log: log, serverDoc: snap.doc, clients: clients, issued: ledger.issued,
                                terminals: ledger.terminals, sameValueOps: same, allowRepeatedIdenticalTerminals: true, priorViolations: pre)
        report.violations = Invariants.check(evidence)
        for v in report.violations { report.violationKinds[String(v.prefix { $0 != ":" && $0 != " " }), default: 0] += 1 }
        report.silentOverwrites = report.violations.filter { $0.hasPrefix("I2") }.count
        report.finalDivergence = report.violations.filter { $0.hasPrefix("I3") }.count

        // Terminal statistics, per class
        var inLog: [OpKey: LogEntry] = [:]
        for e in log { inLog[OpKey(client: e.client, cseq: e.cseq)] = e }
        for (key, issued) in ledger.issued {
            report.issued += 1
            let cls = Classifier.classify(issued.op, plan: plan)
            var cs = report.byClass[cls.rawValue] ?? ClassStats()
            cs.issued += 1
            let terms = ledger.terminals[key] ?? []
            switch terms.first {
            case .committed?: report.committed += 1; cs.committed += 1
            case .rejected(let r)?:
                if case .conflict = r { report.rejectedConflict += 1; cs.conflict += 1 } else { report.rejectedOther[r.name, default: 0] += 1; cs.otherRejected += 1 }
            case .lost?: report.lost += 1; cs.lost += 1
            case nil: report.unresolved += 1; cs.noTerminal += 1
            }
            if Set(terms).count < terms.count { report.duplicateTerminals += 1 }
            report.byClass[cls.rawValue] = cs
            let committed: Bool = { if case .committed? = terms.first { return true }; return false }()
            let reportedLost: Bool = { if case .lost? = terms.first { return true }; return false }()
            if reportedLost { report.reportedLostEdits += 1 }
            switch cls {
            case .disjoint, .layout: if !committed && !reportedLost { report.lostDisjointEdits += 1 }
            case .sameValue: if !committed && !reportedLost { report.lostSameValueEdits += 1 }
            case .diffValue:
                if case .rejected(let r)? = terms.first {
                    if case .conflict(let c) = r {
                        if c.seq < 1 || c.seq > log.count || log[c.seq - 1].client != c.by { report.conflictNoticesMissingInLog += 1 }
                    } else { report.unexplainedDiffRejects += 1 }
                } else if !committed { report.unexplainedDiffRejects += 1 }
            case .chaos: break
            }
        }

        if plan != .chaos { report.disjointFinalMismatch = disjointFinalMismatches(log: log, ledger: ledger, serverDoc: snap.doc, plan: plan) }
        report.diffRegistersChecked = Set(ledger.issued.values.compactMap { i -> String? in
            if case .setField("hot", .config(let p), _) = i.op, p.first == "diff" { return p.joined(separator: ".") }
            return nil
        }).count

        // Latency: issue -> (acked) and issue -> visible on every client.
        var ack: [Double] = []
        var visible: [Double] = []
        var visibleSteady: [Double] = []
        let firstIssue = ledger.issuedAt.values.min() ?? 0
        let applied = loadApplied(dir: dir, clientIds: clientIds)
        var allVisibleAt = [Int64](repeating: 0, count: head + 1)
        if !applied.isEmpty {
            for s in 1...max(head, 1) where s <= head {
                var worst: Int64 = 0
                var complete = true
                for a in applied { if s < a.count, a[s] > 0 { worst = max(worst, a[s]) } else { complete = false; break } }
                if complete { allVisibleAt[s] = worst }
            }
        }
        for (key, terms) in ledger.terminals {
            guard case .committed(let seq)? = terms.first, let t0 = ledger.issuedAt[key] else { continue }
            if let t1 = ledger.terminalAt[key] { ack.append(Double(t1 - t0)) }
            if seq <= head, allVisibleAt[seq] > 0 {
                let l = Double(max(0, allVisibleAt[seq] - t0))
                visible.append(l)
                if t0 - firstIssue > 10_000 { visibleSteady.append(l) }
            }
        }
        report.ackLatencyMs = Percentiles(ack)
        report.visibilityLatencyMs = Percentiles(visible)
        report.visibilityLatencySteadyMs = Percentiles(visibleSteady)
        return report
    }

    /// Per client: min over incarnations of the time each seq was applied; returns one array per client.
    static func loadApplied(dir: String, clientIds: [String]) -> [[Int64]] {
        var out: [[Int64]] = []
        for id in clientIds {
            var merged: [Int64] = []
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("\(id).applied.") && $0.hasSuffix(".json") }
            for f in files {
                guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"), let t = try? JSONDecoder().decode(AppliedTimes.self, from: data) else { continue }
                if merged.count < t.at.count { merged += [Int64](repeating: 0, count: t.at.count - merged.count) }
                for (i, v) in t.at.enumerated() where v > 0 { merged[i] = merged[i] == 0 ? v : min(merged[i], v) }
            }
            if !merged.isEmpty { out.append(merged) }
        }
        return out
    }

    // MARK: ground truth for the disjoint class

    private static func get(_ cfg: [String: Value], _ path: [String]) -> Value? {
        var cur: Value = .map(cfg)
        for k in path {
            guard case .map(let m) = cur, let n = m[k] else { return nil }
            cur = n
        }
        return cur
    }

    /// Every disjoint register has exactly one writer, so its final value must be that writer's last committed write.
    /// List items must be exactly the items the owner inserted and did not remove, with the last committed value.
    static func disjointFinalMismatches(log: [LogEntry], ledger: LedgerSummary, serverDoc: Document, plan: PlanKind) -> Int {
        var mismatches = 0
        var expectedFields: [String: Value] = [:]   // "node|title" / "node|a.b.c"
        var itemValues: [ItemID: Value] = [:]
        var removed: Set<ItemID> = []
        for e in log {
            let cls = Classifier.classify(e.op, plan: plan)
            guard cls == .disjoint else { continue }
            switch e.op {
            case .setField(let n, .title, let v): expectedFields["\(n)|title"] = v
            case .setField(let n, .config(let p), let v): expectedFields["\(n)|\(p.joined(separator: "."))"] = v
            case .insertItem(_, _, let item, _): itemValues[item.id] = item.value
            case .updateItem(_, _, let id, let v): if itemValues[id] != nil, !removed.contains(id) { itemValues[id] = v }
            case .removeItem(_, _, let id): removed.insert(id)
            default: break
            }
        }
        for (k, v) in expectedFields {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard let node = serverDoc.nodes[parts[0]] else { mismatches += 1; continue }
            let actual: Value? = parts[1] == "title" ? .string(node.title) : get(node.config, parts[1].split(separator: ".").map(String.init))
            if actual != v { mismatches += 1 }
        }
        var present: [ItemID: Value] = [:]
        if case .items(let xs)? = serverDoc.nodes["list"]?.config["outs"] { for i in xs { present[i.id] = i.value } }
        for (id, v) in itemValues {
            if removed.contains(id) { if present[id] != nil { mismatches += 1 } } else if present[id] != v { mismatches += 1 }
        }
        // Items present that no one inserted (other than the seed items) would be corruption too.
        for id in present.keys where !id.hasPrefix("seed-") && itemValues[id] == nil { mismatches += 1 }
        return mismatches
    }
}
