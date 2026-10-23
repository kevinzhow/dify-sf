// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/end/end_node.py,
// entities.py, graphon/nodes/base/entities.py (OutputVariableEntity). See ../../NOTICE.md.

/// The end node of a workflow: its outputs are the run's outputs (and stream, in order, as the response filter allows).
public struct EndNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    /// `outputs`: `{variable, value_selector}`.
    public let outputs: [(variable: String, selector: [String])]

    public var nodeType: String { NodeType.end }
    public var executionType: NodeExecutionType { .response }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let list = data["outputs"]?.array else { throw NodeDataError("outputs: Field required") }
        outputs = try list.map { o in
            guard let v = o["variable"]?.string else { throw NodeDataError("outputs.variable: Field required") }
            let sel = (o["value_selector"]?.array ?? []).compactMap(\.string)
            return (v, sel)
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        outputs.filter { $0.selector.count >= VariablePool.selectorsLength }.map { (id + ".#" + $0.selector.joined(separator: ".") + "#", $0.selector) }
    }

    public var streamingTemplate: ResponseTemplate? { .fromEndOutputs(outputs) }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var out = JSONObject()
        for (variable, selector) in outputs {
            out[variable] = context.pool.get(selector)?.object ?? .null
        }
        var result = NodeRunResult(status: .succeeded, inputs: out, outputs: out)
        for (name, selector) in outputs { result.outputTypes[name] = context.pool.get(selector)?.valueType }
        await emit(.completed(result))
    }
}
