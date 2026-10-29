// Standard Responses ingress for an official Codex process. Its bearer is a
// short-lived execution capability, never a provider or service credential.
import CollabRuntime
import Foundation
import HTTPTypes
import Vapor

struct AgentCodexCallLimit: Error {}

/// Native Codex resends inline image history. Raw files expand by 4/3 in
/// base64, so the aggregate file budget fits within the total JSON budget.
enum AgentCodexGatewayLimits {
    static let requestBytes = 128 << 20
    static let fileBytes = 96 << 20
}

extension AgentResponsesRequest {
    init(codexBody value: JSONValue, scope: AgentModelScope) throws {
        guard scope.harnessStyle == "codex", scope.modelWire == "responses",
              var fields = value.object, fields["model"] == .string(scope.model),
              fields["stream"] == true, fields["store"] == false,
              let input = fields["input"]?.array, !input.isEmpty,
              input.count <= AgentModelGatewayLimits.messages else { throw AgentModelGatewayRequest.invalid() }
        let allowed: Set<String> = ["model", "input", "instructions", "tools", "tool_choice", "parallel_tool_calls",
            "reasoning", "store", "stream", "include", "prompt_cache_key", "text", "max_output_tokens",
            "temperature", "top_p", "stream_options", "service_tier", "client_metadata"]
        guard Set(fields.keys).isSubset(of: allowed),
              fields["instructions"] == nil || fields["instructions"]?.string != nil,
              fields["prompt_cache_key"] == nil || (fields["prompt_cache_key"]?.string.map { $0.utf8.count <= 512 } ?? false),
              fields["include"]?.array.map({ $0.count <= 16 && $0.allSatisfy { ($0.string?.utf8.count ?? 1000) <= 128 } }) ?? (fields["include"] == nil)
        else { throw AgentModelGatewayRequest.invalid() }
        var tools = 0
        func checkTools(_ raw: JSONValue, depth: Int) throws {
            guard depth <= 8, let array = raw.array else { throw AgentModelGatewayRequest.invalid() }
            for tool in array {
                tools += 1
                guard tools <= 256, let kind = tool["type"]?.string,
                      ["function", "custom", "namespace"].contains(kind) else { throw AgentModelGatewayRequest.invalid() }
                if kind == "namespace" { try checkTools(tool["tools"] ?? .null, depth: depth + 1) }
            }
        }
        if let raw = fields["tools"], raw != .null { try checkTools(raw, depth: 0) }
        let parameters = scope.modelParameters ?? [:]
        var reasoning = fields["reasoning"]?.object ?? [:]
        guard fields["reasoning"] == nil || fields["reasoning"] == .null || fields["reasoning"]?.object != nil else {
            throw AgentModelGatewayRequest.invalid()
        }
        if let effort = parameters["reasoning_effort"] {
            guard effort.string != nil, reasoning["effort"] == nil || reasoning["effort"] == effort else {
                throw AgentModelGatewayRequest.invalid()
            }
            reasoning["effort"] = effort
            fields["reasoning"] = .object(reasoning)
        }
        // Codex does not expose every provider output-budget setting. Apply the
        // workflow's cap here rather than silently dropping its cost boundary.
        let caps = ["max_tokens", "max_completion_tokens", "max_output_tokens"].compactMap { parameters[$0]?.int }
            + [scope.outputTokenLimit].compactMap { $0 }
        guard caps.allSatisfy({ $0 > 0 }) else { throw AgentModelGatewayRequest.invalid() }
        if let requested = fields["max_output_tokens"] {
            guard let count = requested.int, count > 0, caps.min().map({ count <= $0 }) ?? true else {
                throw AgentModelGatewayRequest.invalid()
            }
        } else if let cap = caps.min() { fields["max_output_tokens"] = .int(cap) }
        for name in ["temperature", "top_p", "service_tier"] {
            if let pinned = parameters[name] {
                guard fields[name] == nil || fields[name] == pinned else { throw AgentModelGatewayRequest.invalid() }
                fields[name] = pinned
            } else if fields[name] != nil { throw AgentModelGatewayRequest.invalid() }
        }
        callIndex = 0 // The actor allocates an index after validation, never the caller.
        invocationID = ""
        attempt = 1
        body = fields
    }
}

extension Routes {
    func authenticateAgentCodex(_ req: Request) throws -> String {
        guard config.agentService.isConfigured else {
            throw ServerError.http(status: 503, code: "agent_not_configured", message: "The agent service is not configured")
        }
        let raw = req.headers[.authorization] ?? ""
        guard raw.hasPrefix("Bearer ") else { throw ServerError.unauthorized("An agent run token is required") }
        let token = String(raw.dropFirst(7))
        guard (16...512).contains(token.utf8.count), token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw ServerError.unauthorized("Invalid agent run authentication")
        }
        return token
    }

    func recordCodexModelCall(scope: AgentModelScope, claim: AgentModelScopes.Claim, phase: String,
                             body: JSONObject, model: String, usage: LLMUsage?, status: Int?) async throws {
        guard let session = try await store.agentSession(execution: scope.executionID) else {
            if scope.durableOwner != nil { throw AgentModelGatewayRequest.invalid() }
            return // Standalone gateway fixtures have no durable Agent session.
        }
        var data: JSONObject = ["phase": .string(phase), "call_index": .int(claim.index),
            "provider": .string(scope.provider), "model": .string(model), "wire": "responses", "harness_style": "codex",
            "reasoning_effort": body["reasoning"]?["effort"] ?? .null,
            "include": body["include"] ?? .array([]), "max_output_tokens": body["max_output_tokens"] ?? .null]
        if let usage { data["usage"] = usage.json }
        if let status { data["http_status"] = .int(status) }
        try await recordAgentEvent(session: session, run: "codex-gateway:" + scope.operationID,
            event: claim.index * 2 + (phase == "started" ? 0 : 1), name: "model_call", data: data, secrets: [])
    }
}
