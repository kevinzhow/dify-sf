import CollabModels
import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite("Extensible model reasoning levels") struct ModelReasoningTests {
    func credentials(_ field: JSON) -> [String: JSON] {
        ["api_key": "fixture-only", "mode": "chat", "agent_thought_support": "only_thinking_supported",
         ModelDiscovery.metadataKey: ["model": ["fields": ["reasoning_levels": field]]]]
    }
    func schema() -> ModelSchema {
        .init(model: "arbitrary-service-alias", label: [:], modelType: "llm", features: nil, fetchFrom: "customizable-model",
              modelProperties: [:], deprecated: false, parameterRules: [
                ["name": "reasoning_effort", "type": "string", "options": ["low", "high", "xhigh"]],
                ["name": "temperature", "type": "float", "min": 0, "max": 2]])
    }
    @Test func absentDeclarationKeepsSuggestionsAndAllowsCustomWithoutModelNameRules() {
        var value = schema(), other = schema()
        ModelReasoning.apply(&value, provider: ModelDiscovery.provider, credentials: [:])
        #expect(value.parameterRules[0]["options"] == ["low", "high", "xhigh"])
        #expect(value.parameterRules[0]["allow_custom_value"] == true)
        #expect(value.parameterRules[0]["options_source"] == "plugin")
        #expect(value.parameterRules[1] == schema().parameterRules[1])
        ModelReasoning.apply(&other, provider: "langgenius/openai/openai", credentials: [:])
        #expect(other == schema())
    }
    @Test func providerDeclarationControlsMenuAndRuntimeWithoutLeakingReceipt() {
        let c = credentials(["source": "provider", "value": ["vendor-next-level", "max", "max"]])
        var value = schema()
        ModelReasoning.apply(&value, provider: ModelDiscovery.provider, credentials: c)
        #expect(value.parameterRules[0]["options"] == ["vendor-next-level", "max"])
        #expect(value.parameterRules[0]["allow_custom_value"] == false)
        #expect(value.parameterRules[0]["options_source"] == "provider")
        let actual = ModelReasoning.runtimeCredentials(c, provider: ModelDiscovery.provider)
        #expect(actual[ModelReasoning.levelsKey] == ["vendor-next-level", "max"])
        #expect(actual[ModelDiscovery.metadataKey] == nil && actual["api_key"] == "fixture-only")
        #expect(ModelReasoning.runtimeCredentials(c, provider: "langgenius/openai/openai")[ModelReasoning.levelsKey] == nil)
    }
    @Test func unknownEmptyMalformedOrStaleDeclarationsDoNotBecomeAuthoritative() {
        let fields: [JSON] = [["source": "unknown", "value": ["max"]], ["source": "provider", "value": []],
                            ["source": "provider", "value": [""]], ["source": "provider", "value": ["a\nb"]],
                            ["source": "manual", "value": ["max"]]]
        for field in fields {
            var c = credentials(field)
            c[ModelReasoning.levelsKey] = ["forged"]
            #expect(ModelReasoning.runtimeCredentials(c, provider: ModelDiscovery.provider)[ModelReasoning.levelsKey] == nil)
        }
        let c = credentials(["source": "provider", "value": ["max"]])
        let metadata = ModelAutofillMetadata.edited(c[ModelDiscovery.metadataKey]!, old: ["api_type": "responses"], new: ["api_type": "chat_completions"])
        #expect(ModelReasoning.declared([ModelDiscovery.metadataKey: metadata]) == nil)
    }
    @Test func discoveredReasoningEnablesTheExistingPluginControl() {
        let model = ModelDiscovery.normalize(["reasoning_levels": ["vendor-next-level"]], id: "arbitrary-service-alias")
        #expect(ModelDiscovery.defaults(model)["agent_thought_support"] == "only_thinking_supported")
    }
    @Test func runtimeMatchesSettingsForCompatiblePluginSuggestionsAndProviderEnums() throws {
        let plugin: JSONValue = ["name": "reasoning_effort", "options": ["low", "high", "xhigh"]]
        #expect(ModelReasoning.runtimeOptions(provider: ModelDiscovery.provider, credentials: [:], rule: plugin) == nil)
        let saved = credentials(["source": "provider", "value": ["high", "max", "vendor-next-level"]])
        let projected = ModelReasoning.runtimeCredentials(saved, provider: ModelDiscovery.provider)
        let runtime = try #require(try JSONValue.parse(JSONCoding.encode(.object(projected))).object)
        let values = ModelReasoning.runtimeOptions(provider: ModelDiscovery.provider, credentials: runtime, rule: plugin)
        #expect(values == ["high", "max", "vendor-next-level"])
        #expect(values?.contains("ultra") == false)
        #expect(runtime[ModelDiscovery.metadataKey] == nil)
        #expect(ModelReasoning.runtimeOptions(provider: "langgenius/openai/openai", credentials: runtime, rule: plugin) == ["low", "high", "xhigh"])
        #expect(ModelReasoning.runtimeOptions(provider: "other/provider", credentials: [:],
            rule: ["options": ["high"], "allow_custom_value": true]) == nil)
    }

}
