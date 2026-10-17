/// Identifiers. Client-generated ids (nodes, edges) must be globally unique (UUIDs in production)
/// and are never reused: deleted ids stay tombstoned.
public typealias ClientID = String
public typealias NodeID = String
public typealias EdgeID = String

/// A reference to another node's output variable (Dify's `value_selector: [nodeId, name]`).
public struct OutputRef: Hashable, Codable, Sendable {
    public var node: NodeID
    public var output: String
    public init(node: NodeID, output: String) {
        self.node = node
        self.output = output
    }
}

/// A node config value. Numbers are integers on purpose: no float equality surprises.
/// `.brokenRef` is the explicit marker the server writes when the referenced node is deleted;
/// clients can never write it.
public enum Value: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case ref(OutputRef)
    case brokenRef(OutputRef)
    /// Lists are atomic leaves for conflict purposes (no index-addressed edits; see REPORT.md).
    case list([Value])
    case map([String: Value])
}

extension Value {
    /// Every live (non-broken) reference contained in this value, recursively.
    public var liveRefs: [OutputRef] {
        switch self {
        case .ref(let r): return [r]
        case .list(let items): return items.flatMap(\.liveRefs)
        case .map(let m): return m.keys.sorted().flatMap { m[$0]!.liveRefs }
        default: return []
        }
    }

    public var containsBrokenRef: Bool {
        switch self {
        case .brokenRef: return true
        case .list(let items): return items.contains { $0.containsBrokenRef }
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
        case .map(let m): return .map(m.mapValues { $0.breaking(refsTo: node) })
        default: return self
        }
    }
}

/// Operations on the nested `config` tree of a node.
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

    /// Marks every reference to `node` as broken. Returns the config paths that changed
    /// (nearest map-key path; lists are atomic) so the caller can version them.
    static func breakRefs(in cfg: inout [String: Value], to node: NodeID, prefix: [String] = []) -> [[String]] {
        var changed: [[String]] = []
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
                    changed.append(path)
                }
            default: break
            }
        }
        return changed
    }
}
