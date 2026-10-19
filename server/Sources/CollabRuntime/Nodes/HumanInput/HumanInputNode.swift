// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// nodes/human_input/{human_input_node,entities}.py and entities/pause_reason.py. See ../../NOTICE.md.

public enum PauseReason: Sendable, Codable, Hashable {
    case hitlRequired(sessionId: String, nodeId: String, nodeTitle: String)
    case scheduled(message: String)

    public var json: JSONValue {
        switch self {
        case .hitlRequired(let sessionId, let nodeId, let title):
            return ["TYPE": "hitl_required", "session_id": .string(sessionId), "node_id": .string(nodeId), "node_title": .string(title)]
        case .scheduled(let message): return ["TYPE": "scheduled_pause", "message": .string(message)]
        }
    }
}

public struct HumanInputContext: Sendable {
    public var workflowExecutionId: String
    public var nodeId: String
    public var nodeTitle: String
    /// The same execution id is reused after a pause; different container rounds have distinct ids.
    public var executionId: String?
    public var pool: VariablePool
    public var userId: String?
    public var appId: String?
}

public enum HumanInputDecision: Sendable {
    case pause(sessionId: String)
    case completed(NodeRunResult)
    case expired(NodeRunResult)
}

/// Dify owns forms and their durable submission state; graphon owns the engine decision. The server adapter creates
/// a form once, returns pause while it is waiting, and supplies a completion (or the node-timeout branch) on resume.
public protocol HumanInputRuntime: Sendable {
    func decide(form: HumanInputFormConfig, context: HumanInputContext) async throws -> HumanInputDecision
}

public struct HumanInputNode: RuntimeNode {
    public var id: String
    public var form: HumanInputFormConfig
    public var runtime: any HumanInputRuntime
    public var base: BaseNodeData { form.base }
    public var nodeType: String { NodeType.humanInput }
    public var executionType: NodeExecutionType { .branch }

    public init(id: String, data: JSONObject, runtime: any HumanInputRuntime) throws {
        self.id = id
        form = try HumanInputFormConfig(data)
        self.runtime = runtime
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        let runId = [["sys", "workflow_execution_id"], ["sys", "workflow_run_id"]]
            .compactMap { context.pool.get($0)?.text }.first { !$0.isEmpty }
        guard let runId else { throw NodeError("ValueError", "workflow_execution_id is required for HITL") }
        let decision = try await runtime.decide(form: form, context: HumanInputContext(
            workflowExecutionId: runId, nodeId: id, nodeTitle: base.title, executionId: context.executionId,
            pool: context.pool, userId: context.userId, appId: context.appId))
        switch decision {
        case .pause(let sessionId):
            await emit(.pauseRequested(.hitlRequired(sessionId: sessionId, nodeId: id, nodeTitle: base.title)))
        case .completed(let result), .expired(let result): await emit(.completed(result))
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] { form.variableMapping(nodeId: id) }
}
