import Foundation
import Testing
@testable import CollabRuntime
@testable import CollabServer

@Suite("Agent model wire")
struct AgentModelWireTests {
    @Test func interleavedToolFragmentsKeepTheirIndexAndOriginalIDs() throws {
        var accumulator = LLMResultAccumulator()
        func chunk(_ calls: [JSONValue]) -> LLMResultChunk {
            LLMResultChunk(json: ["model": "fixture", "delta": ["message": ["tool_calls": .array(calls)]]])
        }
        let first = chunk([
            ["index": 0, "id": "ask_human:0", "type": "function", "function": ["name": "ask_human", "arguments": "{\"city\":"]],
            ["index": 1, "id": "shell/run:1", "type": "function", "function": ["name": "shell_run", "arguments": "{\"command\":"]],
        ])
        #expect(first.json["delta"]?["message"]?["tool_calls"]?.array?.first?["index"] == 0)
        try accumulator.consume(first)
        try accumulator.consume(chunk([["index": 1, "function": ["arguments": "\"pwd\"}"]]]))
        try accumulator.consume(chunk([["index": 0, "function": ["arguments": "\"Kyoto\"}"]]]))
        #expect(accumulator.toolCalls.map(\.id) == ["ask_human:0", "shell/run:1"])
        #expect(accumulator.toolCalls.map(\.arguments) == [#"{"city":"Kyoto"}"#, #"{"command":"pwd"}"#])
        // A completed assistant prompt carries opaque IDs but no stream-only indexes.
        #expect(accumulator.toolCalls[0].json["index"] == nil)
    }

    @Test func reasoningIsSeparateAndRoundTripsWithoutBecomingAnswerText() throws {
        let chunk = LLMResultChunk(json: [
            "model": "fixture", "delta": ["index": 0, "message": ["role": "assistant", "content": "answer", "reasoning_content": "private thought"],
                                        "finish_reason": "stop"],
        ])
        #expect(chunk.content == .text("answer"))
        #expect(chunk.reasoningContent == "private thought")
        let again = LLMResultChunk(json: chunk.json)
        #expect(again.reasoningContent == "private thought")
        #expect(again.content == .text("answer"))
        let message = try AgentModelGatewayRequest.message([
            "role": "assistant", "content": .null, "reasoning_content": "thought before tool",
            "tool_calls": [["id": "ask_human:0", "type": "function", "function": ["name": "ask_human", "arguments": "{}"]]],
        ])
        #expect(message.json["reasoning_content"] == "thought before tool")
        #expect(message.json["content"] == .null)
    }

    @Test func usageDetailsAreNotAddedToTotalsAndUnknownIsNotZero() {
        let a = LLMUsage(json: ["prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30,
                               "completion_tokens_details": ["reasoning_tokens": 12], "prompt_tokens_details": ["cached_tokens": 4]])
        let b = LLMUsage(json: ["prompt_tokens": 8, "completion_tokens": 9, "total_tokens": 17, "reasoning_tokens": 5, "cached_tokens": 2])
        let total = a.plus(b)
        #expect(total.totalTokens == 47 && total.completionTokens == 29)
        #expect(total.reasoningTokens == 17 && total.cachedTokens == 6)
        #expect(total.json["reasoning_tokens"] == 17)
        let unknown = LLMUsage(json: ["prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3])
        #expect(a.plus(unknown).reasoningTokens == nil)
        #expect(unknown.json["reasoning_tokens"] == nil)
        #expect(LLMUsage.empty.plus(a).reasoningTokens == 12)
    }

    @Test func onlyNormalizedInlineImagesCanReachTheProvider() throws {
        let bytes = Data([0, 1, 2]).base64EncodedString()
        let image = try AgentModelGatewayRequest.message(["role": "user", "content": [
            ["type": "text", "data": "Look"], ["type": "image", "base64_data": .string(bytes), "mime_type": "image/png"],
        ]])
        #expect(image.json["content"]?.array?.count == 2)
        #expect(throws: ServerError.self) {
            try AgentModelGatewayRequest.message(["role": "user", "content": [
                ["type": "image", "url": "http://127.0.0.1/private", "mime_type": "image/png"],
            ]])
        }
    }
}

@Suite("Agent model execution scope")
struct AgentModelScopeTests {
    static func scope(generation: Int = 1) -> AgentModelScope {
        AgentModelScope(operationID: "E:0:0", generation: generation,
            execution: ["tenant_id": "T", "app_id": "A", "workflow_run_id": "W", "node_id": "N",
                        "execution_id": "E", "agent_config_snapshot_id": "S", "user_id": "U", "user_from": "account", "invoke_from": "debugger"],
            provider: "fixture/provider/model", model: "fixture", maxCalls: 5, expiresAt: Date().addingTimeInterval(60))
    }
    static func request(_ scope: AgentModelScope, call: Int = 1, override: JSONObject = [:], parameters: JSONObject = [:]) throws -> AgentModelGatewayRequest {
        var caller = scope.caller.merging(override)
        caller["run_id"] = "agent-run"
        caller["call_index"] = .int(call)
        caller["invocation_id"] = .string("agent-run:\(call)")
        return try AgentModelGatewayRequest([
            "caller": .object(caller), "target": ["provider": .string(scope.provider), "model": .string(scope.model),
                "prompt_messages": [["role": "user", "content": "hello"]], "model_parameters": .object(parameters), "stream": true],
        ])
    }

