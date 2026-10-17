/// The workflow graph plus the version metadata needed to enforce the conflict rules.
/// Server and clients run the *same* `validate`/`apply` code, so a committed op has the same
/// effect everywhere (including cascades), and convergence is plain structural equality.
///
/// Conflict policy (see docs/protocol.md, "Conflict rules"):
/// - content registers (title, config paths, list items, node/edge existence) are stale-write protected;
/// - a stale write whose value equals the current value is a success and a no-op (same-value rule);
/// - layout (`moveNode`) is last-writer-wins in server order and is never rejected for staleness.
public struct Document: Hashable, Sendable {
    public private(set) var nodes: [NodeID: Node]
    public private(set) var edges: [EdgeID: Edge]
    /// Tombstones. Ids are never reused, so an edit to a deleted node is always recognisable.
    public private(set) var deletedNodes: [NodeID: Stamp] = [:]
    public private(set) var deletedEdges: [EdgeID: Stamp] = [:]
    public private(set) var deletedItems: [ItemID: Stamp] = [:]
    /// Last write per content register. Descendant paths are pruned when an ancestor is rewritten.
    public private(set) var fieldStamps: [NodeID: [FieldKey: Stamp]] = [:]
    /// Last seq at which each client changed a node's content in any way (used for delete-vs-edit).
    public private(set) var touches: [NodeID: [ClientID: Int]] = [:]

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        self.edges = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    }

    /// Full-state initializer used when decoding a snapshot.
    init(nodes: [Node], edges: [Edge], deletedNodes: [NodeID: Stamp], deletedEdges: [EdgeID: Stamp],
         deletedItems: [ItemID: Stamp], fieldStamps: [NodeID: [FieldKey: Stamp]], touches: [NodeID: [ClientID: Int]]) {
        self.init(nodes: nodes, edges: edges)
        self.deletedNodes = deletedNodes
        self.deletedEdges = deletedEdges
        self.deletedItems = deletedItems
        self.fieldStamps = fieldStamps
        self.touches = touches
    }

    // MARK: - Integrity (used by invariant I4)

    /// Human-readable integrity problems: dangling live refs, edges to missing nodes.
    public var integrityProblems: [String] {
        var problems: [String] = []
        for id in nodes.keys.sorted() {
            for key in nodes[id]!.config.keys.sorted() {
                for r in nodes[id]!.config[key]!.liveRefs {
                    if nodes[r.node] == nil {
                        problems.append("node \(id).\(key) has dangling ref to \(r.node)")
                    } else if let outs = Self.declaredOutputs(of: nodes[r.node]!), !outs.contains(r.output) {
                        problems.append("node \(id).\(key) has dangling ref to \(r.node).\(r.output) (no such output)")
                    }
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

    /// The config key of a node's declared outputs (protocol 1.4).
    public static let outputsKey = "outputs"

    /// A node's declared outputs: the names of the items of its `outputs` keyed list (an item's `name`, or its id when it
    /// has none), or nil if it has no such list (then any output name is accepted, e.g. the fixed outputs of an LLM node).
    /// References to a node with declared outputs must name one of them.
    public static func declaredOutputs(of node: Node) -> Set<String>? {
        guard case .items(let xs)? = node.config[outputsKey] else { return nil }
        return Set(xs.map(outputName))
    }

    static func outputName(_ item: Item) -> String {
        if case .map(let m) = item.value, case .string(let n)? = m["name"] { return n }
        return item.id
    }

    /// The output name that `op` takes away from `node` (removing or renaming an output item), if no other item of the
    /// list still declares it. References to that name break, like references to a deleted node.
    func outputNameRemoved(by op: Op) -> (node: NodeID, name: String)? {
        let node: NodeID, itemId: ItemID, newValue: Value?
        switch op {
        case .removeItem(let n, let path, let id) where path == [Self.outputsKey]: (node, itemId, newValue) = (n, id, nil)
        case .updateItem(let n, let path, let id, let v) where path == [Self.outputsKey]: (node, itemId, newValue) = (n, id, v)
        default: return nil
        }
        guard let n = nodes[node], case .items(let xs)? = n.config[Self.outputsKey],
              let item = xs.first(where: { $0.id == itemId }) else { return nil }
        let old = Self.outputName(item)
        if let v = newValue, Self.outputName(Item(id: itemId, value: v)) == old { return nil }
        if xs.contains(where: { $0.id != itemId && Self.outputName($0) == old }) { return nil }
        return (node, old)
    }

    // MARK: - Validation

    /// Decides whether `op`, created by `client` against server version `base`, may be applied now.
    ///
    /// Stale-write rule: a write to a content register is refused if another client wrote an
    /// overlapping register after `base` AND the new value differs from the current one. The newer value
    /// always wins; the stale writer gets a `.conflict` notice. Writing the value that is already
    /// there is a success (no-op) even on a stale base.
    ///
    /// Writes by the same client never conflict with their own earlier writes. This does NOT assume bases are
    /// monotone: a register records only its LAST write, and a client's earlier write to it passed this very check
    /// against everything foreign before it, so whatever it overwrote had already been seen by that client.
    ///
    /// Delete vs. edit: deleting a node conflicts with any content modification of that node by someone
    /// else after `base`, and with any such write to a field that references it (the delete would rewrite
    /// that field to a broken marker). Edits to a deleted node get `.nodeDeleted`.
    public func validate(_ op: Op, base: Int, by client: ClientID,
                         checkConflicts: Bool = true, defects: ProtocolDefects = []) throws(RejectReason) {
        switch op {
        case .addNode(let n):
            guard !n.id.isEmpty else { throw .invalid("empty node id") }
            guard nodes[n.id] == nil, deletedNodes[n.id] == nil else { throw .nodeExists(n.id) }
            for key in n.config.keys.sorted() {
                guard !key.hasPrefix("$") else { throw .invalid("config key \(key) is reserved") }
                try checkValue(n.config[key]!, selfNode: n.id)
            }

        case .removeNode(let id):
            try requireLive(id)
            if checkConflicts {
                if let c = nodeConflict(id, base: base, client: client) { throw .conflict(c) }
                // The delete also rewrites every field that references this node (ref -> brokenRef).
                // Those are writes too: refuse if someone else wrote one of them after `base`.
                for other in nodes.keys.sorted() where other != id {
                    var cfg = nodes[other]!.config
                    for key in ConfigTree.breakRefs(in: &cfg, to: id) {
                        if let c = fieldConflict(other, key, base: base, client: client) { throw .conflict(c) }
                    }
                }
            }

        case .moveNode(let id, _, _):
            try requireLive(id)

        case .setField(let id, let key, let value):
            try requireLive(id)
            let current: Value?
            switch key {
            case .item: throw .invalid("list items are written with the item ops")
            case .title:
                guard case .string = value else { throw .invalid("title must be a string") }
                current = .string(nodes[id]!.title)
            case .config(let path):
                guard ConfigTree.canSet(nodes[id]!.config, path) else { throw .invalid("bad path \(path)") }
                guard !path.contains(where: { $0.hasPrefix("$") }) else { throw .invalid("reserved key in path") }
                try checkValue(value, selfNode: nil)
                current = ConfigTree.get(nodes[id]!.config, path)
            }
            try checkStale(id, key, base: base, client: client, isSameValue: current == value,
                           enabled: checkConflicts, defects: defects)

        case .addEdge(let e):
            guard !e.id.isEmpty else { throw .invalid("empty edge id") }
            guard edges[e.id] == nil, deletedEdges[e.id] == nil else { throw .edgeExists(e.id) }
            try requireLive(e.source)
            try requireLive(e.target)
            for other in edges.values where other.source == e.source && other.sourceHandle == e.sourceHandle
                && other.target == e.target && other.targetHandle == e.targetHandle {
                throw .duplicateEdge(other.id)
            }

        case .removeEdge(let id):
            guard edges[id] != nil else { throw .edgeNotFound(id) }

        case .insertItem(let id, let path, let item, _):
            try requireLive(id)
            guard !path.isEmpty, ConfigTree.canSet(nodes[id]!.config, path),
                  !path.contains(where: { $0.hasPrefix("$") }) else { throw .invalid("bad list path \(path)") }
            guard !item.id.isEmpty else { throw .invalid("empty item id") }
            switch ConfigTree.list(in: nodes[id]!.config, at: path) {
            case .notAList: throw .invalid("\(path) is not a keyed list")
            case .found(let items): if items.contains(where: { $0.id == item.id }) { throw .itemExists(item.id) }
            case .absent: break
            }
            guard deletedItems[item.id] == nil else { throw .itemExists(item.id) }
            try checkValue(item.value, selfNode: nil)

        case .removeItem(let id, let path, let itemId):
            try requireLive(id)
            switch try lookupItem(id, path, itemId, tombstoneIsSuccess: true) {
            case .tombstoned: return  // already gone: the intended end state holds (same-value rule)
            case .present:
                if checkConflicts, let c = fieldConflict(id, .item(path, itemId), base: base, client: client) {
                    throw .conflict(c)
                }
                // Removing a declared output rewrites every field that references it (ref -> brokenRef); like a node
                // delete, refuse if someone else wrote one of those fields after `base`.
                if checkConflicts { try checkOutputRemoval(op, base: base, client: client) }
            }

        case .updateItem(let id, let path, let itemId, let value):
            try requireLive(id)
            guard case .present(let existing) = try lookupItem(id, path, itemId, tombstoneIsSuccess: false) else { return }
            try checkValue(value, selfNode: nil)
            try checkStale(id, .item(path, itemId), base: base, client: client, isSameValue: existing == value,
                           enabled: checkConflicts, defects: defects)
            if checkConflicts { try checkOutputRemoval(op, base: base, client: client) }  // renaming an output
        }
    }

    /// Removing or renaming a declared output rewrites every field that references its name (ref -> brokenRef); like a
    /// node delete, refuse if someone else wrote one of those fields after `base`.
    private func checkOutputRemoval(_ op: Op, base: Int, client: ClientID) throws(RejectReason) {
        guard let (node, name) = outputNameRemoved(by: op) else { return }
        for other in nodes.keys.sorted() {
            var cfg = nodes[other]!.config
            for key in ConfigTree.breakRefs(in: &cfg, matching: { $0.node == node && $0.output == name }) {
                if let c = fieldConflict(other, key, base: base, client: client) { throw .conflict(c) }
            }
        }
    }

    private mutating func breakOutputRefs(_ removed: (node: NodeID, name: String)?, _ stamp: Stamp, _ defects: ProtocolDefects) {
        guard let (node, name) = removed, !defects.contains(.skipBrokenMarkers) else { return }
        for other in nodes.keys.sorted() {
            var cfg = nodes[other]!.config
            let changed = ConfigTree.breakRefs(in: &cfg, matching: { $0.node == node && $0.output == name })
            guard !changed.isEmpty else { continue }
            nodes[other]!.config = cfg
            for key in changed { stampField(other, key, stamp) }
            touch(other, stamp)
        }
    }

    private enum ItemState { case present(Value), tombstoned }

    private func lookupItem(_ node: NodeID, _ path: [String], _ id: ItemID,
                            tombstoneIsSuccess: Bool) throws(RejectReason) -> ItemState {
        if case .found(let items) = ConfigTree.list(in: nodes[node]!.config, at: path),
           let item = items.first(where: { $0.id == id }) {
            return .present(item.value)
        }
        if deletedItems[id] != nil {
            if tombstoneIsSuccess { return .tombstoned }
            throw .itemDeleted(id)
        }
        throw .itemNotFound(id)
    }

    private func checkStale(_ node: NodeID, _ key: FieldKey, base: Int, client: ClientID, isSameValue: Bool,
                            enabled: Bool, defects: ProtocolDefects) throws(RejectReason) {
        guard enabled, let c = fieldConflict(node, key, base: base, client: client) else { return }
        if isSameValue && !defects.contains(.sameValueConflicts) { return }
        throw .conflict(c)
    }

    private func requireLive(_ id: NodeID) throws(RejectReason) {
        if nodes[id] != nil { return }
        throw deletedNodes[id] != nil ? .nodeDeleted(id) : .nodeNotFound(id)
    }

    /// Clients may only write live refs to existing nodes; broken markers are server-only.
    private func checkValue(_ v: Value, selfNode: NodeID?) throws(RejectReason) {
        if let p = v.structuralProblem { throw .invalid(p) }
        if v.containsBrokenRef { throw .invalid("brokenRef is server-written only") }
        for r in v.liveRefs where r.node != selfNode {
            guard let target = nodes[r.node] else { throw .danglingReference(r.node) }
            if let outs = Self.declaredOutputs(of: target), !outs.contains(r.output) { throw .danglingReference(r.node) }
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
                    for key in changed { stampField(other, key, stamp) }
                    touch(other, stamp)
                }
            }

        case .moveNode(let id, let x, let y):
            // Layout is last-writer-wins: no stamp, no touch (a drag never blocks someone's delete).
            guard nodes[id] != nil else { return }
            nodes[id]!.x = x
            nodes[id]!.y = y

        case .setField(let id, let key, let value):
            guard nodes[id] != nil else { return }
            switch key {
            case .item: return
            case .title:
                guard case .string(let s) = value else { return }
                // Same value: a pure no-op for conflict tracking (no stamp, no touch).
                if nodes[id]!.title == s && !defects.contains(.equalValueRestamps) { return }
                nodes[id]!.title = s
            case .config(let path):
                guard ConfigTree.canSet(nodes[id]!.config, path) else { return }
                if ConfigTree.get(nodes[id]!.config, path) == value && !defects.contains(.equalValueRestamps) { return }  // same value: no-op
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

        case .insertItem(let id, let path, let item, let after):
            guard nodes[id] != nil, ConfigTree.canSet(nodes[id]!.config, path), deletedItems[item.id] == nil else { return }
            var items: [Item]
            switch ConfigTree.list(in: nodes[id]!.config, at: path) {
            case .notAList: return
            case .absent: items = []
            case .found(let xs): items = xs
            }
            guard !items.contains(where: { $0.id == item.id }) else { return }
            // Anchor gone (concurrently removed) => append. Deterministic: every replica applies in server order.
            let at = after.flatMap { a in items.firstIndex { $0.id == a } }.map { $0 + 1 } ?? (after == nil ? 0 : items.count)
            items.insert(item, at: at)
            ConfigTree.set(&nodes[id]!.config, path[...], .items(items))
            stampField(id, .item(path, item.id), stamp)
            touch(id, stamp)

        case .removeItem(let id, let path, let itemId):
            guard nodes[id] != nil, case .found(var items) = ConfigTree.list(in: nodes[id]!.config, at: path),
                  let at = items.firstIndex(where: { $0.id == itemId }) else { return }
            let removedName = outputNameRemoved(by: op)
            items.remove(at: at)
            ConfigTree.set(&nodes[id]!.config, path[...], .items(items))
            deletedItems[itemId] = stamp
            stampField(id, .item(path, itemId), stamp)
            touch(id, stamp)
            breakOutputRefs(removedName, stamp, defects)

        case .updateItem(let id, let path, let itemId, let value):
            guard nodes[id] != nil, case .found(var items) = ConfigTree.list(in: nodes[id]!.config, at: path),
                  let at = items.firstIndex(where: { $0.id == itemId }),
                  items[at].value != value || defects.contains(.equalValueRestamps) else { return }
            let removedName = outputNameRemoved(by: op)
            items[at].value = value
            ConfigTree.set(&nodes[id]!.config, path[...], .items(items))
            stampField(id, .item(path, itemId), stamp)
            touch(id, stamp)
            breakOutputRefs(removedName, stamp, defects)
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
                switch k {
                case .config(let q) where q.count > path.count && Array(q.prefix(path.count)) == path: stamps[k] = nil
                case .item(let q, _) where q.count >= path.count && Array(q.prefix(path.count)) == path: stamps[k] = nil
                default: break
                }
            }
        }
        stamps[key] = stamp
        fieldStamps[node] = stamps
    }
}
