// Real Dart harness -> Swift scope/credential gateway -> scripted Responses
// provider. No external provider, user account or sandbox is involved.
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

@Suite("Agent native harness through Swift", .enabled(if: testDbHost != nil && ProcessInfo.processInfo.environment["AGENT_NATIVE_SERVICE_URL"] != nil))
struct AgentNativeIntegrationTests {
    @Test func workflowSelectsTheWireRetriesAndRoundTripsOpaqueReasoningAndPlanEvents() async throws {
        let serviceURL = try #require(ProcessInfo.processInfo.environment["AGENT_NATIVE_SERVICE_URL"])
        let requests = Mutex<[JSONValue]>([]), pluginInvocations = Mutex(0)
        try await withApp(configure: { app in
            app.routes.post("plugin", ":tenant", "dispatch", "model", "schema") { _ in
                let schema: JSONValue = ["code": 0, "message": "", "data": ["model_schema": [
                    "model": "stub-chat", "label": ["en_US": "stub-chat"], "model_type": "llm", "features": ["tool-call"],
                    "fetch_from": "customizable-model", "model_properties": ["mode": "chat", "context_size": 500000],
                    "parameter_rules": [["name": "max_tokens", "max": 128000]],
                ]]]
                return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: "data: " + schema.compactJSON() + "\n\n"))
            }
            app.routes.post("plugin", ":tenant", "dispatch", "llm", "invoke") { _ in
                pluginInvocations.withLock { $0 += 1 }
                return Response(status: .internalServerError)
            }
            app.routes.post("v1", "responses") { req in
                let bytes = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20))) ?? Data()
                let payload = try JSONValue.parse(bytes)
                let n = requests.withLock { $0.append(payload); return $0.count }
                #expect(req.headers[.authorization] == "Bearer fixture-native-key")
                #expect(payload["model"] == "vendor-stub" && payload["reasoning"]?["effort"] == "max")
                #expect(payload["max_output_tokens"] == 32768)
                if n == 1 {
                    return Response(status: .serviceUnavailable, headers: [HTTPField.Name("Retry-After")!: "0"],
                        body: .init(string: #"{"error":{"code":"server_is_overloaded"}}"#))
                }
                let items: [JSONValue]
                if n == 2 {
                    items = [
                        ["type": "reasoning", "id": "rs_fixture", "encrypted_content": "opaque-fixture-only", "summary": []],
                        ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "Checking the fixture render"]]],
                        ["type": "function_call", "call_id": "call_plan", "name": "update_plan", "arguments": "{\"plan\":[{\"step\":\"Render fixture\",\"status\":\"in_progress\"}]}"],
                    ]
                } else {
                    let input = payload["input"]?.array ?? []
                    #expect(input.contains { $0["encrypted_content"] == "opaque-fixture-only" })
                    #expect(input.contains { $0["type"] == "function_call_output" && $0["call_id"] == "call_plan" })
                    items = [["type": "message", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": "native fixture finished"]]]]
                }
                var events = items.map { JSONValue.object(["type": "response.output_item.done", "item": $0]) }
                events.append(["type": "response.completed", "response": ["reasoning": ["effort": "max"], "usage": [
                    "input_tokens": 20, "output_tokens": 30, "total_tokens": 50,
                    "input_tokens_details": ["cached_tokens": 12], "output_tokens_details": ["reasoning_tokens": 19]]]])
                return Response(status: .ok, headers: [.contentType: "text/event-stream"],
                    body: .init(string: events.map { "data: " + $0.compactJSON() + "\n\n" }.joined()))
            }
        }) { provider in
            try await provider.testing(.running) { providerClient in
                let providerURL = "http://127.0.0.1:\(try #require(providerClient.port))"
                var config = AgentModelGatewayRouteTests.config(providerURL)
                config.agentService.url = serviceURL
                config.agentService.inlineEnabled = true
                config.agentService.timeoutSeconds = 30
                let frozen = config
                try await withStore { store, logger in
                    let registry = DocumentRegistry(store: store, config: frozen, logger: logger)
                    let routes = try CollabServer.Routes(registry: registry, store: store, config: frozen, logger: logger)
                    try await withApp(configure: { routes.register(on: $0) }) { server in
                        try await server.testing(.running, options: .live(hostname: "0.0.0.0", port: 21306)) { client in
                            let api = API(client: client)
                            let (owner, _, _) = try await runtimeFixture(api, endpoint: providerURL + "/v1")
                            let credentials: JSONValue = ["model": "stub-chat", "model_type": "llm", "credentials": [
                                "endpoint_url": .string(providerURL + "/v1"), "endpoint_model_name": "vendor-stub", "api_key": "fixture-native-key", "mode": "chat",
                                "api_type": "responses", "context_size": "500000", "max_tokens_to_sample": "128000", "function_calling_type": "tool_call"]]
                            #expect(try await api.post("/v1/workspace/model-providers/\(AgentModelWire.compatible)/models/credentials", credentials.compactJSON(), token: owner).status == 201)
                            let key = ModelKey(provider: AgentModelWire.compatible, model: "stub-chat", modelType: "llm")
                            let state = try await store.modelProviderState()
                            let selected = try #require(state.modelCredentials[key]?.first { $0.config?.contains("fixture-native-key") == true })
                            try await store.switchCustomModelCredential(key, id: selected.id)
                            let yaml = AgentRuntimeIntegrationTests.yaml.split(separator: "\n", omittingEmptySubsequences: false)
                                .filter { !$0.contains("value_selector: [inline-agent, score]") }.joined(separator: "\n")
                            let appID = try await api.post("/v1/docs/import", yaml, token: owner).str("id")
                            var soul = AgentInlineConfig.empty
                            soul["harness_style"] = "codex"; soul["tools"] = ["dify_tools": [], "cli_tools": [], "update_plan": true]
                            soul["model"] = ["plugin_id": "langgenius/openai_api_compatible", "model_provider": "openai_api_compatible", "model": "stub-chat",
                                "model_settings": ["reasoning_effort": "max", "max_tokens": 32768]]
                            let saved = try await api.send(.put, AgentComposerTests.path(appID), AgentComposerTests.payload(soul: soul, task: "Exercise the native fixture").compactJSON(), token: owner)
                            #expect(saved.status == 200, "\(saved.text)")
                            let response = try await api.post("/v1/apps/\(appID)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                            #expect(response.status == 200, "\(response.status): \(response.text)")
                            let frames = HumanInputRunTests.frames(response.text)
                            let final = try #require(frames.last?["data"], "\(response.text)")
                            #expect(final["status"] == "succeeded", "\(response.text)")
                            #expect(final["outputs"]?["answer"] == "native fixture finished")
                            #expect(final["total_tokens"] == 100)
                            let logs = frames.filter { $0["event"] == "agent_log" }.compactMap { $0["data"] }
                            for name in ["commentary", "plan", "model_retry"] { #expect(logs.contains { $0["metadata"]?["event"] == .string(name) }) }
                            let calls = logs.filter { $0["metadata"]?["event"] == "model_call" }
                            #expect(calls.count == 2)
                            #expect(calls.allSatisfy { $0["data"]?["reasoning"]?["effort_forwarded"] == "max" })
                            #expect(requests.withLock { $0.count } == 3 && pluginInvocations.withLock { $0 } == 0)
                            let run = try #require(final["id"]?.string)
                            let traces = try await store.nodeExecutions(doc: appID, run: run)
                            let agent = try #require(traces.first { $0.nodeType == "agent" })
                            let metadata = try JSONValue.parse(try #require(try await store.agentSession(execution: agent.id)).usage)
                            #expect(metadata["cached_tokens"] == 24 && metadata["reasoning_tokens"] == 38)
                            await routes.deliverAgentOutbox()
                        }
                    }
                }
            }
        }
    }
}
