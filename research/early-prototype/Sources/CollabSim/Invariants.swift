import CollabCore

/// Independent reference model: replays the committed log with *flat, path-keyed* semantics that
/// share no code with `Document`. If the real document ever disagrees with this replay, either the
/// implementation or the rules have drifted.
struct Oracle {
    struct ONode: Equatable {
        var type: String
        var title: String
        var x: Int
        var y: Int
        var leaves: [[String]: Value]
    }
    struct Touch {
        var node: NodeID
        /// nil = "something about the node changed" (matters only to deletes).
        var field: FieldKey?
    }

    var nodes: [NodeID: ONode] = [:]
    var edges: [EdgeID: Edge] = [:]

    init(_ doc: Document) {
        for n in doc.nodes.values { nodes[n.id] = Self.make(n) }
        edges = doc.edges
    }

    static func make(_ n: Node) -> ONode {
        var leaves: [[String]: Value] = [:]
        for (k, v) in n.config { flatten([k], v, into: &leaves) }
        return ONode(type: n.type, title: n.title, x: n.x, y: n.y, leaves: leaves)
    }

    static func flatten(_ path: [String], _ v: Value, into out: inout [[String]: Value]) {
        if case .map(let m) = v, !m.isEmpty {
            for (k, c) in m { flatten(path + [k], c, into: &out) }
        } else {
            out[path] = v
        }
    }

    static func hasPrefix(_ path: [String], _ prefix: [String]) -> Bool {
        path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix
    }

    static func breakRefs(_ v: Value, _ node: NodeID) -> (Value, Bool) {
        switch v {
        case .ref(let r) where r.node == node: return (.brokenRef(r), true)
        case .list(let items):
            let r = items.map { breakRefs($0, node) }
            return (.list(r.map(\.0)), r.contains { $0.1 })
        default: return (v, false)
        }
    }

    /// Applies one committed entry and reports which (node, field) registers it wrote.
    mutating func apply(_ e: LogEntry) -> [Touch] {
        switch e.op {
        case .addNode(let n):
            nodes[n.id] = Self.make(n)
            return [Touch(node: n.id, field: nil)]
        case .removeNode(let d):
            var touches = [Touch(node: d, field: nil)]
            nodes[d] = nil
            edges = edges.filter { $0.value.source != d && $0.value.target != d }
            for id in nodes.keys.sorted() {
                for path in nodes[id]!.leaves.keys.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
                    let (nv, changed) = Self.breakRefs(nodes[id]!.leaves[path]!, d)
                    if changed {
                        nodes[id]!.leaves[path] = nv
                        touches.append(Touch(node: id, field: .config(path)))
                    }
                }
            }
            return touches
        case .moveNode(let id, let x, let y):
            nodes[id]?.x = x
            nodes[id]?.y = y
            return [Touch(node: id, field: .position)]
        case .setField(let id, let key, let value):
            switch key {
            case .title:
                if case .string(let s) = value { nodes[id]?.title = s }
            case .position: break
            case .config(let path):
                guard var n = nodes[id] else { break }
                for p in n.leaves.keys where Self.hasPrefix(p, path) { n.leaves[p] = nil }
                for p in n.leaves.keys where p.count < path.count && Self.hasPrefix(path, p) {
                    if n.leaves[p] == .map([:]) { n.leaves[p] = nil }
                }
                Self.flatten(path, value, into: &n.leaves)
                nodes[id] = n
            }
            return [Touch(node: id, field: key)]
        case .addEdge(let ed):
            edges[ed.id] = ed
            return [Touch(node: ed.source, field: nil), Touch(node: ed.target, field: nil)]
        case .removeEdge(let id):
            edges[id] = nil
            return []
        }
    }

    func matches(_ doc: Document) -> String? {
        if Set(nodes.keys) != Set(doc.nodes.keys) { return "node sets differ: oracle \(nodes.keys.sorted()) vs doc \(doc.nodes.keys.sorted())" }
        for id in nodes.keys.sorted() {
            let d = Self.make(doc.nodes[id]!)
            if d != nodes[id]! { return "node \(id) differs: oracle \(nodes[id]!) vs doc \(d)" }
        }
        if edges != doc.edges { return "edge sets differ" }
        return nil
    }
}

