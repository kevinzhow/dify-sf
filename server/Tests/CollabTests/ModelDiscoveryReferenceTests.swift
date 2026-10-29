import CollabModels
import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite("Official-origin model references")
struct ModelDiscoveryReferenceTests {
    @Test func sparseOfficialListUsesSourcedFactsAndResponsesWithoutModelCalls() async throws {
        let connection = try ModelDiscovery.Connection(["endpoint_url": "https://api.openai.com/v1", "api_key": "fixture-only"])
        let result = try await ModelDiscovery.discover(connection) { request in
            #expect(request.method == "GET" && request.body == nil)
            return .init(status: 200, headers: [], body: Array(#"{"data":[{"id":"gpt-6.1-terra","object":"model","owned_by":"openai","created":1}]}"#.utf8))
        }
        let model = try #require(result["models"]?.array?.first)
        #expect(model["fields"]?["api_type"]?["value"] == "responses")
        #expect(model["fields"]?["tools"]?["value"] == true)
        #expect(model["fields"]?["tools"]?["source"] == "reference")
        #expect(model["fields"]?["context_capacity"]?["value"] == 1_050_000)
        #expect(model["fields"]?["output_capacity"]?["value"] == 128_000)
        #expect(model["fields"]?["output_limit"]?["source"] == "unknown")
        #expect(model["reference"] == "https://developers.openai.com/api/docs/models/gpt-6.1-terra")
        #expect(ModelDiscoveryReference.probeEffort(model) == "none")
        let defaults = ModelDiscovery.defaults(model)
        #expect(defaults["agent_thought_support"] == "only_thinking_supported")
        #expect(defaults["function_calling_type"] == "tool_call")
        var manual = defaults; manual["context_size"] = "8192"
        let metadata = ModelAutofillMetadata.make(model: model, defaults: defaults, actual: manual, listed: true, probe: nil)
        #expect(metadata["settings"]?["context_size"]?["source"] == "manual")
        #expect(metadata["settings"]?["agent_thought_support"]?["source"] == "reference")
        var credentials = defaults
        credentials["endpoint_url"] = "https://api.openai.com/v1"
        credentials[ModelDiscovery.metadataKey] = metadata
        let rules = ModelReasoning.rules([["name": "reasoning_effort", "options": ["low", "high"]]], provider: ModelDiscovery.provider, credentials: credentials)
        #expect(rules.first?["options_source"] == "reference")
        #expect(rules.first?["allow_custom_value"] == true)
        #expect(rules.first?["options"]?.array?.contains("max") == true)
        #expect(ModelReasoning.declared(credentials) == nil)
        credentials["endpoint_url"] = "https://gateway.example/v1"
        #expect(ModelReasoning.referenced(credentials) == nil)
        let chat = ModelDiscoveryReference.applicable(model, apiType: "chat_completions")
        #expect(chat["fields"]?["tools"]?["value"] == .null)
        #expect(ModelDiscovery.defaults(chat)["function_calling_type"] == "no_call")
    }

    @Test func aliasesSpoofedOriginsAndUnlistedModelsDoNotInheritOfficialFacts() throws {
        for base in ["https://gateway.example/v1", "http://api.openai.com/v1", "https://api.openai.com.evil.test/v1",
                     "https://api.openai.com:8443/v1", "https://api.openai.com/proxy/v1"] {
            let connection = try ModelDiscovery.Connection(["endpoint_url": .string(base)])
            let value = ModelDiscoveryReference.enrich(ModelDiscovery.normalize([:], id: "gpt-6.1-terra"), connection: connection, catalog: nil)
            #expect(value["fields"]?["tools"]?["source"] == "unknown")
            #expect(value["fields"]?["context_capacity"]?["value"] == .null)
        }
        let official = try ModelDiscovery.Connection(["endpoint_url": "https://api.openai.com/v1"])
        for id in ["codex/gpt-6.1-terra", "gpt-6.1-terra-custom", "unknown-model"] {
            #expect(ModelDiscoveryReference.model(id, connection: official, catalog: nil) == nil)
        }
    }

    @Test func reusesExistingProviderCatalogAndNeverTurnsMissingFeaturesIntoFalse() throws {
        let catalog = try ModelCatalog.bundled()
        let official = try ModelDiscovery.Connection(["endpoint_url": "https://api.openai.com/v1"])
        let reference = try #require(ModelDiscoveryReference.model("gpt-6-sol", connection: official, catalog: catalog))
        #expect(reference["fields"]?["context_capacity"]?["value"] == 1_050_000)
        #expect(reference["fields"]?["context_capacity"]?["source"] == "catalog")
        #expect(reference["checked_at"] == "2026-10-13")
        #expect(reference["fields"]?["vision"]?["value"] == true)
    }

    @Test func probeExplainsRejectionAndTruncationWithoutReflectingProviderSecrets() async throws {
        let connection = try ModelDiscovery.Connection(["endpoint_url": "https://gateway.example/v1", "api_key": "fixture-credential-never-reflect"])
        let result = try await ModelCapabilityProbe.run(connection, model: "custom", protocolName: "responses") { request in
            let body = try JSONCoding.decode(Data(request.body ?? []))
            if body["text"] != nil {
                return .init(status: 400, headers: [], body: Array(#"{"error":{"code":"unsupported_parameter","message":"fixture-credential-never-reflect","param":"secret-account-id"}}"#.utf8))
            }
            return .init(status: 200, headers: [], body: Array(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8))
        }
        #expect(result["diagnostics"]?["json_schema"]?["http_status"] == 400)
        #expect(result["diagnostics"]?["json_schema"]?["code"] == "unsupported_parameter")
        #expect(result["diagnostics"]?["tools"]?["reason"] == "output_budget_exhausted")
        #expect(result["fields"]?["tools"]?["source"] == "unknown")
        let json = String(decoding: try JSONCoding.encode(result), as: UTF8.self)
        #expect(!json.contains("fixture-credential-never-reflect") && !json.contains("secret-account-id"))
    }

    @Test func aSourcedLowEffortAndBudgetGiveReasoningModelsRoomWithoutUnboundedRetries() async throws {
        let connection = try ModelDiscovery.Connection(["endpoint_url": "https://api.openai.com/v1"])
        let result = try await ModelCapabilityProbe.run(connection, model: "gpt-6.1-terra", protocolName: "responses", reasoningEffort: "none") { request in
            let body = try JSONCoding.decode(Data(request.body ?? []))
            #expect(body["reasoning"]?["effort"] == "none")
            #expect(body["max_output_tokens"] == 1024 || body["max_output_tokens"] == 16)
            return .init(status: 400, headers: [], body: Array(#"{"error":{"code":"fixture-credential-never-reflect"}}"#.utf8))
        }
        #expect((result["request_count"]?.int ?? 99) <= 7)
        #expect(result["diagnostics"]?["tools"]?["code"] == nil)
    }
}
