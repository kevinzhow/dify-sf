import CollabRuntime
import Foundation
import Testing

private struct FixedAgentRuntime: AgentRuntime {
    let result: NodeRunResult
    func prepare(nodeID: String, data: AgentNodeData) async throws {}
    func run(nodeID: String, data: AgentNodeData, context: NodeRunContext) async throws -> AgentNodeDecision { .completed(result) }
}
private struct FixedAgentFactory: NodeFactory {
    let result: NodeRunResult
    func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        if config.type == "agent" { return AgentV2Node(id: config.id, data: try AgentNodeData(config.data), runtime: FixedAgentRuntime(result: result)) }
        return try await BuiltinNodeFactory(services: .init()).createNode(config, graph: graph)
    }
}

@Suite("Agent field failures in the graph engine")
struct AgentOutputEngineTests {
    static func run(_ result: NodeRunResult, nodeStrategy: String? = nil) async throws -> [GraphEngineEvent] {
        func node(_ id: String, _ data: JSONObject) -> JSONValue { ["id": .string(id), "data": .object(data)] }
        func edge(_ source: String, _ target: String, _ handle: String = "source") -> JSONValue {
            ["id": .string(source + "-" + target), "source": .string(source), "target": .string(target), "sourceHandle": .string(handle)]
        }
        var agent: JSONObject = ["type": "agent", "version": "2", "title": "Agent", "agent_node_kind": "dify_agent",
            "agent_binding": ["binding_type": "inline_agent", "agent_id": "private", "current_snapshot_id": "frozen"],
            "agent_task": "Task", "agent_declared_outputs": []]
        if let nodeStrategy { agent["error_strategy"] = .string(nodeStrategy) }
        let graph = try GraphConfig(json: ["nodes": [node("start", ["type": "start", "variables": []]), node("agent", agent),
            node("normal", ["type": "end", "outputs": []]), node("error", ["type": "end", "outputs": []])],
            "edges": [edge("start", "agent"), edge("agent", "normal"), edge("agent", "error", "fail-branch")]])
        let built = try await RuntimeGraph.build(graph, rootId: "start", factory: FixedAgentFactory(result: result))
        var events: [GraphEngineEvent] = []
        for await event in GraphEngine(graph: built).run(pool: VariablePool()) { events.append(event) }
        return events
    }
    static func started(_ events: [GraphEngineEvent]) -> Set<String> {
        Set(events.compactMap { if case .node(.started(_, let id, _, _, _, _)) = $0 { id } else { nil } })
    }
    @Test func successfulAgentUsesOnlyItsNormalEdge() async throws {
        let events = try await Self.run(.init(status: .succeeded, outputs: ["text": "done"]))
        #expect(Self.started(events).contains("normal"))
        #expect(!Self.started(events).contains("error"))
        guard case .runSucceeded? = events.last else { Issue.record("The successful agent must complete the workflow"); return }
    }
    @Test func fieldFailBranchOverridesAnAbsentNodeStrategy() async throws {
        let events = try await Self.run(.init(status: .failed, error: "Invalid score", errorType: "output_type_check_failed_fail_branch"))
        #expect(Self.started(events).contains("error"))
        #expect(!Self.started(events).contains("normal"))
        #expect(events.contains { if case .node(.exception(_, "agent", _, _, let result, _)) = $0 {
            return result.outputs["error_type"] == "output_type_check_failed_fail_branch" && result.edgeSourceHandle == "fail-branch"
        }; return false })
        guard case .runPartialSucceeded? = events.last else { Issue.record("The error branch must finish the workflow"); return }
    }
    @Test func fieldStopCannotBeChangedIntoANodeDefault() async throws {
        let events = try await Self.run(.init(status: .failed, error: "Invalid score", errorType: "output_type_check_failed"), nodeStrategy: "default-value")
        #expect(!Self.started(events).contains("normal") && !Self.started(events).contains("error"))
        guard case .runFailed? = events.last else { Issue.record("The explicit field stop must fail the workflow"); return }
    }
}
