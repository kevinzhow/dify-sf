import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Cross-provider Agent model selection", .enabled(if: testDbHost != nil))
struct AgentModelSelectionTests {
    @Test func selectedCredentialsDetermineWireTransportAndCapabilitiesWithoutInvokingAModel() async throws {
        // Only schema RPCs are implemented. A mistaken generation request fails instead of spending tokens.
        try await withApp(configure: { app in
            app.post("plugin", ":tenant", "dispatch", "model", "schema") { req async throws -> Response in
                let bytes = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20))) ?? Data()
                let data = try JSONValue.parse(bytes)["data"]
                let deepSeek = data?["provider"] == "deepseek"
                #expect(data?["credentials"]?[deepSeek ? "api_key" : "openai_api_key"] ==
                    .string(deepSeek ? "fixture-deepseek-only" : "fixture-openai-only"))
                let schema: JSONValue = ["code": 0, "data": ["model_schema": [
                    "model": "fixture-model", "model_type": "llm", "label": ["en_US": "Fixture model"],
                    "features": deepSeek ? ["tool-call"] : ["tool-call", "vision"],
                    "model_properties": ["mode": "chat", "context_size": .int(deepSeek ? 64000 : 128000)],
                    "parameter_rules": [["name": "max_tokens", "max": .int(deepSeek ? 8192 : 16384)],
                                        ["name": "reasoning_effort", "options": ["low", "high", "max"]]]]]]
                return Response(status: .ok, headers: [.contentType: "text/event-stream"],
                    body: .init(string: "data: " + schema.compactJSON() + "\n\n"))
            }
        }) { daemon in
            try await daemon.testing(.running) { client in
                var config = runtimeConfig(daemon: "http://127.0.0.1:\(try #require(client.port))")
                config.agentService.url = "http://127.0.0.1:1"
                config.agentService.key = "fixture-service-key"
                config.agentService.inlineEnabled = true
                config.agentService.codexWebsocketPort = 21499
                try await withServerAndRoutes(config: config) { api, store, routes in
                    let (token, owner, app) = try await AgentComposerTests.seed(api, store)
                    for provider in [AgentModelWire.openAI, AgentModelWire.deepSeek] {
                        let credentials: JSONObject = provider == AgentModelWire.deepSeek
                            // Even a misconfigured DeepSeek endpoint must never select the OpenAI-only WS transport.
                            ? ["api_key": "fixture-deepseek-only", "endpoint_url": "https://api.openai.com/v1"]
                            : ["openai_api_key": "fixture-openai-only"]
                        _ = try await store.createModelCredential(.init(provider: provider, model: "fixture-model", modelType: "llm"),
                            name: nil, config: JSONValue.object(credentials).compactJSON(), createdBy: owner)
                    }
                    var original = AgentInlineConfig.empty
                    original["harness_style"] = "codex"
                    original["model"] = ["plugin_id": "unused/plugin", "model_provider": "unavailable", "model": "unconfigured",
                        "credential_ref": ["type": "provider", "id": "foreign-credential"],
                        "model_settings": ["temperature": 0.7, "max_tokens": 123]]
                    let saved = try await api.send(.put, AgentComposerTests.path(app),
                        AgentComposerTests.payload(soul: original).compactJSON(), token: token)
                    #expect(saved.status == 200, "\(saved.text)")
                    let binding = try #require(try JSONValue.parse(saved.text)["binding"])
                    let data = try AgentNodeData(["type": "agent", "version": "2", "agent_node_kind": "dify_agent",
                        "agent_task": "Fixture only", "agent_binding": binding,
                        "agent_model": ["selection": "{{#start.model#}}", "reasoning_effort": "{{#start.effort#}}"]])
                    let runtime = ServerAgentRuntime(routes: routes, appID: app, runID: "fixture-run", userID: owner,
                        endUserID: nil, pending: PendingHumanInputForms(), decisions: [:])
                    // The unused fixed default is unavailable, but must not block a full runtime selection.
                    try await runtime.prepare(nodeID: AgentComposerTests.nodeID, data: data)
                    for provider in [AgentModelWire.openAI, AgentModelWire.deepSeek] {
                        var pool = VariablePool()
                        try pool.add(["start", "model"], JSONValue.string("\(provider)::fixture-model"))
                        try pool.add(["start", "effort"], "high")
                        let soul = try data.modelInputs.resolve(AgentInlineConfig(original), pool: pool)
                        let envelope = try await runtime.modelEnvelope(soul)
                        let deepSeek = provider == AgentModelWire.deepSeek
                        #expect(envelope["provider"] == .string(provider) && envelope["name"] == "fixture-model")
                        #expect(envelope["wire"] == "responses")
                        #expect(envelope["transport"] == .string(deepSeek ? "http" : "websocket"))
                        #expect(envelope["context_window"] == .int(deepSeek ? 64000 : 128000))
                        #expect(envelope["max_output_tokens"] == .int(deepSeek ? 8192 : 16384))
                        #expect(envelope["input_modalities"] == (deepSeek ? ["text"] : ["text", "image"]))
                        #expect(envelope["parameters"] == ["reasoning_effort": "high"])
                        #expect(!JSONValue.object(envelope).compactJSON().contains("fixture-openai-only"))
                        #expect(!JSONValue.object(envelope).compactJSON().contains("fixture-deepseek-only"))
                    }
                }
            }
        }
    }
}
