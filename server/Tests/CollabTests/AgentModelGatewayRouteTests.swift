import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent model gateway routes", .enabled(if: testDbHost != nil))
struct AgentModelGatewayRouteTests {
    static let path = "/inner/agent/llm/invoke"
    static let serviceKey = "fixture-agent-service-key"

    static func config(_ daemon: String) -> ServerConfig {
        var config = runtimeConfig(daemon: daemon)
        config.agentService.url = "http://agent-service.invalid"
        config.agentService.key = serviceKey
        return config
    }

    static func fixture(_ api: API, _ store: PostgresStore, _ routes: Routes) async throws -> (AgentModelScope, String) {
        let (_, ownerID, app) = try await runtimeFixture(api)
        let runID = UUID().uuidString.lowercased()
        let run = StoredWorkflowRun(id: runID, docId: app, docSeq: 0, workflowId: "draft", type: "workflow",
            triggeredFrom: "debugging", version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: ownerID, createdAt: Date())
        try await store.insertWorkflowRun(run)
        let scope = AgentModelScope(operationID: "execution:0:0", generation: 1,
            execution: ["tenant_id": .string(routes.config.pluginDaemonTenant), "app_id": .string(app), "workflow_run_id": .string(runID),
                "node_id": "agent-node", "execution_id": "execution", "agent_config_snapshot_id": "snapshot",
                "user_id": .string(ownerID), "user_from": "account", "invoke_from": "debugger"],
            provider: "langgenius/openai_api_compatible/openai_api_compatible", model: "stub-chat", maxCalls: 5,
            expiresAt: Date().addingTimeInterval(60))
        return (scope, try await routes.agentModelScopes.activate(scope))
    }

    static func body(_ scope: AgentModelScope, call: Int = 1, callerOverrides: JSONObject = [:], text: String = "hello") -> String {
        var caller = scope.caller.merging(callerOverrides)
        caller["run_id"] = "fixture-agent-run"
        caller["invocation_id"] = .string("fixture-agent-run:\(call)")
        caller["call_index"] = .int(call)
        let payload: JSONValue = [
            "caller": .object(caller),
            "target": ["provider": .string(scope.provider), "model": .string(scope.model), "stream": true,
                "prompt_messages": [
                    ["role": "assistant", "content": .null, "reasoning_content": "preserved thought",
                     "tool_calls": [["id": "ask_human:0", "type": "function", "function": ["name": "ask_human", "arguments": "{}"]]]],
                    ["role": "tool", "content": "{\"city\":\"Kyoto\"}", "tool_call_id": "ask_human:0"],
                    ["role": "user", "content": .string(text)],
                ],
                "tools": [["name": "add", "description": "add", "parameters": ["type": "object"]]],
                "model_parameters": ["temperature": 0.2]],
        ]
        return payload.compactJSON()
    }

    @Test func callbackUsesTheWorkspaceCredentialsAndPreservesTheToolConversation() async throws {
        try await withFakeDaemon { daemon, log in
            try await withServerAndRoutes(config: Self.config(daemon)) { api, store, routes in
                let (scope, token) = try await Self.fixture(api, store, routes)
                let reply = try await api.send(.post, Self.path, Self.body(scope), token: Self.serviceKey, headers: [("X-Agent-Run-Token", token)])
                #expect(reply.status == 200 && reply.text.contains("echo:") && reply.text.contains("hello"), "\(reply.status): \(reply.text)")
                let invocation = try #require(log.requests.last { $0.path.hasSuffix("/dispatch/llm/invoke") })
                #expect(invocation.body["data"]?["tools"]?.array?.first?["name"] == "add")
                let messages = try #require(invocation.body["data"]?["prompt_messages"]?.array)
                #expect(messages[0]["reasoning_content"] == "preserved thought")
                #expect(messages[0]["tool_calls"]?.array?.first?["id"] == "ask_human:0")
                #expect(messages[1]["tool_call_id"] == "ask_human:0")
                #expect(invocation.body["data"]?["credentials"]?.object?.isEmpty == false)
                #expect(!reply.text.contains("credentials") && !reply.text.contains("sk-good"))
                let usage = await routes.agentModelScopes.revoke(token: token)
                #expect(usage.totalTokens == 8)
            }
        }
    }

    @Test func serviceAndRunAuthenticationAndCurrentRunStateAreBothRequired() async throws {
        try await withFakeDaemon { daemon, log in
            try await withServerAndRoutes(config: Self.config(daemon)) { api, store, routes in
                let (scope, token) = try await Self.fixture(api, store, routes)
                #expect(try await api.post(Self.path, Self.body(scope)).status == 401)
                #expect(try await api.post(Self.path, Self.body(scope), token: Self.serviceKey).status == 401)
                let forged = try await api.send(.post, Self.path, Self.body(scope, callerOverrides: ["tenant_id": "elsewhere"]),
                    token: Self.serviceKey, headers: [("X-Agent-Run-Token", token)])
                #expect(forged.status == 403)
                try await store.finishWorkflowRun(id: scope.workflowRunID, status: "stopped", outputs: nil, error: nil,
                    elapsedTime: 0, totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
                let stopped = try await api.send(.post, Self.path, Self.body(scope), token: Self.serviceKey,
                    headers: [("X-Agent-Run-Token", token)])
                #expect(stopped.status == 403)
                #expect(!log.requests.contains { $0.path.hasSuffix("/dispatch/llm/invoke") })
                _ = await routes.agentModelScopes.revoke(token: token)
            }
        }
    }

    @Test func duplicateCallIsRejectedAndProviderErrorsDoNotReflectSecrets() async throws {
        try await withFakeDaemon { daemon, log in
            try await withServerAndRoutes(config: Self.config(daemon)) { api, store, routes in
                let (scope, token) = try await Self.fixture(api, store, routes)
                let body = Self.body(scope, text: "[[fail]]")
                let first = try await api.send(.post, Self.path, body, token: Self.serviceKey, headers: [("X-Agent-Run-Token", token)])
                #expect(first.status == 200 && first.text.contains("AgentModelInvokeError"))
                #expect(!first.text.contains("Incorrect API key") && !first.text.contains("sk-good"))
                let duplicate = try await api.send(.post, Self.path, body, token: Self.serviceKey, headers: [("X-Agent-Run-Token", token)])
                #expect(duplicate.status == 409 && duplicate.errorCode == "duplicate_invocation")
                #expect(log.requests.filter { $0.path.hasSuffix("/dispatch/llm/invoke") }.count == 1)
                _ = await routes.agentModelScopes.revoke(token: token)
            }
        }
    }

    @Test func noAgentConfigurationMeansNoCallback() async throws {
        try await withServer { api, _, _ in
            let reply = try await api.post(Self.path, "{}")
            #expect(reply.status == 503)
        }
    }
}
