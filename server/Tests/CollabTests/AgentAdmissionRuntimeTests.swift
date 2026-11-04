import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

/// The actual workflow adapter and transactional capacity gate, with a local
/// agent protocol peer. It never invokes a provider or creates a sandbox.
@Suite("Agent queue budget through workflow runtime", .serialized, .enabled(if: testDbHost != nil))
struct AgentAdmissionRuntimeTests {
    @Test(arguments: ["queue_complete", "queue_expire", "queue_cancel", "execution_expire"])
    func admissionAndExecutionHaveIndependentBounds(_ scenario: String) async throws {
        let operation = Mutex<JSONValue>(.null), starts = Mutex(0)
        try await withApp(configure: { app in
            app.post("plugin", ":tenant", "dispatch", "model", "schema") { _ in
                let schema: JSONValue = ["code": 0, "message": "", "data": ["model_schema": [
                    "model": "stub-chat", "label": ["en_US": "stub-chat"], "model_type": "llm", "features": ["tool-call"],
                    "fetch_from": "customizable-model", "model_properties": ["mode": "chat", "context_size": 4096], "parameter_rules": []]]]
                return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: "data: " + schema.compactJSON() + "\n\n"))
            }
            app.post("v1", "executions", ":id", "lease") { _ in
                Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
            app.post("v1", "operations") { req in
                let bytes = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20))) ?? Data()
                let body = try JSONValue.parse(bytes)
                operation.withLock { $0 = body }; starts.withLock { $0 += 1 }
                return Response(status: .accepted, body: .init(string: #"{"protocol":"dify-sf-agent/1","run_id":"admission-fixture"}"#))
            }
            app.get("v1", "runs", "admission-fixture", "events") { _ in
                if scenario == "execution_expire" { try await Task.sleep(for: .seconds(3)) }
                else { try await Task.sleep(for: .milliseconds(150)) }
                return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string:
                    "id: 1\nevent: run_started\ndata: {\"executor_profile\":\"default\"}\n\nid: 2\nevent: succeeded\ndata: {\"status\":\"succeeded\"}\n\n"))
            }
            app.get("v1", "runs", "admission-fixture") { _ in
                let body = operation.withLock { $0 }
                let value: JSONValue = ["protocol": "dify-sf-agent/1", "run_id": "admission-fixture", "operation_id": body["operation_id"] ?? .null,
                    "status": "succeeded", "last_event_id": 2, "result": ["candidate": ["text": "fixture completed"]]]
                return Response(status: .ok, body: .init(string: value.compactJSON()))
            }
        }) { peer in
            try await peer.testing(.running) { client in
                let endpoint = "http://127.0.0.1:\(try #require(client.port))"
                var config = runtimeConfig(daemon: endpoint)
                config.agentService.url = endpoint; config.agentService.key = "fixture-only"
                config.agentService.inlineEnabled = true; config.agentService.maxConcurrent = 1
                config.agentService.timeoutSeconds = 2
                config.agentService.admissionTimeoutSeconds = scenario == "queue_expire" ? 1 : 15
                let frozen = config
                try await withServerAndRoutes(config: frozen) { api, store, _ in
                    let (owner, user, _) = try await runtimeFixture(api, endpoint: endpoint + "/v1")
                    let yaml = AgentRuntimeIntegrationTests.yaml.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { !$0.contains("value_selector: [inline-agent, score]") }.joined(separator: "\n")
                    let app = try await api.post("/v1/docs/import", yaml, token: owner).str("id")
                    var soul = AgentInlineConfig.empty
                    soul["model"] = ["plugin_id": "langgenius/openai_api_compatible", "model_provider": "openai_api_compatible", "model": "stub-chat", "model_settings": [:]]
                    let saved = try await api.send(.put, AgentComposerTests.path(app), AgentComposerTests.payload(soul: soul).compactJSON(), token: owner)
                    #expect(saved.status == 200, "\(saved.text)")
                    let pinned = try #require(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID))
                    let blockerRun = UUID().uuidString.lowercased()
                    var blocker: StoredAgentSession?
                    if scenario != "execution_expire" {
                        try await store.insertWorkflowRun(.init(id: blockerRun, docId: app, docSeq: 3, workflowId: app, type: "workflow", triggeredFrom: "debugging",
                            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: user, createdAt: Date()))
                        blocker = try await store.createAgentSession(.init(executionID: UUID().uuidString.lowercased(), workflowRunID: blockerRun, docID: app,
                            nodeID: AgentComposerTests.nodeID, agentID: pinned.agentId, configSnapshotID: pinned.id, ownerID: "queue-fixture"), maxConcurrent: 1)
                    }
                    let running = Task { try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner) }
                    var current: StoredWorkflowRun?
                    for _ in 0..<200 {
                        current = try await store.workflowRuns(doc: app, triggeredFrom: "debugging", status: nil, limit: 20, lastId: nil)?.runs.first { $0.id != blockerRun }
                        if current != nil { break }; try await Task.sleep(for: .milliseconds(20))
                    }
                    let run = try #require(current)
                    if scenario == "queue_complete" {
                        try await Task.sleep(for: .seconds(3)) // longer than the entire execution budget
                        #expect(starts.withLock { $0 } == 0)
                        let held = try #require(blocker)
                        try await store.abandonAgentExecution(execution: held.executionID, owner: held.ownerID, generation: held.generation)
                    } else if scenario == "queue_cancel" {
                        try await Task.sleep(for: .milliseconds(350))
                        #expect(try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(run.id)/stop", token: owner).status == 200)
                    }
                    let response = try await running.value
                    let frames = HumanInputRunTests.frames(response.text)
                    let final = try #require(try await store.workflowRun(id: run.id))
                    let logs = frames.filter { $0["event"] == "agent_log" }.compactMap { $0["data"] }
                    if scenario == "queue_complete" {
                        #expect(final.status == "succeeded", "\(response.text)")
                        #expect(starts.withLock { $0 } == 1)
                        #expect(operation.withLock { $0["limits"]?["timeout_seconds"] } == 2)
                        #expect(logs.contains { $0["metadata"]?["event"] == "admission" && $0["data"]?["phase"] == "queued" })
                        #expect(logs.contains { $0["metadata"]?["event"] == "admission" && $0["data"]?["phase"] == "admitted" })
                        let node = try #require(try await store.nodeExecutions(doc: app, run: run.id).first { $0.nodeType == "agent" })
                        let meta = try JSONValue.parse(node.executionMetadata ?? "{}")
                        #expect(meta["agent_timing_version"] == 2)
                        #expect((meta["agent_queue_elapsed_time"]?.double ?? 0) >= 3)
                        #expect(node.elapsedTime > 0 && node.elapsedTime < 2)
                        let session = try #require(try await store.agentSession(execution: node.id))
                        #expect(try JSONValue.parse(session.usage)["timing_version"] == 2)
                    } else if scenario == "execution_expire" {
                        #expect(final.status == "failed" && starts.withLock { $0 } == 1)
                        #expect(final.error?.contains("deadline") == true, "\(response.text)")
                    } else {
                        #expect(starts.withLock { $0 } == 0, "No agent operation may start while queued or cancelled")
                        #expect(final.status == (scenario == "queue_cancel" ? "stopped" : "failed"))
                        if scenario == "queue_expire" {
                            #expect(logs.contains { $0["data"]?["phase"] == "expired" })
                            let node = try #require(try await store.nodeExecutions(doc: app, run: run.id).first { $0.nodeType == "agent" })
                            #expect(node.elapsedTime == 0)
                            #expect(try JSONValue.parse(node.executionMetadata ?? "{}")["agent_queue_elapsed_time"]?.double ?? 0 >= 1)
                        }
                    }
                    if let held = blocker { try await store.abandonAgentExecution(execution: held.executionID, owner: held.ownerID, generation: held.generation) }
                }
            }
        }
    }
}
