import CollabCore

public struct OpKey: Hashable, Sendable, Comparable {
    public var client: ClientID
    public var cseq: Int
    public init(client: ClientID, cseq: Int) {
        self.client = client
        self.cseq = cseq
    }
    public static func < (a: OpKey, b: OpKey) -> Bool { (a.client, a.cseq) < (b.client, b.cseq) }
}

public struct Issued: Sendable {
    public var op: Op
    public var base: Int
    public init(op: Op, base: Int) {
        self.op = op
        self.base = base
    }
}

/// Terminal outcome as the *user would have seen it* (taken from client events, not server state).
public enum Terminal: Hashable, Sendable {
    case committed(seq: Int)
    case rejected(RejectReason)
    case lost
}

public struct ClientEvidence: Sendable {
    public var id: ClientID
    /// nil = the client is not running at the end (a violation by itself).
    public var confirmed: Document?
    public var view: Document?
    public var unresolved: Int
    public init(id: ClientID, confirmed: Document?, view: Document?, unresolved: Int) {
        self.id = id
        self.confirmed = confirmed
        self.view = view
        self.unresolved = unresolved
    }
}

/// Everything the checker needs, gathered by the simulator or by the chaos/storm harness.
public struct Evidence: Sendable {
    public var initial: Document
    /// The full committed log, seq 1...n.
    public var log: [LogEntry]
    public var serverDoc: Document
    public var clients: [ClientEvidence]
    public var issued: [OpKey: Issued]
    /// Every terminal event each client reported per op.
    public var terminals: [OpKey: [Terminal]]
    /// Ops known to be same-value writes (hot registers always written with one constant): they must
    /// never be rejected as a conflict (rule: same-value writes are not conflicts).
    public var sameValueOps: Set<OpKey>
    /// Real clients crash between reporting an outcome and persisting it, so the same outcome may be
    /// reported again after a restart. The simulator reports exactly once.
    public var allowRepeatedIdenticalTerminals: Bool
    public var priorViolations: [String]

    public init(initial: Document, log: [LogEntry], serverDoc: Document, clients: [ClientEvidence],
                issued: [OpKey: Issued], terminals: [OpKey: [Terminal]], sameValueOps: Set<OpKey> = [],
                allowRepeatedIdenticalTerminals: Bool = false, priorViolations: [String] = []) {
        self.initial = initial
        self.log = log
        self.serverDoc = serverDoc
        self.clients = clients
        self.issued = issued
        self.terminals = terminals
        self.sameValueOps = sameValueOps
        self.allowRepeatedIdenticalTerminals = allowRepeatedIdenticalTerminals
        self.priorViolations = priorViolations
    }
}

