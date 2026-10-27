import CollabRuntime
import Testing
@testable import CollabServer

@Suite("Agent configurable model-call limits") struct AgentTurnLimitTests {
    @Test func oldConfigurationsKeepFiftyAndImmutableConfigurationsCanRequestMore() throws {
        #expect(try AgentInlineConfig(AgentInlineConfig.empty).maxTurns == 50)
        var soul = AgentInlineConfig.empty
        soul["limits"] = ["max_turns": 200]
        let parsed = try AgentInlineConfig(soul)
        #expect(parsed.maxTurns == 200 && parsed.json["limits"]?["max_turns"] == 200)
        #expect(try AgentExecutionPolicy.turns(node: parsed.maxTurns, profile: 200) == 200)
        #expect(throws: NodeError.self) { try AgentExecutionPolicy.turns(node: parsed.maxTurns, profile: 50) }
        #expect(throws: NodeError.self) { try AgentExecutionPolicy.turns(node: parsed.maxTurns, profile: nil) }
    }
    @Test func malformedLimitsCannotBypassTheEnvironmentPolicy() throws {
        for limits in [["max_turns": 0], ["max_turns": -1], ["max_turns": 1001], ["max_turns": "200"],
                                 ["max_turns": 1.5], ["max_turns": true], ["max_turns": 200, "timeout_seconds": 999999], [], .null] as [JSONValue] {
            var soul = AgentInlineConfig.empty
            soul["limits"] = limits
            #expect(throws: NodeDataError.self) { try AgentInlineConfig(soul) }
        }
        #expect(try AgentExecutionPolicy.turns(node: 1, profile: 200) == 1)
        #expect(try AgentExecutionPolicy.turns(node: 1000, profile: 1000) == 1000)
        #expect(throws: NodeError.self) { try AgentExecutionPolicy.turns(node: 201, profile: 200) }
        #expect(throws: NodeError.self) { try AgentExecutionPolicy.turns(node: 1001, profile: 2000) }
    }
    @Test func profileCatalogAddsOnlyTheAllowedTurnCapAndOldCatalogsStayCompatible() throws {
        let old: JSONValue = ["name": "default", "description": "Default", "status": "ok", "timeout_seconds_max": 1800]
        #expect(try AgentExecutorProfile.parse(["profiles": [old]])[0].maxTurnsMax == 50)
        var entry = old.object!
        entry["max_turns_max"] = 200
        let profile = try AgentExecutorProfile.parse(["profiles": [.object(entry)]])[0]
        #expect(profile.maxTurnsMax == 200 && profile.json["max_turns_max"] == 200)
        for value in [0, -1, 1001, "200", true, 1.5, .null] as [JSONValue] {
            entry["max_turns_max"] = value
            #expect(throws: NodeError.self) { try AgentExecutorProfile.parse(["profiles": [.object(entry)]]) }
        }
    }
}

@Suite("Long agent model histories") struct AgentLongHistoryTests {
    @Test func configuredTwoHundredCallsDoNotStopAtTheOldFiftyCallCap() async throws {
        let registry = AgentModelScopes()
        var scope = AgentModelScopeTests.scope()
        scope.maxCalls = 200
        let token = try await registry.activate(scope)
        for call in 1...200 {
            let claim = try await registry.claim(token: token, request: AgentModelScopeTests.request(scope, call: call))
            await registry.finish(claim, usage: LLMUsage(json: ["total_tokens": 1]))
        }
        await #expect(throws: ServerError.self) {
            try await registry.claim(token: token, request: AgentModelScopeTests.request(scope, call: 201))
        }
        #expect(await registry.revoke(token: token).totalTokens == 200)
    }
    @Test func appendOnlyHistoriesCanExceedFiveHundredMessagesButRemainBounded() throws {
        let scope = AgentModelScopeTests.scope()
        let original = try AgentModelScopeTests.request(scope)
        var target: JSONObject = ["provider": .string(scope.provider), "model": .string(scope.model), "stream": true,
            "prompt_messages": .array((0..<900).map { ["role": "user", "content": .string("fixture \($0)")] })]
        let accepted = try AgentModelGatewayRequest(["caller": .object(original.caller), "target": .object(target)])
        #expect(accepted.messages.count == 900)
        target["prompt_messages"] = .array(Array(repeating: ["role": "user", "content": "fixture"], count: AgentModelGatewayLimits.messages + 1))
        #expect(throws: ServerError.self) {
            try AgentModelGatewayRequest(["caller": .object(original.caller), "target": .object(target)])
        }
    }
    @Test func partialCompletionOnlyRetainsRecognizedReasonsAndCallNumbers() {
        #expect(ServerAgentRuntime.partialResult(["reason": "max_turns", "notice_call_index": 198, "secret": "never-publish"]) ==
            ["reason": "max_turns", "notice_call_index": 198])
        for malformed in [["reason": "anything", "notice_call_index": 1], ["reason": "timeout", "notice_call_index": 0],
                          ["reason": "timeout", "notice_call_index": "3"], .null] as [JSONValue] {
            #expect(ServerAgentRuntime.partialResult(malformed) == nil)
        }
    }
}
