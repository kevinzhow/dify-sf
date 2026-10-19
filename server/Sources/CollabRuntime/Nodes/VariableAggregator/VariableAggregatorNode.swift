// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/nodes/variable_aggregator/variable_aggregator_node.py, entities.py. See ../../NOTICE.md.

/// The variable aggregator (also the legacy `variable-assigner` type): the first variable that exists, per group.
public struct VariableAggregatorNode: RuntimeNode {
    public struct Group: Sendable {
        public var outputType: String
        public var variables: [[String]]
        public var groupName: String
    }

    public let id: String
    public let base: BaseNodeData
    public let nodeType: String
    public let outputType: String
    public let variables: [[String]]
    /// `advanced_settings.groups` when `group_enabled`.
    public let groups: [Group]?

    public init(id: String, type: String, data: JSONObject) throws {
        self.id = id
        nodeType = type
        base = try BaseNodeData(data)
        guard let ot = data["output_type"]?.string else { throw NodeDataError("output_type: Field required") }
        outputType = ot
        guard let vars = data["variables"]?.array else { throw NodeDataError("variables: Field required") }
        variables = vars.map { ($0.array ?? []).map { PythonText.str($0) } }
        if let adv = data["advanced_settings"]?.object {
            guard let enabled = adv["group_enabled"]?.bool else { throw NodeDataError("advanced_settings.group_enabled: Field required") }
            let gs = try (adv["groups"]?.array ?? []).map { g -> Group in
                guard let name = g["group_name"]?.string, let t = g["output_type"]?.string else {
                    throw NodeDataError("advanced_settings.groups: group_name and output_type are required")
                }
                return Group(outputType: t, variables: (g["variables"]?.array ?? []).map { ($0.array ?? []).map { PythonText.str($0) } },
                             groupName: name)
            }
            groups = enabled ? gs : nil
        } else {
            groups = nil
        }
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var outputs = JSONObject(), inputs = JSONObject()
        var types: [String: SegmentType] = [:]
        if let groups {
            for g in groups {
                for sel in g.variables {
                    if let v = context.pool.get(sel) {
                        outputs[g.groupName] = ["output": v.value]
                        inputs[sel.dropFirst().joined(separator: ".")] = v.object
                        break
                    }
                }
            }
        } else {
            for sel in variables {
                if let v = context.pool.get(sel) {
                    outputs = ["output": v.value]
                    types = ["output": v.valueType]
                    inputs = [sel.dropFirst().joined(separator: "."): v.object]
                    break
                }
            }
        }
        var r = NodeRunResult(status: .succeeded, inputs: inputs, outputs: outputs)
        r.outputTypes = types
        await emit(.completed(r))
    }
}

extension BuiltinNodeFactory {
    func makeVariableAggregator(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        try VariableAggregatorNode(id: config.id, type: config.type, data: config.data)
    }
}
