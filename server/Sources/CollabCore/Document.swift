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
    /// Protocol 1.7: document-level registers (Dify's environment variables, conversation variables, features). Ops address
    /// them through the reserved node id `Document.appNode` ("$app") with `setField` (config paths), `insertItem`,
    /// `removeItem` and `updateItem`, under the same conflict rules as a node's config. Values contain no references.
    public private(set) var app: [String: Value] = [:]

    /// The reserved node id of the document-level registers (protocol 1.7). It always exists; it has no title, position,
    /// edges or touches, and can be neither added, removed nor restored. Real node ids never start with `$`.
    public static let appNode: NodeID = "$app"

    public init(nodes: [Node] = [], edges: [Edge] = [], app: [String: Value] = [:]) {
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        self.edges = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
        self.app = app
    }

    /// Full-state initializer used when decoding a snapshot.
    init(nodes: [Node], edges: [Edge], app: [String: Value] = [:], deletedNodes: [NodeID: Stamp], deletedEdges: [EdgeID: Stamp],
         deletedItems: [ItemID: Stamp], fieldStamps: [NodeID: [FieldKey: Stamp]], touches: [NodeID: [ClientID: Int]]) {
        self.init(nodes: nodes, edges: edges, app: app)
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
        for key in app.keys.sorted() where !app[key]!.liveRefs.isEmpty || app[key]!.containsBrokenRef {
            problems.append("\(Self.appNode).\(key) contains a reference")
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
            guard !n.id.hasPrefix("$") else { throw .invalid("node id \(n.id) is reserved (ids starting with $)") }
            guard nodes[n.id] == nil, deletedNodes[n.id] == nil else { throw .nodeExists(n.id) }
            for key in n.config.keys.sorted() {
                guard !key.hasPrefix("$") else { throw .invalid("config key \(key) is reserved") }
                try checkValue(n.config[key]!, selfNode: n.id)
            }

        case .removeNode(let id):
            try requireNotApp(id, "removeNode")
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
            try requireNotApp(id, "moveNode")
            try requireLive(id)

        case .setField(let id, let key, let value):
            try requireLive(id)
            let current: Value?
            switch key {
            case .item: throw .invalid("list items are written with the item ops")
            case .title:
                try requireNotApp(id, "title")
                guard case .string = value else { throw .invalid("title must be a string") }
                current = .string(nodes[id]!.title)
            case .config(let path):
                let cfg = config(of: id)!
                guard ConfigTree.canSet(cfg, path) else { throw .invalid("bad path \(path)") }
                guard !path.contains(where: { $0.hasPrefix("$") }) else { throw .invalid("reserved key in path") }
                try checkValue(value, selfNode: nil, inApp: id == Self.appNode)
                current = ConfigTree.get(cfg, path)
            }
            try checkStale(id, key, base: base, client: client, isSameValue: current == value,
                           enabled: checkConflicts, defects: defects)

        case .addEdge(let e):
            guard !e.id.isEmpty else { throw .invalid("empty edge id") }
            guard edges[e.id] == nil, deletedEdges[e.id] == nil else { throw .edgeExists(e.id) }
            try requireNotApp(e.source, "edge endpoint")
            try requireNotApp(e.target, "edge endpoint")
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
            let cfg = config(of: id)!
            guard !path.isEmpty, ConfigTree.canSet(cfg, path),
                  !path.contains(where: { $0.hasPrefix("$") }) else { throw .invalid("bad list path \(path)") }
            guard !item.id.isEmpty else { throw .invalid("empty item id") }
            switch ConfigTree.list(in: cfg, at: path) {
            case .notAList: throw .invalid("\(path) is not a keyed list")
            case .found(let items): if items.contains(where: { $0.id == item.id }) { throw .itemExists(item.id) }
            case .absent: break
            }
            guard deletedItems[item.id] == nil else { throw .itemExists(item.id) }
            try checkValue(item.value, selfNode: nil, inApp: id == Self.appNode)

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
            try checkValue(value, selfNode: nil, inApp: id == Self.appNode)
            try checkStale(id, .item(path, itemId), base: base, client: client, isSameValue: existing == value,
                           enabled: checkConflicts, defects: defects)
            if checkConflicts { try checkOutputRemoval(op, base: base, client: client) }  // renaming an output

        case .restoreNode(let n, let restoredEdges):
            try validateRestore(n, restoredEdges, base: base, client: client, checkConflicts: checkConflicts, defects: defects)
        }
    }

    /// Protocol 1.6 `restoreNode` (undo of a delete). Undo is only for one's own operations: only the client whose delete
    /// made the tombstone may restore the node (`notDeleter` otherwise). Since that client wrote the tombstone, the
    /// tombstone itself is never a stale write for it. Like a delete, the restore rewrites fields of other nodes
    /// (`$broken` -> `$ref`); it conflicts with any other client's write, after `base`, to one of those fields.
    private func validateRestore(_ n: Node, _ restoredEdges: [Edge], base: Int, client: ClientID,
                                 checkConflicts: Bool, defects: ProtocolDefects) throws(RejectReason) {
        guard !n.id.isEmpty else { throw .invalid("empty node id") }
        guard !n.id.hasPrefix("$") else { throw .invalid("node id \(n.id) is reserved (ids starting with $)") }
        if nodes[n.id] != nil { throw .nodeExists(n.id) }
        guard let tomb = deletedNodes[n.id] else { throw .nodeNotFound(n.id) }
        if tomb.client != client && !defects.contains(.anyoneRestores) { throw .notDeleter(n.id, by: tomb.client) }
        for key in n.config.keys.sorted() {
            guard !key.hasPrefix("$") else { throw .invalid("config key \(key) is reserved") }
            // `$broken` markers are allowed here (the node comes back as it was); live and broken references are
            // normalised when applied, so references to nodes deleted meanwhile are not an error.
            if let p = n.config[key]!.structuralProblem { throw .invalid(p) }
        }
        // Only a malformed edge list is refused. An edge that cannot come back (not removed by this delete, other
        // endpoint deleted meanwhile, duplicate connection) is skipped when applied; the rest of the restore holds.
        var ids = Set<EdgeID>()
        for e in restoredEdges {
            guard !e.id.isEmpty else { throw .invalid("empty edge id") }
            guard ids.insert(e.id).inserted else { throw .invalid("edge \(e.id) listed twice") }
            guard e.source == n.id || e.target == n.id else { throw .invalid("edge \(e.id) does not touch node \(n.id)") }
        }
        guard checkConflicts else { return }
        if tomb.seq > base && tomb.client != client {  // only reachable with the `anyoneRestores` defect
            throw .conflict(Conflict(node: n.id, field: nil, seq: tomb.seq, by: tomb.client))
        }
        let accepts = Self.acceptsOutput(of: n)
        for other in nodes.keys.sorted() {
            var cfg = nodes[other]!.config
            for key in ConfigTree.reviveRefs(in: &cfg, matching: { $0.node == n.id && accepts($0.output) }) {
                if let c = fieldConflict(other, key, base: base, client: client) { throw .conflict(c) }
            }
        }
    }

    /// Whether `node` can be referenced by output name `output`: it declares it, or it declares no outputs at all.
    static func acceptsOutput(of node: Node) -> (String) -> Bool {
        guard let outs = declaredOutputs(of: node) else { return { _ in true } }
        return { outs.contains($0) }
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
        if case .found(let items) = ConfigTree.list(in: config(of: node)!, at: path),
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

    /// `$app` (protocol 1.7) always exists.
    private func requireLive(_ id: NodeID) throws(RejectReason) {
        if nodes[id] != nil || id == Self.appNode { return }
        throw deletedNodes[id] != nil ? .nodeDeleted(id) : .nodeNotFound(id)
    }

    /// `$app` takes config and item writes only (protocol 1.7).
    private func requireNotApp(_ id: NodeID, _ what: String) throws(RejectReason) {
        if id == Self.appNode { throw .invalid("\(what) is not allowed on \(Self.appNode)") }
    }

    /// The config a register write addresses: a live node's, or the document-level registers for `$app`.
    private func config(of id: NodeID) -> [String: Value]? { id == Self.appNode ? app : nodes[id]?.config }

    /// Clients may only write live refs to existing nodes; broken markers are server-only. `$app` values (protocol 1.7)
    /// contain no references at all.
    private func checkValue(_ v: Value, selfNode: NodeID?, inApp: Bool = false) throws(RejectReason) {
        if let p = v.structuralProblem { throw .invalid(p) }
        if v.containsBrokenRef { throw .invalid("brokenRef is server-written only") }
        if inApp && !v.liveRefs.isEmpty { throw .invalid("references are not allowed in \(Self.appNode)") }
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
            guard let cfg = config(of: id) else { return }
            switch key {
            case .item: return
            case .title:
                guard id != Self.appNode, case .string(let s) = value else { return }
                // Same value: a pure no-op for conflict tracking (no stamp, no touch).
                if nodes[id]!.title == s && !defects.contains(.equalValueRestamps) { return }
                nodes[id]!.title = s
            case .config(let path):
                guard ConfigTree.canSet(cfg, path) else { return }
                if ConfigTree.get(cfg, path) == value && !defects.contains(.equalValueRestamps) { return }  // same value: no-op
                setConfig(of: id, path, value)
            }
            stampWrite(id, key, stamp, defects)

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
            guard let cfg = config(of: id), ConfigTree.canSet(cfg, path), deletedItems[item.id] == nil else { return }
            var items: [Item]
            switch ConfigTree.list(in: cfg, at: path) {
            case .notAList: return
            case .absent: items = []
            case .found(let xs): items = xs
            }
            guard !items.contains(where: { $0.id == item.id }) else { return }
            // Anchor gone (concurrently removed) => append. Deterministic: every replica applies in server order.
            let at = after.flatMap { a in items.firstIndex { $0.id == a } }.map { $0 + 1 } ?? (after == nil ? 0 : items.count)
            items.insert(item, at: at)
            setConfig(of: id, path, .items(items))
            stampWrite(id, .item(path, item.id), stamp, defects)

        case .removeItem(let id, let path, let itemId):
            guard let cfg = config(of: id), case .found(var items) = ConfigTree.list(in: cfg, at: path),
                  let at = items.firstIndex(where: { $0.id == itemId }) else { return }
            let removedName = outputNameRemoved(by: op)
            items.remove(at: at)
            setConfig(of: id, path, .items(items))
            deletedItems[itemId] = stamp
            stampWrite(id, .item(path, itemId), stamp, defects)
            breakOutputRefs(removedName, stamp, defects)

        case .updateItem(let id, let path, let itemId, let value):
            guard let cfg = config(of: id), case .found(var items) = ConfigTree.list(in: cfg, at: path),
                  let at = items.firstIndex(where: { $0.id == itemId }),
                  items[at].value != value || defects.contains(.equalValueRestamps) else { return }
            let removedName = outputNameRemoved(by: op)
            items[at].value = value
            setConfig(of: id, path, .items(items))
            stampWrite(id, .item(path, itemId), stamp, defects)
            breakOutputRefs(removedName, stamp, defects)

        case .restoreNode(let n, let restoredEdges):
            applyRestore(n, restoredEdges, stamp, defects)
        }
    }

    /// Restore: the node comes back with its references normalised (live iff the target exists and declares the
    /// output); each listed edge comes back iff this delete removed it (same tombstone), both endpoints exist and no live
    /// edge has the same connection, otherwise it stays deleted; `$broken` references to the node in other nodes whose
    /// output it declares become live again. The restore counts as a content write of the whole node
    /// (title + the whole config) by its author, so writes based on a version before it are stale.
    private mutating func applyRestore(_ n: Node, _ restoredEdges: [Edge], _ stamp: Stamp, _ defects: ProtocolDefects) {
        guard nodes[n.id] == nil, let tomb = deletedNodes[n.id] else { return }
        let accepts = Self.acceptsOutput(of: n)
        var node = n
        for key in node.config.keys.sorted() {
            node.config[key] = node.config[key]!.normalizingRefs { r, _ in
                if r.node == n.id { return accepts(r.output) }
                guard let target = nodes[r.node] else { return false }
                return Self.acceptsOutput(of: target)(r.output)
            }
        }
        deletedNodes[n.id] = nil
        nodes[n.id] = node
        if !defects.contains(.restoreSkipsStamps) {
            stampField(n.id, .title, stamp)
            stampField(n.id, .config([]), stamp)  // the empty path overlaps every config path and list item
            touch(n.id, stamp)
        }
        for e in restoredEdges {
            guard e.source == n.id || e.target == n.id, edges[e.id] == nil, deletedEdges[e.id] == tomb else { continue }
            if !defects.contains(.restoreIgnoresEndpoints) {
                guard nodes[e.source] != nil, nodes[e.target] != nil else { continue }  // other endpoint deleted: skipped
            }
            guard !edges.values.contains(where: { $0.sameConnection(e) }) else { continue }
            edges[e.id] = e
            deletedEdges[e.id] = nil
            touch(e.source, stamp)
            touch(e.target, stamp)
        }
        for other in nodes.keys.sorted() where other != n.id {
            var cfg = nodes[other]!.config
            let changed = ConfigTree.reviveRefs(in: &cfg, matching: { $0.node == n.id && accepts($0.output) })
            guard !changed.isEmpty else { continue }
            nodes[other]!.config = cfg
            for key in changed { stampField(other, key, stamp) }
            touch(other, stamp)
        }
    }

    private mutating func setConfig(of id: NodeID, _ path: [String], _ value: Value) {
        if id == Self.appNode { ConfigTree.set(&app, path[...], value) } else { ConfigTree.set(&nodes[id]!.config, path[...], value) }
    }

    /// Versions a content write: the register's stamp and, for a node, the author's touch (`$app` has no touches: nothing
    /// deletes it).
    private mutating func stampWrite(_ id: NodeID, _ key: FieldKey, _ stamp: Stamp, _ defects: ProtocolDefects) {
        if id == Self.appNode && defects.contains(.appSkipsStamps) { return }
        stampField(id, key, stamp)
        touch(id, stamp)
    }

    private mutating func touch(_ node: NodeID, _ stamp: Stamp) {
        guard node != Self.appNode else { return }
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