public enum Invariants {
    /// Checks every invariant on a settled world and returns human-readable violations (empty = pass).
    public static func check(_ w: World) -> [String] {
        var v = w.rec.violations
        guard let server = w.server else { return v + ["server is down at the end"] }
        let log = server.disk.fullLog

        // Log hygiene: contiguous seq, per-client cseq strictly increasing (no op committed twice).
        var lastCseq: [ClientID: Int] = [:]
        for (i, e) in log.enumerated() {
            if e.seq != i + 1 { v.append("LOG: seq gap at index \(i) (seq \(e.seq))") }
            if let l = lastCseq[e.client], e.cseq <= l { v.append("LOG: \(e.client) cseq \(e.cseq) committed again/out of order") }
            lastCseq[e.client] = e.cseq
        }
        if server.seq != log.count { v.append("LOG: server.seq \(server.seq) != log length \(log.count)") }

        // I1a: everything any client was told is committed is in the durable log, byte for byte.
        var inLog: [OpKey: LogEntry] = [:]
        for e in log { inLog[OpKey(client: e.client, cseq: e.cseq)] = e }
        for (key, terms) in w.rec.terminals {
            for t in terms {
                guard case .committed(let seq) = t else { continue }
                guard seq >= 1, seq <= log.count, log[seq - 1].client == key.client, log[seq - 1].cseq == key.cseq else {
                    v.append("I1: \(key.client)#\(key.cseq) acked at seq \(seq) but missing from durable log")
                    continue
                }
                if let issued = w.rec.issued[key], issued.op != log[seq - 1].op || issued.base != log[seq - 1].base {
                    v.append("I1: \(key.client)#\(key.cseq) logged op differs from the op the user made")
                }
            }
        }

        // I1b: final server state == replay of exactly the committed log (nothing acked lost,
        // nothing unacked applied). Also collects per-entry touches for I2.
        var oracle = Oracle(w.rec.initial)
        var touches: [[Oracle.Touch]] = []
        for e in log { touches.append(oracle.apply(e)) }
        if let diff = oracle.matches(server.doc) { v.append("I1: server state != replay of log: \(diff)") }

        // I2: no committed write overwrote a newer foreign write it had not seen. A write's targets are
        // exactly the registers it touched (for a delete: the node itself plus every field it rewrote).
        for e in log {
            switch e.op {
            case .setField, .moveNode, .removeNode: break
            default: continue
            }
            guard e.base + 1 < e.seq else { continue }
            for later in log[e.base..<(e.seq - 1)] where later.client != e.client {
                for t in touches[e.seq - 1] {
                    for u in touches[later.seq - 1] where u.node == t.node {
                        let hit = t.field == nil || (u.field != nil && u.field!.overlaps(t.field!))
                        if hit {
                            v.append("I2: seq \(e.seq) (\(e.client), base \(e.base)) overwrote unseen seq \(later.seq) (\(later.client)) on \(t.node)")
                        }
                    }
                }
            }
        }

        // I3: every client equals the server after quiescence.
        for s in w.slots {
            guard let c = s.client else { v.append("I3: \(s.id) is not running at the end"); continue }
            if c.confirmed != server.doc { v.append("I3: \(s.id) confirmed state != server") }
            if c.view != server.doc { v.append("I3: \(s.id) view != server") }
            if c.unresolvedCount != 0 { v.append("I5: \(s.id) still has \(c.unresolvedCount) unresolved ops") }
        }

        // I4: no dangling references anywhere (broken markers are the only allowed form).
        for p in server.doc.integrityProblems { v.append("I4: server \(p)") }
        for s in w.slots { for p in s.client?.view.integrityProblems ?? [] { v.append("I4: \(s.id) \(p)") } }

        // I5: every op the users made ends in exactly one explicit outcome, and the outcome is truthful.
        for (key, _) in w.rec.issued {
            let terms = w.rec.terminals[key] ?? []
            if terms.count != 1 { v.append("I5: \(key.client)#\(key.cseq) has \(terms.count) outcomes: \(terms)"); continue }
            switch terms[0] {
            case .committed: break  // checked against the log in I1a
            case .rejected, .lost:
                if inLog[key] != nil { v.append("I5: \(key.client)#\(key.cseq) reported \(terms[0]) but IS in the log") }
            }
        }
        for key in inLog.keys where w.rec.issued[key] == nil {
            v.append("LOG: \(key.client)#\(key.cseq) in log but never issued by a user")
        }
        for (key, terms) in w.rec.terminals where w.rec.issued[key] == nil {
            v.append("I5: outcome \(terms) for unknown op \(key.client)#\(key.cseq)")
        }
        for key in inLog.keys.sorted(by: { ($0.client, $0.cseq) < ($1.client, $1.cseq) }) {
            if !(w.rec.terminals[key] ?? []).contains(where: { if case .committed = $0 { return true }; return false }) {
                v.append("I1: \(key.client)#\(key.cseq) is in the log but its client never learned it was saved")
            }
        }
        return v
    }
}
