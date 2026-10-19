// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/graph (node configs),
// graphon/entities/base_node_data.py. See NOTICE.md.

import Foundation

/// One node of a Dify graph (`{"id", "data": {"type", "title", ...}}`, plus canvas fields the runtime ignores).
public struct NodeConfig: Sendable {
    public var id: String
    public var data: JSONObject
    /// The node's canvas parent (`parentId`: the iteration or loop it is in), if any.
    public var parentId: String?

    public var type: String { data["type"]?.string ?? "" }
    public var title: String { data["title"]?.string ?? "" }
    /// `str(node_data.version)` (default `"1"`).
    public var version: String {
        switch data["version"] {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        default: return "1"
        }
    }
}

/// An edge (`{"id", "source", "target", "sourceHandle", "targetHandle"}`).
public struct EdgeConfig: Sendable, Hashable {
    public var id: String
    public var source: String
    public var target: String
    public var sourceHandle: String
    public var targetHandle: String
}

/// A Dify graph (`workflow.graph`: `{nodes, edges, viewport}`) as the runtime reads it.
public struct GraphConfig: Sendable {
    public var nodes: [NodeConfig]
    public var edges: [EdgeConfig]
    /// The raw graph (node data as given).
    public var json: JSONValue

    public struct Invalid: Error, CustomStringConvertible, Sendable { public var description: String }

    public init(json: JSONValue) throws {
        self.json = json
        guard let nodes = json["nodes"]?.array else { throw Invalid(description: "graph has no nodes") }
        self.nodes = try nodes.map { n in
            guard let id = n["id"]?.string, let data = n["data"]?.object else { throw Invalid(description: "node without id or data") }
            return NodeConfig(id: id, data: data, parentId: n["parentId"]?.string)
        }
        edges = (json["edges"]?.array ?? []).compactMap { e in
            guard let s = e["source"]?.string, let t = e["target"]?.string else { return nil }
            return EdgeConfig(id: e["id"]?.string ?? "", source: s, target: t, sourceHandle: e["sourceHandle"]?.string ?? "source",
                              targetHandle: e["targetHandle"]?.string ?? "target")
        }
    }

    /// `get_node_config_by_id`.
    public func node(_ id: String) -> NodeConfig? { nodes.first { $0.id == id } }

    /// `get_enclosing_node_type_and_id`: the iteration or loop a node is in (`data.iteration_id` / `data.loop_id`).
    public func enclosingNode(of n: NodeConfig) -> (type: String, id: String)? {
        if n.data["isInLoop"]?.bool == true, let p = n.data["loop_id"]?.string { return (NodeType.loop, p) }
        if n.data["isInIteration"]?.bool == true, let p = n.data["iteration_id"]?.string { return (NodeType.iteration, p) }
        return nil
    }
}

/// A node's data could not be read (pydantic's validation error in graphon).
public struct NodeDataError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// `BaseNodeData`: the fields every node has.
public struct BaseNodeData: Sendable {
    public struct RetryConfig: Sendable {
        public var maxRetries = 0
        /// Milliseconds.
        public var retryInterval = 0
        public var retryEnabled = false
    }

    /// `DefaultValue`: an output's value under the `default-value` error strategy.
    public struct DefaultValue: Sendable {
        public var key: String
        public var type: String
        public var value: JSONValue
    }

    public var type: String
    public var title: String
    public var desc: String?
    public var version: String
    public var errorStrategy: ErrorStrategy?
    public var defaultValue: [DefaultValue]?
    public var retryConfig = RetryConfig()

    public init(_ data: JSONObject) throws {
        type = data["type"]?.string ?? ""
        title = data["title"]?.string ?? ""
        desc = data["desc"]?.string
        switch data["version"] {
        case .string(let s)?: version = s
        case .int(let i)?: version = String(i)
        default: version = "1"
        }
        switch data["error_strategy"] {
        case .string(let s)?:
            guard let e = ErrorStrategy(rawValue: s) else { throw NodeDataError("error_strategy: invalid value '\(s)'") }
            errorStrategy = e
        default: errorStrategy = nil
        }
        if let list = data["default_value"]?.array {
            defaultValue = try list.map(Self.defaultValue)
        }
        if let r = data["retry_config"]?.object {
            retryConfig.maxRetries = r["max_retries"]?.int ?? 0
            retryConfig.retryInterval = r["retry_interval"]?.int ?? 0
            retryConfig.retryEnabled = r["retry_enabled"]?.bool ?? false
        }
    }

    /// `default_value_dict`.
    public var defaultValueDict: JSONObject {
        JSONObject((defaultValue ?? []).map { ($0.key, $0.value) })
    }

    /// `DefaultValue.validate_value_type`: strings are converted for non-string types (JSON for objects and arrays,
    /// `float()` for numbers), then the type is checked.
    static func defaultValue(_ j: JSONValue) throws -> DefaultValue {
        guard let key = j["key"]?.string, let type = j["type"]?.string else { throw NodeDataError("default_value: key and type are required") }
        var value = j["value"] ?? .null
        let converters: [String: Bool] = ["string": false, "number": true, "object": true, "array[number]": true, "array[string]": true,
                                          "array[object]": true]
        if type == "array[file]" { return DefaultValue(key: key, type: type, value: value) }
        guard let convert = converters[type] else { throw NodeDataError("Unsupported type: \(type)") }
        if convert, case .string(let s) = value {
            if type == "number" {
                guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { throw NodeDataError("Cannot convert to number: \(s)") }
                value = .double(d)
            } else {
                do { value = try JSONValue.parse(s) } catch { throw NodeDataError("Invalid JSON format for value: \(s)") }
            }
        }
        func isNumber(_ v: JSONValue) -> Bool { if case .int = v { return true }; if case .double = v { return true }; return false }
        let ok: Bool
        switch type {
        case "string": ok = value.string != nil
        case "number": ok = isNumber(value)
        case "object": ok = value.object != nil
        case "array[number]": ok = value.array.map { $0.allSatisfy(isNumber) } ?? false
        case "array[string]": ok = value.array.map { $0.allSatisfy { $0.string != nil } } ?? false
        case "array[object]": ok = value.array.map { $0.allSatisfy { $0.object != nil } } ?? false
        default: ok = true
        }
        guard ok else { throw NodeDataError("Value must be \(type) type for \(PythonText.str(value))") }
        return DefaultValue(key: key, type: type, value: value)
    }
}
