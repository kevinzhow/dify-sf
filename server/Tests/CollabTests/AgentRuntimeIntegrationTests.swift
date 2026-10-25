import AsyncHTTPClient
import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Agent workflow questions through real service", .enabled(if: testDbHost != nil && ProcessInfo.processInfo.environment["AGENT_RUNTIME_SERVICE_URL"] != nil))
struct AgentRuntimeIntegrationTests {
    static let yaml = """
    app: {mode: workflow, name: Agent integration}
    kind: app
    version: 0.3.1
    workflow:
      conversation_variables: []
      environment_variables: []
      features: {}
      graph:
        nodes:
        - id: start
          data: {type: start, title: Start, variables: []}
        - id: inline-agent
          data: {type: agent, version: '2', title: Agent, agent_node_kind: dify_agent, agent_task: fixture-two-questions, agent_declared_outputs: []}
        - id: end
          data:
            type: end
            title: End
            outputs:
            - {variable: answer, value_selector: [inline-agent, text]}
            - {variable: score, value_selector: [inline-agent, score]}
        edges:
        - {id: first, source: start, sourceHandle: source, target: inline-agent, targetHandle: target}
        - {id: second, source: inline-agent, sourceHandle: source, target: end, targetHandle: target}
    """
    @Test func twoQuestionsShareExecutionSurviveDraftEditsAndCompleteTheirOriginalToolCalls() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["AGENT_RUNTIME_SERVICE_URL"])
        let daemon = try #require(ProcessInfo.processInfo.environment["AGENT_PLUGIN_DAEMON_URL"])
        let provider = try #require(ProcessInfo.processInfo.environment["AGENT_MODEL_PROVIDER_URL"])
        var config = humanInputTestConfig(runtimeConfig(daemon: daemon, key: "fixture-daemon-key", tenant: "00000000-0000-0000-0000-000000000001"))
        config.agentService.url = endpoint; config.agentService.key = "fixture-agent-service-key"; config.agentService.inlineEnabled = true
        config.files.directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-runtime-files-" + UUID().uuidString).path
        config.files.signingKey = String(repeating: "fixture-only-signing-key", count: 2)
        config.files.internalURL = "http://winnie-agent-swift-tests:21306"; config.files.externalURL = "http://127.0.0.1:21306"
        let frozen = config
        try await withStore { store, logger in
            let registry = DocumentRegistry(store: store, config: frozen, logger: logger)
            let routes = try Routes(registry: registry, store: store, config: frozen, logger: logger)
            try await withApp(configure: { routes.register(on: $0) }) { app in
                try await app.testing(.running, options: .live(hostname: "0.0.0.0", port: 21306)) { client in
                    let api = API(client: client)
                    let (token, _, _) = try await runtimeFixture(api, endpoint: provider)
                    let key = ModelKey(provider: "langgenius/openai_api_compatible/openai_api_compatible", model: "stub-chat", modelType: "llm")
                    let state = try await store.modelProviderState()
                    let credential = try #require(state.modelCredentials[key]?.first)
                    let raw = try #require(credential.config)
                    var credentials = try #require(try JSONValue.parse(raw).object)
                    credentials["function_calling_type"] = "tool_call"; credentials["agent_thought_support"] = "only_thinking_supported"
                    try await store.updateModelCredential(key, id: credential.id, name: nil, config: JSONValue.object(credentials).compactJSON())
                    let appID = try await api.post("/v1/docs/import", Self.yaml, token: token).str("id")
                    var soul = AgentInlineConfig.empty
                    soul["model"] = ["plugin_id": "langgenius/openai_api_compatible", "model_provider": "openai_api_compatible", "model": "stub-chat", "model_settings": [:]]
                    soul["human"] = ["contacts": [["id": "operator", "name": "Operator", "method": "web_app"]], "tools": []]
                    let saved = try await api.send(.put, AgentComposerTests.path(appID), AgentComposerTests.payload(soul: soul, task: "fixture-two-questions").compactJSON(), token: token)
                    #expect(saved.status == 200, "\(saved.text)")
                    let savedJSON = try JSONValue.parse(saved.text)
                    let pinned = try #require(savedJSON["binding"]?["current_snapshot_id"]?.string)
                    // Enable one declared output after first creating the config, through the same collaborative transaction.
                    let seq = try #require(savedJSON["document_seq"]?.int)
                    var body = try #require(AgentComposerTests.payload(head: seq, soul: soul, task: "fixture-two-questions").object)
                    body["node_job"] = ["workflow_prompt": "fixture-two-questions", "declared_outputs": [["name": "score", "type": "number", "required": true]]]
                    let configured = try await api.send(.put, AgentComposerTests.path(appID), JSONValue.object(body).compactJSON(), token: token)
                    #expect(configured.status == 200, "\(configured.text)")
                    let configuredJSON = try JSONValue.parse(configured.text)
                    let activeSnapshot = try #require(configuredJSON["binding"]?["current_snapshot_id"]?.string)
                    #expect(activeSnapshot != pinned)
                    let response = try await api.post("/v1/apps/\(appID)/workflows/draft/run", #"{"inputs":{}}"#, token: token)
                    #expect(response.status == 200, "\(response.text)")
                    let frames = HumanInputRunTests.frames(response.text)
                    let firstToken = try #require(frames.first { $0["event"] == "human_input_required" }?["data"]?["form_token"]?.string, "\(response.text)")
                    let first = try #require(try await store.humanInputForm(token: firstToken))
                    let run = try #require(first.workflowRunId)
                    #expect(first.questionID == first.executionId + ":q1")
                    let initial = try #require(try await store.agentSession(execution: first.executionId))
                    #expect(initial.configSnapshotID == activeSnapshot && initial.status == "paused")
                    #expect(try await store.workflowRun(id: run)?.status == "paused")
                    #expect(frames.last?["data"]?["total_tokens"] == 8)
                    await routes.deliverAgentOutbox()
                    // A running draft edit must not change the model, task, contacts or config already pinned by this run.
                    let beforeEdit = try await registry.sequencer(appID).currentSnapshot().seq
                    let edited = try await api.send(.put, AgentComposerTests.path(appID), AgentComposerTests.payload(head: beforeEdit, soul: AgentInlineConfig.empty, task: "Changed after pause").compactJSON(), token: token)
                    #expect(edited.status == 200)
                    var request = HTTPClientRequest(url: "http://127.0.0.1:21306/v1/workflow/\(run)/events?include_state_snapshot=true&continue_on_pause=true")
                    request.headers.add(name: "Authorization", value: "Bearer " + token)
                    let follow = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
                    #expect(follow.status.code == 200)
                    let following = Task { try await follow.body.collect(upTo: 4 << 20) }
                    let submitted = try await api.post("/v1/form/human_input/\(firstToken)", #"{"action":"submit","inputs":{"answer":"First answer"}}"#, token: token)
                    #expect(submitted.status == 200, "\(submitted.text)")
                    var second: StoredHumanInputForm?
                    for _ in 0..<300 {
                        second = try await store.humanInputForms(workflowRunId: run).first { $0.questionID == first.executionId + ":q2" }
                        if second != nil { break }; try await Task.sleep(for: .milliseconds(50))
                    }
                    let next = try #require(second)
                    #expect(next.executionId == first.executionId && next.id != first.id)
                    #expect(next.renderedContent.contains("Question 2"))
                    #expect(try await store.agentSession(execution: first.executionId)?.configSnapshotID == activeSnapshot)
                    #expect(try await store.workflowRun(id: run)?.totalTokens == 0) // Paused totals live in the durable pause record.
                    let pauses = try await store.openPauses(workflowRunId: run)
                    #expect(pauses.first?.totalTokens == 16)
                    await routes.deliverAgentOutbox()
                    let answer = try await api.post("/v1/form/human_input/\(next.token)", #"{"action":"submit","inputs":{"answer":"Second answer"}}"#, token: token)
                    #expect(answer.status == 200, "\(answer.text)")
                    let wire = try await following.value
                    let events = HumanInputRunTests.frames(String(buffer: wire))
                    let filled = events.filter { $0["event"] == "human_input_form_filled" }
                    #expect(filled.count == 2)
                    #expect(filled.first?["data"]?["rendered_content"]?.string?.contains("First answer") == true)
                    #expect(events.last?["data"]?["status"] == "succeeded", "\(events.last?.compactJSON() ?? "")")
                    let final = try #require(try await store.workflowRun(id: run))
                    #expect(final.status == "succeeded" && final.totalTokens == 24)
                    #expect(try JSONValue.parse(final.outputs ?? "{}")["score"] == 7)
                    let traces = try await store.nodeExecutions(doc: appID, run: run)
                    #expect(traces.filter { $0.nodeType == "agent" }.count == 1)
                    #expect(Set(traces.map(\.index)).count == traces.count)
                    #expect(try await store.agentSession(execution: first.executionId)?.status == "completed")
                    await routes.deliverAgentOutbox(); await routes.deliverAgentOutbox()
                    #expect(try await store.pendingAgentJobs().isEmpty)
                }
            }
        }
    }
}
