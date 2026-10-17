/// The workflow graph plus the version metadata needed to enforce the conflict rules.
/// Server and clients run the *same* `validate`/`apply` code, so a committed op has the same
/// effect everywhere (including cascades), and convergence is plain structural equality.
public struct Document: Hashable, Codable, Sendable {
    public private(set) var nodes: [NodeID: Node]
    public private(set) var edges: [EdgeID: Edge]
    /// Tombstones. Ids are never reused, so an edit to a deleted node is always recognisable.
    public private(set) var deletedNodes: [NodeID: Stamp] = [:]
    public private(set) var deletedEdges: [EdgeID: Stamp] = [:]
    /// Last write per field register. Descendant paths are pruned when an ancestor is rewritten.
    private(set) var fieldStamps: [NodeID: [FieldKey: Stamp]] = [:]
    /// Last seq at which each client touched a node in any way (used for delete-vs-edit).
    private(set) var touches: [NodeID: [ClientID: Int]] = [:]

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        self.edges = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    }

    // MARK: - Integrity (used by invariant I4)

    /// Human-readable integrity problems: dangling live refs, edges to missing nodes.
    public var integrityProblems: [String] {
        var problems: [String] = []
        for id in nodes.keys.sorted() {
            for key in nodes[id]!.config.keys.sorted() {
                for r in nodes[id]!.config[key]!.liveRefs where nodes[r.node] == nil {
                    problems.append("node \(id).\(key) has dangling ref to \(r.node)")
                }
            }
        }
        for id in edges.keys.sorted() {
            let e = edges[id]!
            if nodes[e.source] == nil || nodes[e.target] == nil {
                problems.append("edge \(id) has missing endpoint")
            }
        }
        return problems
    }

    // MARK: - Validation

    /// Decides whether `op`, created by `client` against server version `base`, may be applied now.
    ///
    /// Stale-write rule: a write to a field is refused if another client wrote an overlapping field
    /// after `base`. The newer value always wins; the stale writer gets a `.conflict` notice.
    /// Writes by the same client never conflict with themselves: its ops are processed in order and
    /// each op's base is >= the previous one's, so by induction no foreign write can hide behind the
    /// client's own last write.
    ///
    /// Delete vs. edit: deleting a node conflicts with any modification of that node by someone else
    /// after `base`, and with any such write to a field that references it (the delete would rewrite
    /// that field to a broken marker). Edits to a deleted node get `.nodeDeleted`.
    public func validate(_ op: Op, base: Int, by client: ClientID,
                         checkConflicts: Bool = true) throws(RejectReason) {
        switch op {
        case .addNode(let n):
            guard !n.id.isEmpty else { throw .invalid("empty node id") }
            guard nodes[n.id] == nil, deletedNodes[n.id] == nil else { throw .nodeExists(n.id) }
            for key in n.config.keys.sorted() { try checkValue(n.config[key]!, selfNode: n.id) }

        case .removeNode(let id):
            try requireLive(id)
            if checkConflicts {
                if let c = nodeConflict(id, base: base, client: client) { throw .conflict(c) }
                // The delete also rewrites every field that references this node (ref -> brokenRef).
                // Those are writes too: refuse if someone else wrote one of them after `base`.
                for other in nodes.keys.sorted() where other != id {
                    var cfg = nodes[other]!.config
                    for path in ConfigTree.breakRefs(in: &cfg, to: id) {
                        if let c = fieldConflict(other, .config(path), base: base, client: client) { throw .conflict(c) }
                    }
                }
            }

        case .moveNode(let id, _, _):
            try requireLive(id)
            if checkConflicts, let c = fieldConflict(id, .position, base: base, client: client) {
                throw .conflict(c)
            }

        case .setField(let id, let key, let value):
            try requireLive(id)
            switch key {
            case .position: throw .invalid("position is written with moveNode")
            case .title:
                guard case .string = value else { throw .invalid("title must be a string") }
            case .config(let path):
                guard ConfigTree.canSet(nodes[id]!.config, path) else { throw .invalid("bad path \(path)") }
                try checkValue(value, selfNode: nil)
            }
            if checkConflicts, let c = fieldConflict(id, key, base: base, client: client) { throw .conflict(c) }

        case .addEdge(let e):
            guard edges[e.id] == nil, deletedEdges[e.id] == nil else { throw .edgeExists(e.id) }
            try requireLive(e.source)
            try requireLive(e.target)
            for other in edges.values where other.source == e.source && other.sourceHandle == e.sourceHandle
                && other.target == e.target && other.targetHandle == e.targetHandle {
                throw .duplicateEdge(other.id)
            }

        case .removeEdge(let id):
            guard edges[id] != nil else { throw .edgeNotFound(id) }
        }
    }

    private func requireLive(_ id: NodeID) throws(RejectReason) {
        if nodes[id] != nil { return }
        throw deletedNodes[id] != nil ? .nodeDeleted(id) : .nodeNotFound(id)
    }

    /// Clients may only write live refs to existing nodes; broken markers are server-only.
    private func checkValue(_ v: Value, selfNode: NodeID?) throws(RejectReason) {
        if v.containsBrokenRef { throw .invalid("brokenRef is server-written only") }
        for r in v.liveRefs where nodes[r.node] == nil && r.node != selfNode {
            throw .danglingReference(r.node)
        }
    }

    private func fieldConflict(_ node: NodeID, _ field: FieldKey, base: Int, client: ClientID) -> Conflict? {
        var worst: Conflict?
        for (k, s) in fieldStamps[node] ?? [:] where k.overlaps(field) && s.seq > base && s.client != client {
            if worst == nil || s.seq > worst!.seq {
                worst = Conflict(node: node, field: k, seq: s.seq, by: s.client)
            }
        }
        return worst
    }

    private func nodeConflict(_ node: NodeID, base: Int, client: ClientID) -> Conflict? {
        var worst: Conflict?
        for (c, seq) in touches[node] ?? [:] where c != client && seq > base {
            if worst == nil || seq > worst!.seq { worst = Conflict(node: node, field: nil, seq: seq, by: c) }
        }
        return worst
    }

    // MARK: - Apply

    /// Applies a validated op. Never traps on invalid input (it just ignores it) because clients feed
    /// it with server-committed entries; callers that care re-validate first.
    public mutating func apply(_ op: Op, at stamp: Stamp, defects: ProtocolDefects = []) {
        switch op {
        case .addNode(let n):
            guard nodes[n.id] == nil, deletedNodes[n.id] == nil else { return }
            nodes[n.id] = n
            touch(n.id, stamp)

        case .removeNode(let id):
            guard nodes[id] != nil else { return }
            nodes[id] = nil
            fieldStamps[id] = nil
            touches[id] = nil
            deletedNodes[id] = stamp
            for eid in edges.keys.sorted() where edges[eid]!.source == id || edges[eid]!.target == id {
                edges[eid] = nil
                deletedEdges[eid] = stamp
            }
            if !defects.contains(.skipBrokenMarkers) {
                for other in nodes.keys.sorted() {
                    var cfg = nodes[other]!.config
                    let changed = ConfigTree.breakRefs(in: &cfg, to: id)
                    guard !changed.isEmpty else { continue }
                    nodes[other]!.config = cfg
                    for path in changed { stampField(other, .config(path), stamp) }
                    touch(other, stamp)
                }
            }

        case .moveNode(let id, let x, let y):
            guard nodes[id] != nil else { return }
            nodes[id]!.x = x
            nodes[id]!.y = y
            stampField(id, .position, stamp)
            touch(id, stamp)

        case .setField(let id, let key, let value):
            guard nodes[id] != nil else { return }
            switch key {
            case .position: return
            case .title:
                guard case .string(let s) = value else { return }
                nodes[id]!.title = s
            case .config(let path):
                guard ConfigTree.canSet(nodes[id]!.config, path) else { return }
                ConfigTree.set(&nodes[id]!.config, path[...], value)
            }
            stampField(id, key, stamp)
            touch(id, stamp)

        case .addEdge(let e):
            guard edges[e.id] == nil, deletedEdges[e.id] == nil,
                  nodes[e.source] != nil, nodes[e.target] != nil else { return }
            edges[e.id] = e
            touch(e.source, stamp)
            touch(e.target, stamp)

        case .removeEdge(let id):
            guard edges[id] != nil else { return }
            edges[id] = nil
            deletedEdges[id] = stamp
        }
    }

    private mutating func touch(_ node: NodeID, _ stamp: Stamp) {
        touches[node, default: [:]][stamp.client] = stamp.seq
    }

    private mutating func stampField(_ node: NodeID, _ key: FieldKey, _ stamp: Stamp) {
        var stamps = fieldStamps[node] ?? [:]
        if case .config(let path) = key {
            // Rewriting an ancestor subsumes (and makes redundant) the stamps of its descendants.
            for k in stamps.keys {
                if case .config(let q) = k, q.count > path.count, Array(q.prefix(path.count)) == path {
                    stamps[k] = nil
                }
            }
        }
        stamps[key] = stamp
        fieldStamps[node] = stamps
    }
}