    @Test func foreignIdentitiesAndRepeatedInvocationsNeverSpendAnotherModelCall() async throws {
        let registry = AgentModelScopes(), scope = Self.scope()
        let token = try await registry.activate(scope)
        let forgeries: [JSONObject] = [["tenant_id": "other"], ["app_id": "other"], ["node_execution_id": "other"],
                                      ["operation_id": "E:0:1"], ["agent_config_snapshot_id": "different"]]
        for forged in forgeries {
            await #expect(throws: ServerError.self) { try await registry.claim(token: token, request: Self.request(scope, override: forged)) }
        }
        let claim = try await registry.claim(token: token, request: Self.request(scope))
        await registry.finish(claim, usage: LLMUsage(json: ["total_tokens": 7]))
        await #expect(throws: ServerError.self) { try await registry.claim(token: token, request: Self.request(scope)) }
        let usage = await registry.revoke(token: token)
        #expect(usage.totalTokens == 7)
        await #expect(throws: ServerError.self) { try await registry.claim(token: token, request: Self.request(scope, call: 2)) }
    }

    @Test func reclaimRevokesThePreviousGenerationAndCancelsItsCalls() async throws {
        let registry = AgentModelScopes(), old = Self.scope()
        let token = try await registry.activate(old)
        let claim = try await registry.claim(token: token, request: Self.request(old))
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        await registry.attach(task, to: claim)
        let current = Self.scope(generation: 2)
        let newToken = try await registry.activate(current)
        #expect(task.isCancelled)
        await #expect(throws: ServerError.self) { try await registry.claim(token: token, request: Self.request(old)) }
        await #expect(throws: ServerError.self) { try await registry.activate(old) }
        _ = try await registry.claim(token: newToken, request: Self.request(current))
        _ = await registry.revoke(token: newToken)
    }

    @Test func pinnedParametersAndSingleActiveOperationCannotBeOverridden() async throws {
        let registry = AgentModelScopes()
        var scope = Self.scope()
        scope.modelParameters = ["temperature": 0]
        let token = try await registry.activate(scope)
        await #expect(throws: ServerError.self) { try await registry.activate(scope) }
        await #expect(throws: ServerError.self) {
            try await registry.claim(token: token, request: Self.request(scope, parameters: ["temperature": 1]))
        }
        let claim = try await registry.claim(token: token, request: Self.request(scope, parameters: ["temperature": 0]))
        await #expect(throws: ServerError.self) {
            try await registry.claim(token: token, request: Self.request(scope, call: 2, parameters: ["temperature": 0]))
        }
        await registry.finish(claim, usage: nil)
        _ = await registry.revoke(token: token)
    }

    @Test func incompleteOrExpiredScopeCannotBeActivated() async {
        let registry = AgentModelScopes()
        var expired = Self.scope()
        expired.expiresAt = .distantPast
        await #expect(throws: ServerError.self) { try await registry.activate(expired) }
    }
}
