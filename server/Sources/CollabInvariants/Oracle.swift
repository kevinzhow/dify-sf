import CollabCore

/// Independent reference model: replays the committed log with *flat, path-keyed* semantics that
/// share no code with `Document`. If the real document ever disagrees with this replay, either the
/// implementation or the rules have drifted.
public struct Oracle {
    struct ONode: Equatable {
        var type: String
        var title: String
        var x: Int
        var y: Int
        /// Flattened config: non-empty maps are expanded to their leaves; lists and keyed lists are leaves.
        var leaves: [[String]: Value]
    }

    /// One content register written by a log entry. `field == nil` means "something about the node
    /// changed" (matters only to deletes).
    public struct Touch: Equatable {
        public var node: NodeID
        public var field: FieldKey?
    }

    var nodes: [NodeID: ONode] = [:]
    var edges: [EdgeID: Edge] = [:]

    public init(_ doc: Document) {
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

    /// Breaks refs to `node` inside `v`; returns the new value and, for keyed lists, the ids of changed items.
    static func breakRefs(_ v: Value, _ node: NodeID) -> (Value, changedItems: [ItemID], changed: Bool) {
        switch v {
        case .ref(let r) where r.node == node: return (.brokenRef(r), [], true)
        case .list(let xs):
            let r = xs.map { breakRefs($0, node) }
            return (.list(r.map(\.0)), [], r.contains { $0.changed })
        case .items(let items):
            var ids: [ItemID] = []
            var out: [Item] = []
            for i in items {
                let r = breakRefs(i.value, node)
                if r.changed { ids.append(i.id) }
                out.append(Item(id: i.id, value: r.0))
            }
            return (.items(out), ids, !ids.isEmpty)
        case .map(let m):
            var changed = false
            var out: [String: Value] = [:]
            for (k, c) in m {
                let r = breakRefs(c, node)
                changed = changed || r.changed
                out[k] = r.0
            }
            return (.map(out), [], changed)
        default: return (v, [], false)
        }
    }

    /// Applies one committed entry and reports which content registers it wrote (empty for pure
    /// layout moves and for same-value no-ops).
    public mutating func apply(_ e: LogEntry) -> [Touch] {
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
                    let (nv, items, changed) = Self.breakRefs(nodes[id]!.leaves[path]!, d)
                    guard changed else { continue }
                    nodes[id]!.leaves[path] = nv
                    if case .items = nv {
                        for i in items { touches.append(Touch(node: id, field: .item(path, i))) }
                    } else {
                        touches.append(Touch(node: id, field: .config(path)))
                    }
                }
            }
            return touches
        case .moveNode(let id, let x, let y):
            nodes[id]?.x = x
            nodes[id]?.y = y
            return []
        case .setField(let id, let key, let value):
            switch key {
            case .title:
                guard case .string(let s) = value, nodes[id]?.title != s else { return [] }
                nodes[id]?.title = s
            case .item: return []
            case .config(let path):
                guard var n = nodes[id] else { return [] }
                var fresh: [[String]: Value] = [:]
                Self.flatten(path, value, into: &fresh)
                let old = n.leaves.filter { Self.hasPrefix($0.key, path) }
                if old == fresh { return [] }  // same value: nothing written
                for p in old.keys { n.leaves[p] = nil }
                for p in n.leaves.keys where p.count < path.count && Self.hasPrefix(path, p) {
                    if n.leaves[p] == .map([:]) { n.leaves[p] = nil }
                }
                for (p, v) in fresh { n.leaves[p] = v }
                nodes[id] = n
            }
            return [Touch(node: id, field: key)]
        case .addEdge(let ed):
            edges[ed.id] = ed
            return [Touch(node: ed.source, field: nil), Touch(node: ed.target, field: nil)]
        case .removeEdge(let id):
            edges[id] = nil
            return []
        case .insertItem(let id, let path, let item, let after):
            guard nodes[id] != nil else { return [] }
            var items: [Item] = []
            if case .items(let xs)? = nodes[id]!.leaves[path] { items = xs }
            var at = after == nil ? 0 : items.count
            if let a = after, let ix = items.firstIndex(where: { $0.id == a }) { at = ix + 1 }
            items.insert(item, at: at)
            nodes[id]!.leaves[path] = .items(items)
            return [Touch(node: id, field: .item(path, item.id))]
        case .removeItem(let id, let path, let itemId):
            guard case .items(var items)? = nodes[id]?.leaves[path], let ix = items.firstIndex(where: { $0.id == itemId }) else {
                return []  // already removed: no-op
            }
            items.remove(at: ix)
            nodes[id]!.leaves[path] = .items(items)
            return [Touch(node: id, field: .item(path, itemId))]
        case .updateItem(let id, let path, let itemId, let value):
            guard case .items(var items)? = nodes[id]?.leaves[path], let ix = items.firstIndex(where: { $0.id == itemId }),
                  items[ix].value != value else { return [] }
            items[ix].value = value
            nodes[id]!.leaves[path] = .items(items)
            return [Touch(node: id, field: .item(path, itemId))]
        }
    }

    public func matches(_ doc: Document) -> String? {
        if Set(nodes.keys) != Set(doc.nodes.keys) {
            return "node sets differ: oracle \(nodes.keys.sorted()) vs doc \(doc.nodes.keys.sorted())"
        }
        for id in nodes.keys.sorted() {
            let d = Self.make(doc.nodes[id]!)
            if d != nodes[id]! { return "node \(id) differs: oracle \(nodes[id]!) vs doc \(d)" }
        }
        if edges != doc.edges { return "edge sets differ" }
        return nil
    }
}