public enum Invariants {
    /// Checks every invariant on a settled system and returns human-readable violations (empty = pass).
    /// Violation strings start with the invariant name ("I1", "I2", "LOG", ...), then a colon.
    public static func check(_ ev: Evidence) -> [String] {
        var v = ev.priorViolations
        let log = ev.log

        // Log hygiene: contiguous seq, per-client cseq strictly increasing (no op committed twice).
        var lastCseq: [ClientID: Int] = [:]
        for (i, e) in log.enumerated() {
            if e.seq != i + 1 { v.append("LOG: seq gap at index \(i) (seq \(e.seq))") }
            if let l = lastCseq[e.client], e.cseq <= l { v.append("LOG: \(e.client) cseq \(e.cseq) committed again/out of order") }
            lastCseq[e.client] = e.cseq
        }

        // I1a: everything any client was told is committed is in the durable log, byte for byte.
        var inLog: [OpKey: LogEntry] = [:]
        for e in log { inLog[OpKey(client: e.client, cseq: e.cseq)] = e }
        for (key, terms) in ev.terminals {
            for t in terms {
                guard case .committed(let seq) = t else { continue }
                guard seq >= 1, seq <= log.count, log[seq - 1].client == key.client, log[seq - 1].cseq == key.cseq else {
                    v.append("I1: \(key.client)#\(key.cseq) acked at seq \(seq) but missing from durable log")
                    continue
                }
                if let issued = ev.issued[key], issued.op != log[seq - 1].op || issued.base != log[seq - 1].base {
                    v.append("I1: \(key.client)#\(key.cseq) logged op differs from the op the user made")
                }
            }
        }

        // I1b: final server state == replay of exactly the committed log (nothing acked lost,
        // nothing unacked applied). Also collects per-entry touches for I2.
        var oracle = Oracle(ev.initial)
        var touches: [[Oracle.Touch]] = []
        for e in log { touches.append(oracle.apply(e)) }
        if let diff = oracle.matches(ev.serverDoc) { v.append("I1: server state != replay of log: \(diff)") }

        // I2: no committed content write overwrote a newer foreign write it had not seen. A write's targets
        // are exactly the registers it changed (for a delete: the node itself plus every field it rewrote).
        // Same-value writes changed nothing, so they have no targets. Layout (moveNode) has none either.
        for e in log {
            switch e.op {
            case .setField, .removeNode, .updateItem, .removeItem: break
            default: continue
            }
            guard e.base + 1 < e.seq else { continue }
            for later in log[e.base..<(e.seq - 1)] where later.client != e.client {
                for t in touches[e.seq - 1] {
                    for u in touches[later.seq - 1] where u.node == t.node {
                        let hit = t.field == nil || (u.field != nil && u.field!.overlaps(t.field!))
                        guard hit else { continue }
                        // A register keeps only its last write. If the writer itself wrote an overlapping register after the
                        // foreign write (its own op passed the check against everything before it), the foreign value
                        // had already been seen and deliberately replaced: bases need not be monotone.
                        if let tf = t.field {
                            let shadowed = log[later.seq..<(e.seq - 1)].enumerated().contains { (i, mine) in
                                mine.client == e.client && touches[later.seq + i].contains { $0.node == t.node && $0.field?.overlaps(tf) == true }
                            }
                            if shadowed { continue }
                        }
                        v.append("I2: seq \(e.seq) (\(e.client), base \(e.base)) overwrote unseen seq \(later.seq) (\(later.client)) on \(t.node)")
                    }
                }
            }
        }

        // Layout: last writer wins in server order => the final position is the last committed write.
        var lastPos: [NodeID: (Int, Int)] = [:]
        for e in log {
            switch e.op {
            case .addNode(let n): lastPos[n.id] = (n.x, n.y)
            case .moveNode(let id, let x, let y): lastPos[id] = (x, y)
            default: break
            }
        }
        for (id, n) in ev.serverDoc.nodes {
            let expected = lastPos[id] ?? { () -> (Int, Int)? in
                guard let n0 = ev.initial.nodes[id] else { return nil }
                return (n0.x, n0.y)
            }()
            if let p = expected, p != (n.x, n.y) {
                v.append("LWW: node \(id) is at (\(n.x),\(n.y)) but the last committed write put it at \(p)")
            }
        }

        // I3: every client equals the server after quiescence.
        for c in ev.clients {
            guard let confirmed = c.confirmed, let view = c.view else { v.append("I3: \(c.id) is not running at the end"); continue }
            if confirmed != ev.serverDoc { v.append("I3: \(c.id) confirmed state != server") }
            if view != ev.serverDoc { v.append("I3: \(c.id) view != server") }
            if c.unresolved != 0 { v.append("I5: \(c.id) still has \(c.unresolved) unresolved ops") }
        }

        // I4: no dangling references anywhere (broken markers are the only allowed form).
        for p in ev.serverDoc.integrityProblems { v.append("I4: server \(p)") }
        for c in ev.clients { for p in c.view?.integrityProblems ?? [] { v.append("I4: \(c.id) \(p)") } }

        // I5: every op the users made ends in exactly one explicit outcome, and the outcome is truthful.
        for key in ev.issued.keys.sorted() {
            let terms = ev.terminals[key] ?? []
            let distinct = Set(terms)
            let ok = ev.allowRepeatedIdenticalTerminals ? distinct.count == 1 : terms.count == 1
            if !ok { v.append("I5: \(key.client)#\(key.cseq) has \(terms.count) outcomes: \(terms)"); continue }
            switch terms[0] {
            case .committed: break  // checked against the log in I1a
            case .rejected, .lost:
                if inLog[key] != nil { v.append("I5: \(key.client)#\(key.cseq) reported \(terms[0]) but IS in the log") }
            }
        }
        for key in inLog.keys where ev.issued[key] == nil {
            v.append("LOG: \(key.client)#\(key.cseq) in log but never issued by a user")
        }
        for (key, terms) in ev.terminals where ev.issued[key] == nil {
            v.append("I5: outcome \(terms) for unknown op \(key.client)#\(key.cseq)")
        }
        for key in inLog.keys.sorted() {
            if !(ev.terminals[key] ?? []).contains(where: { if case .committed = $0 { return true }; return false }) {
                v.append("I1: \(key.client)#\(key.cseq) is in the log but its client never learned it was saved")
            }
        }

        // I6: same-value writes are never conflicts: they must all end up committed.
        for key in ev.sameValueOps.sorted() {
            for t in ev.terminals[key] ?? [] {
                if case .rejected(.conflict(let c)) = t { v.append("I6: same-value write \(key.client)#\(key.cseq) was rejected as a conflict: \(c)") }
            }
        }
        return v
    }
}
