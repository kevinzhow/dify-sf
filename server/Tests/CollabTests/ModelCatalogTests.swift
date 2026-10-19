import CollabModels
import CollabStore
import Foundation
import Testing
@testable import CollabServer

private func catalog() throws -> ModelCatalog { try ModelService.bundledCatalog.get() }

/// Model providers without a database (protocol 1.9): the vendored definitions, parameter templates, custom-model schemas,
/// credential form rules, credential checks and the secrets key.
@Suite("Model provider catalog")
struct ModelCatalogTests {
    @Test func theVendoredDefinitionsLoad() throws {
        let c = try catalog()
        #expect(c.providers.map(\.id.description) == [
            "langgenius/openai/openai", "langgenius/anthropic/anthropic", "langgenius/gemini/google", "langgenius/azure_openai/azure_openai",
            "langgenius/tongyi/tongyi", "langgenius/zhipuai/zhipuai", "langgenius/moonshot/moonshot", "langgenius/deepseek/deepseek",
            "langgenius/ollama/ollama", "langgenius/openai_api_compatible/openai_api_compatible",
        ])
        // Bare names and Dify's google -> gemini rule.
        #expect(c.provider("openai")?.id.description == "langgenius/openai/openai")
        #expect(c.provider("google")?.id.description == "langgenius/gemini/google")
        #expect(c.provider("langgenius/google/google")?.id.description == "langgenius/gemini/google")
        #expect(c.provider("nobody") == nil && c.provider("a/b") == nil && c.provider("../x/y") == nil)

        let openai = try #require(c.provider("openai"))
        #expect(openai.label == ["en_US": "OpenAI", "zh_Hans": "OpenAI"])  // zh_Hans defaults to en_US (graphon's I18nObject)
        #expect(openai.supportedModelTypes.contains("llm") && openai.supportsPredefinedModels && openai.supportsCustomModels)
        #expect(openai.models.filter { $0.modelType == "llm" }.count > 20)
        #expect(openai.positions["llm"]?.isEmpty == false)
        #expect(openai.secretVariables(forModel: false) == ["openai_api_key"])
        #expect(openai.icon(type: "icon_small", lang: "en_US")?.contentType == "image/svg+xml")
        #expect(openai.icon(type: "icon_small", lang: "zh_Hans") != nil)  // falls back to the en_US file
        #expect(openai.icon(type: "icon_small_dark", lang: "en_US") != nil)
        #expect(openai.icon(type: "icon_large", lang: "en_US") == nil)
        // graphon's CredentialFormSchema fields only (no `help`), the daemon's defaults.
        let field = try #require(openai.providerFormSchemas.first)
        #expect(Set(field.object!.keys) == ["variable", "label", "type", "required", "default", "options", "placeholder", "max_length", "show_on"])
        #expect(field["variable"] == "openai_api_key" && field["type"] == "secret-input" && field["required"] == true)

        let ollama = try #require(c.provider("ollama"))
        #expect(ollama.configurateMethods == ["customizable-model"] && ollama.models.isEmpty && ollama.providerCredentialSchema == nil)
        #expect(ollama.modelCredentialSchema?["model"]?["label"]?["en_US"]?.string?.isEmpty == false)
        // An option without a label of its own still has one; show_on survives.
        let mode = try #require(ollama.modelFormSchemas.first { $0["variable"] == "mode" })
        #expect(mode["show_on"] == [["variable": "__model_type", "value": "llm"]])
        // Every provider has an icon and models of the types it declares.
        for p in c.providers {
            #expect(p.icon(type: "icon_small", lang: "en_US") != nil, "\(p.id)")
            #expect(p.models.allSatisfy { p.supportedModelTypes.contains($0.modelType) }, "\(p.id)")
        }
    }

    @Test func modelLabelsFallBackToTheModelName() throws {
        let c = try catalog()
        let all = c.providers.flatMap(\.models)
        #expect(all.allSatisfy { $0.label["en_US"]?.string?.isEmpty == false && $0.label["zh_Hans"]?.string?.isEmpty == false })
        #expect(all.allSatisfy { $0.fetchFrom == "predefined-model" })
    }

    /// The label question of the design: Dify 1.17.1's parameter-rules endpoint is answered by the plugin process, whose
    /// SDK lays the YAML over the template (`validate_label`): a template-only rule shows the template's label.
    @Test func templatesResolveLikeThePluginSDK() {
        let t = ParameterRules.predefined(["name": "temperature", "use_template": "temperature"])
        #expect(t["label"] == ["en_US": "Temperature", "zh_Hans": "温度"])
        #expect(t["type"] == "float" && t["min"]?.double == 0 && t["max"]?.double == 1 && t["default"]?.double == 0 && t["precision"] == 2)
        #expect(t["help"]?["en_US"]?.string?.hasPrefix("Controls randomness") == true)
        #expect(t["required"] == false && t["options"] == [] && t["use_template"] == "temperature")

        // Rule keys win, whole values: an own label replaces the template's, own bounds replace the template's.
        let m = ParameterRules.predefined(["name": "max_tokens", "use_template": "max_tokens", "required": true, "default": 64000, "min": 1, "max": 64000])
        #expect(m["label"] == ["en_US": "Max Tokens", "zh_Hans": "最大标记"])
        #expect(m["required"] == true && m["default"] == 64000 && m["max"]?.double == 64000 && m["precision"] == 0)
        let own = ParameterRules.predefined(["name": "top_k", "use_template": "top_k", "label": ["en_US": "Top k", "zh_Hans": "取样数量"]])
        #expect(own["label"] == ["en_US": "Top k", "zh_Hans": "取样数量"] && own["max"]?.double == 100)
        // json_schema is a text parameter in the SDK's table (the daemon's says string).
        #expect(ParameterRules.predefined(["name": "json_schema", "use_template": "json_schema"])["type"] == "text")
        #expect(ParameterRules.predefined(["name": "json_schema", "use_template": "json_schema"])["label"] == ["en_US": "JSON Schema", "zh_Hans": "JSON Schema"])
        // response_format brings its options.
        #expect(ParameterRules.predefined(["name": "response_format", "use_template": "response_format"])["options"] == ["JSON", "XML"])
        // No template, no label: the name.
        let bare = ParameterRules.predefined(["name": "seed", "type": "int"])
        #expect(bare["label"] == ["en_US": "seed", "zh_Hans": "seed"] && bare["help"] == .null && bare["min"] == .null && bare["use_template"] == .null)
    }

    @Test func anthropicRulesComeOutResolved() throws {
        let anthropic = try #require(try catalog().provider("anthropic"))
        let model = try #require(anthropic.models.first { $0.modelType == "llm" && $0.rawParameterRules.contains { $0["use_template"] == "temperature" } })
        let temperature = try #require(model.parameterRules.first { $0["name"] == "temperature" })
        #expect(temperature["label"]?["en_US"] == "Temperature" && temperature["type"] == "float")
        #expect(model.parameterRules.allSatisfy { $0["label"]?["en_US"]?.string?.isEmpty == false && $0["type"] != .null })
    }

    @Test func customizableTemplateHydrationIsTheSDKs() {
        // Falsy bounds and defaults take the template's; help comes from the template when absent.
        let r = ParameterRules.hydrateCustomizable(["name": "temperature", "use_template": "temperature", "min": 0, "max": 2, "default": .double(0)])
        #expect(r["max"] == 2 && r["min"]?.double == 0 && r["precision"] == 2 && r["help"]?["en_US"]?.string?.hasPrefix("Controls") == true)
        let unchanged = ParameterRules.hydrateCustomizable(["name": "x", "type": "int"])
        #expect(unchanged == ["name": "x", "type": "int"])
    }

    @Test func ollamaCustomModels() throws {
        let ollama = try #require(try catalog().provider("ollama"))
        #expect(CustomModels.schema(provider: ollama, model: "llama3", modelType: "llm", credentials: nil) == nil)
        #expect(CustomModels.schema(provider: ollama, model: "llama3", modelType: "llm", credentials: [:]) == nil)
        let s = try #require(CustomModels.schema(provider: ollama, model: "llama3", modelType: "llm", credentials: [
            "base_url": "http://127.0.0.1:11434", "mode": "chat", "context_size": "8192", "max_tokens": "4096",
            "vision_support": "true", "function_call_support": "true",
        ]))
        #expect(s.label == ["en_US": "llama3", "zh_Hans": "llama3"] && s.fetchFrom == "customizable-model" && s.modelType == "llm")
        #expect(s.features == ["vision", "tool-call", "multi-tool-call", "stream-tool-call"])
        #expect(s.modelProperties == ["mode": "chat", "context_size": 8192])
        #expect(s.parameterRules.count == 19)
        let predict = try #require(s.parameterRules.first { $0["name"] == "num_predict" })
        #expect(predict["use_template"] == "max_tokens" && predict["default"] == 512 && predict["max"]?.double == 4096 && predict["min"]?.double == -2)
        let topP = try #require(s.parameterRules.first { $0["name"] == "top_p" })
        #expect(topP["default"]?.double == 0.9 && topP["precision"] == 2 && topP["help"]?["en_US"]?.string?.hasPrefix("Works together") == true)
        // A small max_tokens: num_predict defaults to 128.
        let small = try #require(CustomModels.schema(provider: ollama, model: "m", modelType: "llm", credentials: ["mode": "chat", "max_tokens": "512"]))
        #expect(small.parameterRules.first { $0["name"] == "num_predict" }?["default"] == 128)
        // Python's int() of a non-number fails: no schema (Dify skips the model).
        #expect(CustomModels.schema(provider: ollama, model: "m", modelType: "llm", credentials: ["context_size": "lots"]) == nil)
        let embedding = try #require(CustomModels.schema(provider: ollama, model: "nomic", modelType: "text-embedding", credentials: ["base_url": "x"]))
        #expect(embedding.modelProperties == ["context_size": 512, "max_chunks": 1] && embedding.parameterRules.isEmpty)
    }

    @Test func openAICompatibleCustomModels() throws {
        let oaic = try #require(try catalog().provider("openai_api_compatible"))
        // No (or an unknown) completion mode: the SDK raises, no schema.
        #expect(CustomModels.schema(provider: oaic, model: "m", modelType: "llm", credentials: ["endpoint_url": "http://x"]) == nil)
        let s = try #require(CustomModels.schema(provider: oaic, model: "qwen3", modelType: "llm", credentials: [
            "endpoint_url": "http://x/v1", "mode": "chat", "context_size": "32768", "max_tokens_to_sample": "8192",
            "function_calling_type": "tool_call", "vision_support": "support", "structured_output_support": "supported",
            "agent_thought_support": "supported", "display_name": "Qwen 3",
        ]))
        #expect(s.label == ["en_US": "Qwen 3", "zh_Hans": "Qwen 3"])
        #expect(s.features == ["multi-tool-call", "stream-tool-call", "vision", "agent-thought"])
        #expect(s.modelProperties == ["mode": "chat", "context_size": 32768])
        #expect(s.parameterRules.map { $0["name"]?.string ?? "" } == [
            "temperature", "top_p", "frequency_penalty", "presence_penalty", "max_tokens", "response_format", "json_schema",
            "enable_thinking", "reasoning_format", "reasoning_effort",
        ])
        let temperature = s.parameterRules[0]
        #expect(temperature["default"]?.double == 0.7 && temperature["max"]?.double == 2 && temperature["use_template"] == .null)
        #expect(s.parameterRules[4]["max"]?.double == 8192 && s.parameterRules[4]["default"] == 512)
        #expect(s.parameterRules[6]["type"] == "text" && s.parameterRules[6]["label"]?["en_US"] == "JSON Schema")
        let tts = try #require(CustomModels.schema(provider: oaic, model: "tts-1", modelType: "tts", credentials: ["voices": "nova, echo"]))
        #expect(tts.modelProperties["default_voice"] == "nova" && tts.modelProperties["voices"]?.array?.count == 2)
    }

    @Test func otherProvidersGetTheGenericSchema() throws {
        let openai = try #require(try catalog().provider("openai"))
        let s = try #require(CustomModels.schema(provider: openai, model: "ft:gpt-4o:me", modelType: "llm",
                                                 credentials: ["openai_api_key": "sk-x", "max_tokens": "1000"]))
        #expect(s.parameterRules.map { $0["name"] } == ["temperature", "top_p", "max_tokens"])
        #expect(s.parameterRules[2]["max"]?.double == 1000 && s.modelProperties["mode"] == "chat" && s.modelProperties["context_size"] == 4096)
    }

    @Test func credentialFormRulesAreDifys() throws {
        let ollama = try #require(try catalog().provider("ollama"))
        let schemas = ollama.modelFormSchemas
        #expect(throws: Credentials.SchemaError.self) { try Credentials.validateAndFilter(schemas, [:], modelType: "llm") }  // base_url required
        // Required fields must be non-empty even when they have a default (Dify's CommonValidator); optional empty fields
        // take their default; show_on keeps llm-only fields out of an embedding model; unknown keys are dropped.
        #expect(throws: Credentials.SchemaError.self) {
            try Credentials.validateAndFilter(schemas, ["base_url": "http://h:11434", "mode": "chat", "max_tokens": "4096"], modelType: "llm")
        }
        let llm = try Credentials.validateAndFilter(schemas, ["base_url": "http://h:11434", "mode": "chat", "context_size": "8192", "max_tokens": "4096",
                                                              "extra": "x", "api_key": ""], modelType: "llm")
        #expect(llm["base_url"] == "http://h:11434" && llm["mode"] == "chat" && llm["context_size"] == "8192" && llm["vision_support"] == "false")
        #expect(llm["extra"] == nil && llm["api_key"] == nil && llm["__model_type"] == nil)
        let embedding = try Credentials.validateAndFilter(schemas, ["base_url": "http://h:11434", "context_size": "512"], modelType: "text-embedding")
        #expect(embedding["mode"] == nil && embedding["max_tokens"] == nil && embedding["vision_support"] == nil && embedding["context_size"] == "512")
        // Options and types.
        #expect(throws: Credentials.SchemaError.self) {
            try Credentials.validateAndFilter(schemas, ["base_url": "http://h", "mode": "poetry", "context_size": "1", "max_tokens": "1"], modelType: "llm")
        }
        #expect(throws: Credentials.SchemaError.self) { try Credentials.validateAndFilter(schemas, ["base_url": 5], modelType: "llm") }
        let switchField: JSON = ["variable": "on", "type": "switch", "required": false, "options": [], "show_on": []]
        #expect(try Credentials.validateAndFilter([switchField], ["on": "TRUE"]) == ["on": true])
    }

    @Test func secretsAreMaskedAndRestoredLikeDify() {
        // Dify's obfuscated_token.
        #expect(Credentials.mask("sk-1234567890abcdef") == "sk-123************ef")
        #expect(Credentials.mask("12345678") == String(repeating: "*", count: 20))
        #expect(Credentials.mask("123456789") == "123456************89")
        #expect(Credentials.mask("") == "")
        #expect(Credentials.masked(["k": "sk-1234567890abcdef", "base": "http://x"], secrets: ["k"]) == ["k": "sk-123************ef", "base": "http://x"])
        let restored = Credentials.restoringHidden(["k": "[__HIDDEN__]", "base": "http://y"], stored: ["k": "sk-real", "base": "http://x"], secrets: ["k"])
        #expect(restored == ["k": "sk-real", "base": "http://y"])
        // Only secret fields are restored.
        #expect(Credentials.restoringHidden(["base": "[__HIDDEN__]"], stored: ["base": "http://x"], secrets: ["k"]) == ["base": "[__HIDDEN__]"])
    }

    @Test func credentialChecksAreOneCheapRequestPerDialect() throws {
        let c = try catalog()
        func plan(_ p: String, _ creds: [String: JSON], model: String? = nil, type: String? = nil) -> Validation.Plan? {
            Validation.plan(provider: c.provider(p)!, model: model, modelType: type, credentials: creds)
        }
        let openai = try #require(plan("openai", ["openai_api_key": "sk-abc", "openai_organization": "org-1"]))
        #expect(openai.request.method == "GET" && openai.request.url == "https://api.openai.com/v1/models")
        #expect(openai.request.headers == ["Authorization": "Bearer sk-abc", "OpenAI-Organization": "org-1"] && openai.secrets == ["sk-abc"])
        #expect(plan("openai", ["openai_api_key": "k", "openai_api_base": "http://h:1/v1/"])?.request.url == "http://h:1/v1/models")
        #expect(plan("openai", ["openai_api_key": "k", "openai_api_base": "http://h:1"])?.request.url == "http://h:1/v1/models")
        let anthropic = try #require(plan("anthropic", ["anthropic_api_key": "sk-ant"]))
        #expect(anthropic.request.url == "https://api.anthropic.com/v1/models?limit=1")
        #expect(anthropic.request.headers == ["x-api-key": "sk-ant", "anthropic-version": "2023-06-01"])
        let gemini = try #require(plan("google", ["google_api_key": "AIza-secret"]))
        #expect(!gemini.request.url.contains("AIza") && gemini.request.headers["x-goog-api-key"] == "AIza-secret")
        #expect(plan("tongyi", ["dashscope_api_key": "k", "use_international_endpoint": "true"])?.request.url
            == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models")
        let ollama = try #require(plan("ollama", ["base_url": "http://h:11434/"], model: "llama3", type: "llm"))
        #expect(ollama.request.method == "POST" && ollama.request.url == "http://h:11434/api/show")
        #expect(try JSONCoding.decode(ollama.request.body!) == ["model": "llama3"])
        let oaic = try #require(plan("openai_api_compatible", ["endpoint_url": "http://h/v1", "api_key": "k", "mode": "chat"], model: "m", type: "llm"))
        #expect(oaic.request.url == "http://h/v1/models" && oaic.fallback?.url == "http://h/v1/chat/completions" && oaic.fallbackOn == [404, 405])
        #expect(plan("azure_openai", ["openai_api_base": "https://x.openai.azure.com", "openai_api_key": "k", "openai_api_version": "2024-10-01-preview"],
                     model: "d", type: "llm")?.request.url == "https://x.openai.azure.com/openai/models?api-version=2024-10-01-preview")
        #expect(plan("azure_openai", ["auth_method": "entra_id_service_principal", "openai_api_base": "https://x"], model: "d", type: "llm") == nil)
        // Error messages: the provider's own, without secrets.
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-abcdef."}}"#.utf8)
        #expect(Validation.failureMessage(status: 401, body: body, secrets: ["sk-abcdef"]) == "Incorrect API key provided: ***. (HTTP 401)")
        #expect(Validation.failureMessage(status: 404, body: Data(#"{"error":"model 'x' not found"}"#.utf8), secrets: []) == "model 'x' not found (HTTP 404)")
        #expect(Validation.failureMessage(status: 502, body: Data("<html>".utf8), secrets: []) == "HTTP 502")
    }

    @Test func theSecretsKeySealsAndOpensOnlyInItsContext() throws {
        let key = SecretsKey.random()
        let sealed = try key.seal("sk-secret", context: "provider_credentials:1")
        #expect(sealed.hasPrefix("v1:") && !sealed.contains("sk-secret"))
        #expect(try key.open(sealed, context: "provider_credentials:1") == "sk-secret")
        #expect(try key.seal("sk-secret", context: "c") != key.seal("sk-secret", context: "c"))  // fresh nonce
        #expect(throws: (any Error).self) { try key.open(sealed, context: "provider_credentials:2") }
        #expect(throws: (any Error).self) { try SecretsKey.random().open(sealed, context: "provider_credentials:1") }
        #expect(try SecretsKey.from(setting: "") == nil && SecretsKey.from(setting: "  ") == nil)
        #expect(throws: SecretsKey.Invalid.self) { try SecretsKey.from(setting: "c2hvcnQ=") }
        let configured = try #require(try SecretsKey.from(setting: Data(repeating: 7, count: 32).base64EncodedString()))
        #expect(try configured.open(configured.seal("x", context: "c"), context: "c") == "x")
    }
}
