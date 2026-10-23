// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/answer/answer_node.py,
// entities.py. See ../../NOTICE.md.

/// The answer node of a chatflow: its rendered template is the answer (streamed in order by the response filter).
public struct AnswerNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let answer: String

    public var nodeType: String { NodeType.answer }
    public var executionType: NodeExecutionType { .response }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let a = data["answer"]?.string else { throw NodeDataError("answer: Field required") }
        answer = a
    }

    public var streamingTemplate: ResponseTemplate? { .fromAnswer(answer) }
    public var streamingTextSelector: [String] { [id, "answer"] }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        let segments = VariableTemplate.convert(context.pool, answer)
        var files: [JSONValue] = []
        for segment in segments.value {
            if segment.valueType == .file { files.append(segment.value) }
            else if segment.valueType == .arrayFile { files += segment.value.array ?? [] }
        }
        await emit(.completed(NodeRunResult(status: .succeeded, outputs: ["answer": .string(segments.markdown), "files": .array(files)])))
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        VariableTemplate.extractSelectors(answer).map { (id + "." + $0.variable, $0.valueSelector) }
    }
}
