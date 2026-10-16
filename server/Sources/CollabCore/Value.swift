/// Identifiers. Client-generated ids (nodes, edges, list items) must be globally unique (UUIDs in
/// production) and are never reused: deleted ids stay tombstoned.
public typealias ClientID = String
public typealias NodeID = String
public typealias EdgeID = String
public typealias ItemID = String

/// A reference to another node's output variable (Dify's `value_selector: [nodeId, name]`).
public struct OutputRef: Hashable, Codable, Sendable {
    public var node: NodeID
    public var output: String
    public init(node: NodeID, output: String) {
        self.node = node
        self.output = output
    }
}

/// One element of a keyed list. The `id` is stable for the life of the item, which is what lets two
/// users insert/remove/edit *different* items of the same list without ever conflicting.
public struct Item: Hashable, Codable, Sendable {
    public var id: ItemID
    public var value: Value
    public init(id: ItemID, value: Value) {
        self.id = id
        self.value = value
    }
}

/// A node config value. Numbers are integers on purpose: no float equality surprises.
/// `.brokenRef` is the explicit marker the server writes when the referenced node is deleted;
/// clients can never write it.
public indirect enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case ref(OutputRef)
    case brokenRef(OutputRef)
    /// Atomic list: replaced as a whole, so concurrent edits to it conflict. Use `.items` for lists
    /// whose elements are edited independently.
    case list([Value])
    /// Keyed list: an ordered list of items with stable ids, edited with item-level ops.
    case items([Item])
    case map([String: Value])
}

extension Value {
    /// Every live (non-broken) reference contained in this value, recursively.
    public var liveRefs: [OutputRef] {
        switch self {
        case .ref(let r): return [r]
        case .list(let items): return items.flatMap(\.liveRefs)
        case .items(let items): return items.flatMap { $0.value.liveRefs }
        case .map(let m): return m.keys.sorted().flatMap { m[$0]!.liveRefs }
        default: return []
        }
    }

    public var containsBrokenRef: Bool {
        switch self {
        case .brokenRef: return true
        case .list(let items): return items.contains { $0.containsBrokenRef }
        case .items(let items): return items.contains { $0.value.containsBrokenRef }
        case .map(let m): return m.values.contains { $0.containsBrokenRef }
        default: return false
        }
    }

    func hasRef(to node: NodeID) -> Bool {
        liveRefs.contains { $0.node == node }
    }

    /// Replaces every live reference to `node` with an explicit broken marker.
    func breaking(refsTo node: NodeID) -> Value {
        switch self {
        case .ref(let r) where r.node == node: return .brokenRef(r)
        case .list(let items): return .list(items.map { $0.breaking(refsTo: node) })
        case .items(let items): return .items(items.map { Item(id: $0.id, value: $0.value.breaking(refsTo: node)) })
        case .map(let m): return .map(m.mapValues { $0.breaking(refsTo: node) })
        default: return self
        }
    }

    /// Structural problems that make a value unwritable: duplicate/empty item ids, reserved map keys.
    var structuralProblem: String? {
        switch self {
        case .list(let xs):
            return xs.lazy.compactMap(\.structuralProblem).first
        case .items(let items):
            var seen = Set<ItemID>()
            for i in items {
                if i.id.isEmpty { return "empty item id" }
                if !seen.insert(i.id).inserted { return "duplicate item id \(i.id)" }
                if let p = i.value.structuralProblem { return p }
            }
            return nil
        case .map(let m):
            for (k, v) in m {
                if k.hasPrefix("$") { return "map key \(k) is reserved (keys starting with $)" }
                if let p = v.structuralProblem { return p }
            }
            return nil
        default: return nil
        }
    }
}

/// Operations on the nested `config` tree of a node. Only maps are traversable; lists are leaves.
enum ConfigTree {
    static func get(_ cfg: [String: Value], _ path: [String]) -> Value? {
        var cur: Value = .map(cfg)
        for key in path {
            guard case .map(let m) = cur, let next = m[key] else { return nil }
            cur = next
        }
        return cur
    }

    /// True when `path` can be written: every existing intermediate is a map (absent ones get created).
    static func canSet(_ cfg: [String: Value], _ path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        var cur = cfg
        for key in path.dropLast() {
            guard let next = cur[key] else { return true }
            guard case .map(let m) = next else { return false }
            cur = m
        }
        return true
    }

    static func set(_ cfg: inout [String: Value], _ path: ArraySlice<String>, _ value: Value) {
        guard let head = path.first else { return }
        if path.count == 1 {
            cfg[head] = value
            return
        }
        var child: [String: Value] = [:]
        if case .map(let m)? = cfg[head] { child = m }
        set(&child, path.dropFirst(), value)
        cfg[head] = .map(child)
    }

    /// Marks every reference to `node` as broken. Returns the registers that changed (nearest
    /// map-key path for atomic values; `(list path, item id)` for keyed lists) so the caller can
    /// version them.
    static func breakRefs(in cfg: inout [String: Value], to node: NodeID, prefix: [String] = []) -> [FieldKey] {
        var changed: [FieldKey] = []
        for key in cfg.keys.sorted() {
            let v = cfg[key]!
            let path = prefix + [key]
            switch v {
            case .map(var m):
                let sub = breakRefs(in: &m, to: node, prefix: path)
                if !sub.isEmpty {
                    cfg[key] = .map(m)
                    changed += sub
                }
            case .ref, .list:
                if v.hasRef(to: node) {
                    cfg[key] = v.breaking(refsTo: node)
                    changed.append(.config(path))
                }
            case .items(let items):
                var out = items
                for i in out.indices where out[i].value.hasRef(to: node) {
                    out[i].value = out[i].value.breaking(refsTo: node)
                    changed.append(.item(path, out[i].id))
                }
                if out != items { cfg[key] = .items(out) }
            default: break
            }
        }
        return changed
    }

    /// The keyed list at `path`: nil if absent, throws-ish `.notAList` if something else lives there.
    enum ListLookup { case absent, notAList, found([Item]) }
    static func list(in cfg: [String: Value], at path: [String]) -> ListLookup {
        switch get(cfg, path) {
        case nil: return .absent
        case .items(let items)?: return .found(items)
        default: return .notAList
        }
    }
}
