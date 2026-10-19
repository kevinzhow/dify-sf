// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/runtime/variable_pool.py,
// graphon/variables/consts.py. See NOTICE.md.

/// The two-level store of a run's values: `[node id or "sys" / "env" / "conversation", name]` -> segment. Longer
/// selectors read inside an object value (`["node", "obj", "a", "b"]`).
public struct VariablePool: Sendable {
    public static let systemNodeId = "sys"
    public static let environmentNodeId = "env"
    public static let conversationNodeId = "conversation"
    public static let ragPipelineNodeId = "rag"
    /// `SELECTORS_LENGTH`.
    public static let selectorsLength = 2

    /// node id -> (name -> value), names in insertion order.
    public private(set) var variables: [String: [(name: String, segment: Segment)]] = [:]

    public init() {}

    public struct InvalidSelector: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// `add(selector, value)`: the selector must have exactly two elements.
    public mutating func add(_ selector: [String], _ value: Segment) throws {
        guard selector.count == Self.selectorsLength else {
            throw InvalidSelector(description: "Invalid selector: expected \(Self.selectorsLength) elements (node_id, variable_name), got \(selector.count) elements")
        }
        var list = variables[selector[0]] ?? []
        if let i = list.firstIndex(where: { $0.name == selector[1] }) {
            list[i].segment = value
        } else {
            list.append((selector[1], value))
        }
        variables[selector[0]] = list
    }

    public mutating func add(_ selector: [String], _ value: JSONValue) throws { try add(selector, Segment.build(value)) }

    /// `get(selector)`: nil when absent, when the selector is shorter than two, or when a nested key is missing.
    public func get(_ selector: [String]) -> Segment? {
        guard selector.count >= Self.selectorsLength,
              let segment = variables[selector[0]]?.first(where: { $0.name == selector[1] })?.segment else { return nil }
        if selector.count == Self.selectorsLength { return segment }
        // Files have attributes (`file.url`, ...); no files before P5.
        if segment.valueType == .file { return nil }
        var current: JSONValue = segment.value
        for attr in selector.dropFirst(2) {
            guard case .object(let o) = current, let next = o[attr] else { return nil }
            current = next
        }
        return Segment.build(current)
    }

    public func contains(_ selector: [String]) -> Bool { get(selector) != nil }

    /// `remove(selector)`: one element clears the node, two remove one variable.
    public mutating func remove(_ selector: [String]) {
        guard let first = selector.first else { return }
        if selector.count == 1 { variables[first] = []; return }
        variables[first]?.removeAll { $0.name == selector[1] }
    }

    /// `get_by_prefix(node_id)`: a node's values by name.
    public func values(of nodeId: String) -> JSONObject {
        JSONObject((variables[nodeId] ?? []).map { ($0.name, $0.segment.value) })
    }
}
