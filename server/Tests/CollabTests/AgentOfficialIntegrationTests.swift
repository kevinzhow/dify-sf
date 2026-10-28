// Real Agent service, supervisor, isolated sandbox and official Codex process
// through Swift to a synthetic provider. Never uses an external model account.
import CollabCore
import CollabStore
import CollabRuntime
import Foundation
import HTTPTypes
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Official Codex through the workflow server", .serialized, .enabled(if: testDbHost != nil && ProcessInfo.processInfo.environment["AGENT_OFFICIAL_SERVICE_URL"] != nil))
struct AgentOfficialIntegrationTests {
    @Test(arguments: [nil, "high", "xhigh", "max"] as [String?])
    func workflowRecordsTheOfficialProcessUsageBeforeFinishing(effort: String?) async throws {
        let expectedEffort = effort ?? "max"
        let service = try #require(ProcessInfo.processInfo.environment["AGENT_OFFICIAL_SERVICE_URL"])
        let requests = Mutex<[JSONValue]>([])
        try await withOfficialFixtureProvider({ req in
            #expect(req.headers[.authorization] == "Bearer sk-native-fixture-only")
            let data = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20))) ?? Data()
            let body = try JSONValue.parse(data)
            requests.withLock { $0.append(body) }
            #expect(body["model"] == "vendor-stub" && body["reasoning"]?["effort"] == .string(expectedEffort))
            #expect(body["client_metadata"]?.object != nil && body["max_output_tokens"] == 4096)
            let message: JSONValue = ["type": "message", "id": "msg_official", "role": "assistant", "status": "completed",
                "content": [["type": "output_text", "text": "official fixture finished"]]]
            let events: [JSONValue] = [
                ["type": "response.created", "response": ["id": "resp_official"]],
                ["type": "response.output_item.added", "output_index": 0, "item": message],
                ["type": "response.output_item.done", "output_index": 0, "item": message],
                ["type": "response.completed", "response": ["id": "resp_official", "status": "completed", "output": .array([message]),
                    "usage": ["input_tokens": 20, "output_tokens": 3, "total_tokens": 23,
                        "input_tokens_details": ["cached_tokens": 12], "output_tokens_details": ["reasoning_tokens": 2]]]]]
            return Response(status: .ok, headers: [.contentType: "text/event-stream"],
                body: .init(string: events.map { "event: \($0["type"]!.string!)\ndata: \($0.compactJSON())\n\n" }.joined()))
        }) { provider in
            do {
                let daemon = String(provider.dropLast(3))
                var config = AgentModelGatewayRouteTests.config(daemon)
                config.agentService.url = service
                config.agentService.inlineEnabled = true
                config.agentService.shellEnabled = true
                config.agentService.timeoutSeconds = 90
                let frozen = config
                try await withStore { store, logger in
                    let routes = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: frozen, logger: logger), store: store, config: frozen, logger: logger)
                    try await withApp(configure: { routes.register(on: $0) }) { server in
                        try await server.testing(.running, options: .live(hostname: "0.0.0.0", port: 21307)) { client in
                            let api = API(client: client)
                            let (owner, _, _) = try await runtimeFixture(api, endpoint: provider)
                            let credentials: JSONValue = ["model": "stub-chat", "model_type": "llm", "credentials": [
                                "endpoint_url": .string(provider), "endpoint_model_name": "vendor-stub", "api_key": "sk-native-fixture-only", "mode": "chat",
                                "api_type": "responses", "context_size": "500000", "max_tokens_to_sample": "4096", "function_calling_type": "tool_call"]]
                            #expect(try await api.post("/v1/workspace/model-providers/\(AgentModelWire.compatible)/models/credentials", credentials.compactJSON(), token: owner).status == 201)
                            let key = ModelKey(provider: AgentModelWire.compatible, model: "stub-chat", modelType: "llm")
                            let state = try await store.modelProviderState()
                            let selected = try #require(state.modelCredentials[key]?.first { $0.config?.contains("sk-native-fixture-only") == true })
                            try await store.switchCustomModelCredential(key, id: selected.id)
                            var yaml = AgentRuntimeIntegrationTests.yaml.split(separator: "\n", omittingEmptySubsequences: false)
                                .filter { !$0.contains("value_selector: [inline-agent, score]") }.joined(separator: "\n")
                            if effort != nil {
                                var alternate = credentials.object!
                                alternate["model"] = "stub-chat-alternate"
                                #expect(try await api.post("/v1/workspace/model-providers/\(AgentModelWire.compatible)/models/credentials",
                                    JSONValue.object(alternate).compactJSON(), token: owner).status == 201)
                                yaml = yaml.replacingOccurrences(of: "variables: []}", with:
                                    "variables: [{variable: model, type: select, required: true, options: [stub-chat, stub-chat-alternate]}, {variable: effort, type: select, required: true, options: [high, xhigh, max]}]}")
                                    .replacingOccurrences(of: "agent_node_kind: dify_agent,", with:
                                        "agent_node_kind: dify_agent, agent_model: {model: '{{#start.model#}}', reasoning_effort: '{{#start.effort#}}'},")
                            }
                            let app = try await api.post("/v1/docs/import", yaml, token: owner).str("id")
                            var soul = AgentInlineConfig.empty
                            soul["harness_style"] = "codex"
                            soul["tools"] = ["dify_tools": [], "cli_tools": [], "update_plan": true]
                            soul["model"] = ["plugin_id": "langgenius/openai_api_compatible", "model_provider": "openai_api_compatible", "model": "stub-chat",
                                "model_settings": ["reasoning_effort": "max", "max_tokens": 4096]]
                            let saved = try await api.send(.put, AgentComposerTests.path(app), AgentComposerTests.payload(soul: soul, task: "Return the synthetic fixture answer without calling tools.").compactJSON(), token: owner)
                            #expect(saved.status == 200, "\(saved.text)")
                            let runInput: JSONValue = effort.map { ["inputs": ["model": "stub-chat-alternate", "effort": .string($0)]] } ?? ["inputs": [:]]
                            let response = try await api.post("/v1/apps/\(app)/workflows/draft/run", runInput.compactJSON(), token: owner)
                            let frames = HumanInputRunTests.frames(response.text)
                            let final = try #require(frames.last?["data"], "\(response.status): \(response.text)")
                            #expect(final["status"] == "succeeded" && final["outputs"]?["answer"] == "official fixture finished", "\(response.text)")
                            #expect(final["total_tokens"] == 23)
                            let calls = frames.filter { $0["event"] == "agent_log" && $0["data"]?["metadata"]?["event"] == "model_call" }
                            #expect(calls.count == 2)
                            let finished = try #require(calls.first { $0["data"]?["data"]?["phase"] == "finished" })
                            #expect(finished["data"]?["data"]?["usage"]?["cached_tokens"] == 12)
                            #expect(requests.withLock { $0.count } == 1)
                            let started = try #require(frames.first { $0["event"] == "agent_log" && $0["data"]?["metadata"]?["event"] == "run_started" })
                            let resolved = try #require(started["data"]?["data"]?["resolved_model"])
                            #expect(resolved["model"] == .string(effort == nil ? "stub-chat" : "stub-chat-alternate"))
                            #expect(resolved["parameters"]?["reasoning_effort"] == .string(expectedEffort))
                            #expect(resolved["credential_ref"] == nil)
                            let completed = try #require(frames.first { $0["event"] == "node_finished" && $0["data"]?["node_id"] == "inline-agent" }?["data"])
                            #expect(completed["inputs"]?["model"] == resolved)
                            let executionID = try #require(completed["id"]?.string)
                            let session = try #require(try await store.agentSession(execution: executionID))
                            #expect(try JSONValue.parse(session.usage)["model_selection"]?["model"] == resolved["model"])
                            let savedSequence = try #require(try JSONValue.parse(saved.text)["document_seq"]?.int)
                            #expect(try await routes.registry.sequencer(app).currentSnapshot().seq == savedSequence)

                            // The production worker first commits the ACK; only
                            // its next pass can admit sandbox cleanup.
                            await routes.deliverAgentOutbox()
                            await routes.deliverAgentOutbox()
                            #expect(try await store.pendingAgentJobs().isEmpty)
                        }
                    }
                }
            }
        }
    }
}

private func withOfficialFixtureProvider(_ handler: @Sendable @escaping (Request) async throws -> Response,
                                        body: @Sendable @escaping (String) async throws -> Void) async throws {
    try await withApp(configure: { app in
        app.routes.post("v1", "responses", use: handler)
        app.routes.post("plugin", ":tenant", "dispatch", "model", "schema") { _ in
            let schema: JSONValue = ["code": 0, "message": "", "data": ["model_schema": [
                "model": "stub-chat", "label": ["en_US": "stub-chat"], "model_type": "llm", "features": ["tool-call", "vision"],
                "fetch_from": "customizable-model", "model_properties": ["mode": "chat", "context_size": 500000],
                "parameter_rules": [["name": "max_tokens", "max": 4096], ["name": "reasoning_effort", "options": ["high", "xhigh", "max"]]]]]]
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: "data: " + schema.compactJSON() + "\n\n"))
        }
    }) { app in
        try await app.testing(.running) { client in try await body("http://127.0.0.1:\(try #require(client.port))/v1") }
    }
}
