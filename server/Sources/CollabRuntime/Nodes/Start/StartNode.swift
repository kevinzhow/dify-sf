// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/start/start_node.py,
// entities.py, graphon/variables/input_entities.py. See ../../NOTICE.md.
//
// Not ported: the JSON-schema check of `json_object` inputs (graphon validates them with jsonschema's Draft 7).

/// `VariableEntity`: one input of a start node (or a user input form).
public struct VariableEntity: Sendable {
    public var variable: String
    public var label: String
    public var type: String
    public var required: Bool
    public var maxLength: Int?
    public var options: [String]
    public var defaultValue: JSONValue?
    public var jsonSchema: JSONValue?
    public var json: JSONObject

    public init(_ j: JSONObject) throws {
        guard let v = j["variable"]?.string else { throw NodeDataError("variables: variable is required") }
        variable = v
        label = j["label"]?.string ?? v
        type = j["type"]?.string ?? "text-input"
        required = j["required"]?.bool ?? false
        maxLength = j["max_length"]?.int
        options = (j["options"]?.array ?? []).compactMap(\.string)
        defaultValue = j["default"].flatMap { $0 == .null ? nil : $0 }
        jsonSchema = j["json_schema"].flatMap { $0 == .null ? nil : $0 }
        json = j
    }
}

/// The start node: its inputs (already in the pool under its id) and the whole pool flattened (`sys.*`, `env.*`, ...).
public struct StartNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let variables: [VariableEntity]

    public var nodeType: String { NodeType.start }
    public var executionType: NodeExecutionType { .root }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        variables = try (data["variables"]?.array ?? []).map { v in
            guard let o = v.object else { throw NodeDataError("variables: each variable must be an object") }
            return try VariableEntity(o)
        }
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var inputs = context.pool.values(of: id)
        for v in variables where v.type == "json_object" {
            let value = inputs[v.variable]
            if (value == nil || value == .null) && v.required { throw NodeError("ValueError", "\(v.variable) is required in input form") }
            guard let value, value.isTruthy else { continue }
            guard value.object != nil else { throw NodeError("TypeError", "JSON object for '\(v.variable)' must be an object") }
            inputs[v.variable] = value
        }
        var outputs = context.pool.flatten(unprefixedNodeId: id)
        for (k, v) in inputs { outputs[k] = v }
        var result = NodeRunResult(status: .succeeded, inputs: inputs, outputs: outputs)
        result.outputTypes["sys.files"] = .arrayFile
        for variable in variables where variable.type == "file-list" && inputs[variable.variable]?.array != nil {
            result.outputTypes[variable.variable] = .arrayFile
        }
        await emit(.completed(result))
    }
}
