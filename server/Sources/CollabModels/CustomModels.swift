/// A model's schema as Dify's model lists and parameter-rules endpoint use it (graphon's `AIModelEntity` without pricing).
public struct ModelSchema: Sendable, Equatable {
    public var model: String
    public var label: JSON
    public var modelType: String
    public var features: [String]?
    public var fetchFrom: String
    public var modelProperties: [String: JSON]
    public var deprecated: Bool
    public var parameterRules: [JSON]
}

extension ModelDefinition {
    public var schema: ModelSchema {
        ModelSchema(model: model, label: label, modelType: modelType, features: features, fetchFrom: fetchFrom,
                    modelProperties: modelProperties, deprecated: deprecated, parameterRules: parameterRules)
    }
}

/// Schemas of custom models (`customizable-model`), which Dify's plugins compute in Python from the model's credentials
/// (`get_customizable_model_schema`). Ported by hand for `ollama` (models/llm/llm.py, text_embedding, rerank) and
/// `openai_api_compatible` (the SDK's `interfaces/model/openai_compatible/*` plus the plugin's additions) at the vendored
/// commit; every other provider gets a generic schema (temperature, top_p and max_tokens from the templates; mode and
/// context size from the credentials). Azure OpenAI's base-model table (Python, `models/constants.py`) is not ported yet:
/// Azure custom models get the generic schema.
public enum CustomModels {
    /// Nil when the plugin would have none: no credentials (the SDK asks only `if credentials`), or credentials its Python
    /// cannot read (a non-numeric context size, an unknown completion mode).
    public static func schema(provider: ProviderDefinition, model: String, modelType: String, credentials: [String: JSON]?) -> ModelSchema? {
        guard let credentials, !credentials.isEmpty else { return nil }
        let built: ModelSchema?
        switch provider.id.description {
        case "langgenius/ollama/ollama": built = ollama(model, modelType, credentials)
        case "langgenius/openai_api_compatible/openai_api_compatible": built = openAICompatible(model, modelType, credentials)
        default: built = generic(model, modelType, credentials)
        }
        guard var schema = built else { return nil }
        schema.parameterRules = schema.parameterRules.map { rule in
            ParameterRules.output(ParameterRules.hydrateCustomizable(rule.object ?? [:]))
        }
        return schema
    }

    // MARK: - Python helpers

    /// `int(credentials.get(key, default))`: nil where Python raises.
    static func pyInt(_ c: [String: JSON], _ key: String, _ def: Int) -> Int? {
        guard let v = c[key] else { return def }
        switch v {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// `float(credentials.get(key, default))`.
    static func pyFloat(_ c: [String: JSON], _ key: String, _ def: Double) -> Double? {
        guard let v = c[key] else { return def }
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func str(_ c: [String: JSON], _ key: String) -> String? { c[key]?.scalarText }

    /// `ParameterRule(**kwargs)`: the SDK merges the template under the given keys.
    static func rule(_ kwargs: [String: JSON]) -> JSON { .object(ParameterRules.merged(kwargs)) }

    static func i18n(_ en: String, _ zh: String? = nil) -> JSON { ["en_US": .string(en), "zh_Hans": .string(zh ?? en)] }

    static func base(_ model: String, _ type: String, props: [String: JSON], rules: [JSON] = [], features: [String]? = nil) -> ModelSchema {
        ModelSchema(model: model, label: i18n(model), modelType: type, features: features, fetchFrom: "customizable-model",
                    modelProperties: props, deprecated: false, parameterRules: rules)
    }

    // MARK: - Generic

    static func generic(_ model: String, _ type: String, _ c: [String: JSON]) -> ModelSchema? {
        switch type {
        case "llm":
            var features: [String] = []
            switch str(c, "function_calling_type") {
            case "function_call": features.append("tool-call")
            case "tool_call": features.append("multi-tool-call")
            default: break
            }
            if str(c, "vision_support") == "support" { features.append("vision") }
            guard let context = pyInt(c, "context_size", 4096) else { return nil }
            var maxTokens: [String: JSON] = ["name": "max_tokens", "use_template": "max_tokens"]
            if c["max_tokens"] != nil {
                guard let m = pyInt(c, "max_tokens", 4096) else { return nil }
                maxTokens["max"] = .int(m)
            }
            return base(model, type, props: ["mode": .string(str(c, "mode") ?? "chat"), "context_size": .int(context)],
                        rules: [rule(["name": "temperature", "use_template": "temperature"]),
                                rule(["name": "top_p", "use_template": "top_p"]),
                                rule(maxTokens)],
                        features: features)
        case "text-embedding":
            guard let context = pyInt(c, "context_size", 512) else { return nil }
            return base(model, type, props: ["context_size": .int(context), "max_chunks": 1])
        default:
            return base(model, type, props: [:])
        }
    }

    // MARK: - Ollama

    static let truthy: Set<String> = ["true", "supported", "yes", "1"]

    static func ollama(_ model: String, _ type: String, _ c: [String: JSON]) -> ModelSchema? {
        switch type {
        case "text-embedding":
            guard let context = pyInt(c, "context_size", 512) else { return nil }
            return base(model, type, props: ["context_size": .int(context), "max_chunks": 1], features: nil)
        case "rerank":
            guard let context = pyInt(c, "context_size", 512) else { return nil }
            return base(model, type, props: ["context_size": .int(context)])
        case "llm":
            break
        default:
            return nil
        }
        var features: [String] = []
        if c["vision_support"]?.scalarText == "true" { features.append("vision") }
        if truthy.contains((c["function_call_support"]?.scalarText ?? "").lowercased()) {
            features += ["tool-call", "multi-tool-call"]
            if let s = c["stream_function_calling"] {
                if truthy.contains((s.scalarText ?? "").lowercased()) { features.append("stream-tool-call") }
            } else {
                features.append("stream-tool-call")
            }
        }
        guard let context = pyInt(c, "context_size", 4096), let maxTokens = pyInt(c, "max_tokens", 4096) else { return nil }
        let rules: [JSON] = [
            rule(["name": "temperature", "use_template": "temperature", "label": i18n("Temperature", "温度"), "type": "float"]),
            rule(["name": "top_p", "use_template": "top_p", "label": i18n("Top P", "Top P"), "type": "float",
                  "help": i18n("Works together with top-k. A higher value (e.g., 0.95) will lead to more diverse text, while a lower value (e.g., 0.5) will generate more focused and conservative text. (Default: 0.9)",
                               "与top-k一起工作。较高的值（例如，0.95）会导致生成更多样化的文本，而较低的值（例如，0.5）会生成更专注和保守的文本。（默认值：0.9）"),
                  "default": .double(0.9), "min": 0, "max": 1]),
            rule(["name": "top_k", "label": i18n("Top K", "Top K"), "type": "int",
                  "help": i18n("Reduces the probability of generating nonsense. A higher value (e.g. 100) will give more diverse answers, while a lower value (e.g. 10) will be more conservative. (Default: 40)",
                               "减少生成无意义内容的可能性。较高的值（例如100）将提供更多样化的答案，而较低的值（例如10）将更为保守。（默认值：40）"),
                  "min": 1, "max": 100]),
            rule(["name": "repeat_penalty", "label": ["en_US": "Repeat Penalty"], "type": "float",
                  "help": i18n("Sets how strongly to penalize repetitions. A higher value (e.g., 1.5) will penalize repetitions more strongly, while a lower value (e.g., 0.9) will be more lenient. (Default: 1.1)",
                               "设置对重复内容的惩罚强度。一个较高的值（例如，1.5）会更强地惩罚重复内容，而一个较低的值（例如，0.9）则会相对宽容。（默认值：1.1）"),
                  "min": -2, "max": 2]),
            rule(["name": "num_predict", "use_template": "max_tokens", "label": i18n("Num Predict", "最大令牌数预测"), "type": "int",
                  "help": i18n("Maximum number of tokens to predict when generating text. (Default: 128, -1 = infinite generation, -2 = fill context)",
                               "生成文本时预测的最大令牌数。（默认值：128，-1 = 无限生成，-2 = 填充上下文）"),
                  "default": .int(maxTokens >= 768 ? 512 : 128), "min": -2, "max": .int(maxTokens)]),
            rule(["name": "mirostat", "label": i18n("Mirostat sampling", "Mirostat 采样"), "type": "int",
                  "help": i18n("Enable Mirostat sampling for controlling perplexity. (default: 0, 0 = disabled, 1 = Mirostat, 2 = Mirostat 2.0)",
                               "启用 Mirostat 采样以控制困惑度。（默认值：0，0 = 禁用，1 = Mirostat，2 = Mirostat 2.0）"),
                  "min": 0, "max": 2]),
            rule(["name": "mirostat_eta", "label": i18n("Mirostat Eta", "学习率"), "type": "float",
                  "help": i18n("Influences how quickly the algorithm responds to feedback from the generated text. A lower learning rate will result in slower adjustments, while a higher learning rate will make the algorithm more responsive. (Default: 0.1)",
                               "影响算法对生成文本反馈响应的速度。较低的学习率会导致调整速度变慢，而较高的学习率会使得算法更加灵敏。（默认值：0.1）"),
                  "precision": 1]),
            rule(["name": "mirostat_tau", "label": i18n("Mirostat Tau", "文本连贯度"), "type": "float",
                  "help": i18n("Controls the balance between coherence and diversity of the output. A lower value will result in more focused and coherent text. (Default: 5.0)",
                               "控制输出的连贯性和多样性之间的平衡。较低的值会导致更专注和连贯的文本。（默认值：5.0）"),
                  "precision": 1]),
            rule(["name": "num_ctx", "label": i18n("Size of context window", "上下文窗口大小"), "type": "int",
                  "help": i18n("Sets the size of the context window used to generate the next token. (Default: 2048)",
                               "设置用于生成下一个标记的上下文窗口大小。（默认值：2048）"),
                  "default": 2048, "min": 1]),
            rule(["name": "num_gpu", "label": i18n("GPU Layers", "GPU 层数"), "type": "int",
                  "help": i18n("The number of layers to offload to the GPU(s). On macOS it defaults to 1 to enable metal support, 0 to disable.As long as a model fits into one gpu it stays in one. It does not set the number of GPU(s). ",
                               "加载到 GPU 的层数。在 macOS 上，默认为 1 以启用 Metal 支持，设置为 0 则禁用。只要模型适合一个 GPU，它就保留在其中。它不设置 GPU 的数量。"),
                  "min": -1, "default": 1]),
            rule(["name": "num_thread", "label": i18n("Num Thread", "线程数"), "type": "int",
                  "help": i18n("Sets the number of threads to use during computation. By default, Ollama will detect this for optimal performance. It is recommended to set this value to the number of physical CPU cores your system has (as opposed to the logical number of cores).",
                               "设置计算过程中使用的线程数。默认情况下，Ollama会检测以获得最佳性能。建议将此值设置为系统拥有的物理CPU核心数（而不是逻辑核心数）。"),
                  "min": 1]),
            rule(["name": "repeat_last_n", "label": i18n("Repeat last N", "回溯内容"), "type": "int",
                  "help": i18n("Sets how far back for the model to look back to prevent repetition. (Default: 64, 0 = disabled, -1 = num_ctx)",
                               "设置模型回溯多远的内容以防止重复。（默认值：64，0 = 禁用，-1 = num_ctx）"),
                  "min": -1]),
            rule(["name": "tfs_z", "label": i18n("TFS Z", "减少标记影响"), "type": "float",
                  "help": i18n("Tail free sampling is used to reduce the impact of less probable tokens from the output. A higher value (e.g., 2.0) will reduce the impact more, while a value of 1.0 disables this setting. (default: 1)",
                               "用于减少输出中不太可能的标记的影响。较高的值（例如，2.0）会更多地减少这种影响，而1.0的值则会禁用此设置。（默认值：1）"),
                  "precision": 1]),
            rule(["name": "seed", "label": i18n("Seed", "随机数种子"), "type": "int",
                  "help": i18n("Sets the random number seed to use for generation. Setting this to a specific number will make the model generate the same text for the same prompt. (Default: 0)",
                               "设置用于生成的随机数种子。将此设置为特定数字将使模型对相同的提示生成相同的文本。（默认值：0）")]),
            rule(["name": "keep_alive", "label": i18n("Keep Alive", "模型存活时间"), "type": "string",
                  "help": i18n("Sets how long the model is kept in memory after generating a response. This must be a duration string with a unit (e.g., '10m' for 10 minutes or '24h' for 24 hours). A negative number keeps the model loaded indefinitely, and '0' unloads the model immediately after generating a response. Valid time units are 's','m','h'. (Default: 5m)",
                               "设置模型在生成响应后在内存中保留的时间。这必须是一个带有单位的持续时间字符串（例如，'10m' 表示10分钟，'24h' 表示24小时）。负数表示无限期地保留模型，'0'表示在生成响应后立即卸载模型。有效的时间单位有 's'（秒）、'm'（分钟）、'h'（小时）。（默认值：5m）")]),
            rule(["name": "format", "label": i18n("Format", "返回格式"), "type": "string",
                  "help": i18n("the format to return a response in. Currently the only accepted value is json.", "返回响应的格式。目前唯一接受的值是json。"),
                  "options": ["json"]]),
            rule(["name": "json_schema", "label": i18n("JSON Schema", "JSON Schema"), "type": "string",
                  "help": i18n("Return output in the format defined by JSON Schema.", "按照JSON Schema定义的格式返回output")]),
            rule(["name": "think", "label": i18n("Think", "思考模式"), "type": "boolean",
                  "help": i18n("Enable or disable Ollama thinking mode. For GPT-OSS reasoning levels, use Think Level.", "启用思考模式，模型在响应前会先进行思考。")]),
            rule(["name": "think_level", "label": i18n("Think Level", "思考等级"), "type": "string",
                  "help": i18n("Optional Ollama thinking level for GPT-OSS models. Overrides Think when set.", "GPT-OSS 模型可选的 Ollama 思考等级。设置后会覆盖 Think。"),
                  "options": ["low", "medium", "high"]]),
        ]
        return ModelSchema(model: model, label: i18n(model, model), modelType: "llm", features: features, fetchFrom: "customizable-model",
                           modelProperties: ["mode": c["mode"].flatMap(\.scalarText).map(JSON.string) ?? .null, "context_size": .int(context)],
                           deprecated: false, parameterRules: rules)
    }

    // MARK: - OpenAI-API-compatible

    static func openAICompatible(_ model: String, _ type: String, _ c: [String: JSON]) -> ModelSchema? {
        var schema: ModelSchema
        switch type {
        case "llm":
            guard let s = openAICompatibleLLM(model, c) else { return nil }
            schema = s
        case "text-embedding":
            guard let context = pyInt(c, "context_size", 512) else { return nil }
            schema = base(model, type, props: ["context_size": .int(context), "max_chunks": 1])
            if str(c, "vision_support") == "support" { schema.features = ["vision"] }
        case "rerank":
            schema = base(model, type, props: [:])
            if str(c, "vision_support") == "support" { schema.features = ["vision"] }
        case "tts":
            var voices: [JSON] = (str(c, "voices") ?? "alloy").trimmingCharacters(in: .whitespaces).split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { ["name": .string($0), "mode": .string($0), "language": "en-US"] }
            if voices.isEmpty { voices = [["name": "Alloy", "mode": "alloy", "language": "en-US"]] }
            guard let wordLimit = pyInt(c, "word_limit", 4096) else { return nil }
            schema = base(model, type, props: ["audio_type": .string(str(c, "audio_type") ?? "mp3"), "word_limit": .int(wordLimit),
                                               "default_voice": voices[0]["mode"] ?? "alloy", "voices": .array(voices)])
        case "speech2text":
            schema = base(model, type, props: [:])
        default:
            return nil
        }
        if let name = str(c, "display_name"), !name.isEmpty { schema.label = i18n(name, name) }
        return schema
    }

    static func openAICompatibleLLM(_ model: String, _ c: [String: JSON]) -> ModelSchema? {
        // The SDK's OAICompatLargeLanguageModel.get_customizable_model_schema.
        var features: [String] = []
        switch str(c, "function_calling_type") ?? "no_call" {
        case "function_call": features.append("tool-call")
        case "tool_call": features.append("multi-tool-call")
        default: break
        }
        if (str(c, "stream_function_calling") ?? "supported") == "supported" { features.append("stream-tool-call") }
        if (str(c, "vision_support") ?? "not_support") == "support" { features.append("vision") }
        if (str(c, "video_support") ?? "not_support") == "support" { features.append("video") }
        guard let context = pyInt(c, "context_size", 4096), let temperature = pyFloat(c, "temperature", 0.7),
              let topP = pyFloat(c, "top_p", 1), let frequency = pyFloat(c, "frequency_penalty", 0),
              let presence = pyFloat(c, "presence_penalty", 0), let maxTokens = pyInt(c, "max_tokens_to_sample", 4096) else { return nil }
        let mode: String
        switch str(c, "mode") {
        case "chat": mode = "chat"
        case "completion": mode = "completion"
        default: return nil  // KeyError / "Unknown completion type"
        }
        var rules: [JSON] = [
            rule(["name": "temperature", "label": i18n("Temperature", "温度"),
                  "help": i18n("Kernel sampling threshold. Used to determine the randomness of the results.The higher the value, the stronger the randomness.The higher the possibility of getting different answers to the same question.",
                               "核采样阈值。用于决定结果随机性，取值越高随机性越强即相同的问题得到的不同答案的可能性越高。"),
                  "type": "float", "default": .double(temperature), "min": 0, "max": 2, "precision": 2]),
            rule(["name": "top_p", "label": i18n("Top P", "Top P"),
                  "help": i18n("The probability threshold of the nucleus sampling method during the generation process.The larger the value is, the higher the randomness of generation will be.The smaller the value is, the higher the certainty of generation will be.",
                               "生成过程中核采样方法概率阈值。取值越大，生成的随机性越高；取值越小，生成的确定性越高。"),
                  "type": "float", "default": .double(topP), "min": 0, "max": 1, "precision": 2]),
            rule(["name": "frequency_penalty", "label": i18n("Frequency Penalty", "频率惩罚"),
                  "help": i18n("For controlling the repetition rate of words used by the model.Increasing this can reduce the repetition of the same words in the model's output.",
                               "用于控制模型已使用字词的重复率。 提高此项可以降低模型在输出中重复相同字词的重复度。"),
                  "type": "float", "default": .double(frequency), "min": -2, "max": 2]),
            rule(["name": "presence_penalty", "label": i18n("Presence Penalty", "存在惩罚"),
                  "help": i18n("Used to control the repetition rate when generating models.Increasing this can reduce the repetition rate of model generation.",
                               "用于控制模型生成时的重复度。提高此项可以降低模型生成的重复度。"),
                  "type": "float", "default": .double(presence), "min": -2, "max": 2]),
            rule(["name": "max_tokens", "label": i18n("Max Tokens", "最大标记"),
                  "help": i18n("Maximum length of tokens for the model response.", "模型回答的tokens的最大长度。"),
                  "type": "int", "default": 512, "min": 1, "max": .int(maxTokens)]),
        ]
        // The plugin's additions (openai_api_compatible/models/llm/llm.py).
        if (str(c, "structured_output_support") ?? "not_supported") == "supported" {
            rules.append(rule(["name": "response_format", "label": i18n("Response Format", "回复格式"),
                               "help": i18n("Specifying the format that the model must output.", "指定模型必须输出的回复格式。"),
                               "type": "string", "options": ["text", "json_object", "json_schema"], "required": false]))
            rules.append(rule(["name": "json_schema", "use_template": "json_schema"]))
        }
        let thought = str(c, "agent_thought_support") ?? "not_supported"
        if thought == "supported" || thought == "only_thinking_supported", !features.contains("agent-thought") { features.append("agent-thought") }
        if thought == "supported" {
            rules.append(rule(["name": "enable_thinking", "label": i18n("Thinking mode", "思考模式"),
                               "help": i18n("Whether to enable thinking mode, applicable to various thinking mode models deployed on reasoning frameworks such as vLLM and SGLang, for example Qwen3.",
                                            "是否开启思考模式，适用于vLLM和SGLang等推理框架部署的多种思考模式模型，例如Qwen3。"),
                               "type": "boolean", "required": false]))
        }
        if thought == "supported" || thought == "only_thinking_supported" {
            rules.append(rule(["name": "reasoning_format", "label": i18n("Reasoning Format", "推理格式"),
                               "help": i18n("Specifies the format in which the model must output reasoning.", "指定模型必须输出的推理格式。"),
                               "type": "string", "options": ["none", "auto", "deepseek", "deepseek-legacy"], "required": false]))
            rules.append(rule(["name": "reasoning_effort", "label": i18n("Reasoning effort", "推理工作"),
                               "help": i18n("Constrains effort on reasoning for reasoning models. Not every level is accepted by every model — 'none' and 'xhigh' in particular are only supported by newer OpenAI reasoning models. The upstream endpoint validates the value.",
                                            "限制推理模型的推理工作。并非所有模型都接受全部级别，其中 none 与 xhigh 仅较新的 OpenAI 推理模型支持，具体由上游端点校验。"),
                               "type": "string", "options": ["none", "minimal", "low", "medium", "high", "xhigh"], "required": false]))
        }
        let webSearch = str(c, "web_search_support") ?? "not_supported"
        let apiType = str(c, "api_type") ?? "chat_completions"
        if webSearch != "not_supported" || apiType == "responses" {
            rules.append(rule(["name": "web_search", "label": i18n("Web Search", "联网搜索"),
                               "help": i18n("Whether to enable web search. When enabled, the model will search the internet for relevant information to generate responses.",
                                            "是否启用联网搜索。启用后，模型将搜索互联网以获取相关信息来生成回复。"),
                               "type": "boolean", "required": false, "default": false]))
        }
        if apiType == "responses" {
            rules.append(rule(["name": "web_search_allowed_domains", "label": i18n("Allowed Domains", "允许的搜索域名"),
                               "help": i18n("Comma or newline-separated list of allowed domains for web search results (e.g., openai.com, github.com). Max 100 domains. Requires Responses API.",
                                            "允许的搜索域名列表，支持逗号或换行分隔（例如 openai.com, github.com）。最多 100 个域名。需要 Responses API。"),
                               "type": "string", "required": false]))
            rules.append(rule(["name": "web_search_blocked_domains", "label": i18n("Blocked Domains", "屏蔽的搜索域名"),
                               "help": i18n("Comma or newline-separated list of blocked domains for web search results (e.g., reddit.com, quora.com). Max 100 domains. Requires Responses API.",
                                            "屏蔽的搜索域名列表，支持逗号或换行分隔（例如 reddit.com, quora.com）。最多 100 个域名。需要 Responses API。"),
                               "type": "string", "required": false]))
            rules.append(rule(["name": "web_search_context_size", "label": i18n("Search Context Size", "搜索上下文大小"),
                               "help": i18n("Controls amount of web search result context provided to model ('low', 'medium', 'high'). Requires Responses API.",
                                            "控制提供给模型的网络搜索结果上下文量（'low', 'medium', 'high'）。需要 Responses API。"),
                               "type": "string", "options": ["medium", "low", "high"], "required": false]))
            rules.append(rule(["name": "web_search_user_country", "label": i18n("Search User Country", "搜索用户国家/地区"),
                               "help": i18n("Optional 2-letter ISO country code (e.g., US, JP) to refine search location. Requires Responses API.",
                                            "可选的 2 位 ISO 国家/地区代码（例如 US、JP）以优化搜索地理位置。需要 Responses API。"),
                               "type": "string", "required": false]))
        }
        for (key, feature) in [("video_support", "video"), ("audio_support", "audio"), ("document_support", "document")]
        where (str(c, key) ?? "no_support") == "support" && !features.contains(feature) {
            features.append(feature)
        }
        var schema = ModelSchema(model: model, label: i18n(model), modelType: "llm", features: features, fetchFrom: "customizable-model",
                                 modelProperties: ["context_size": .int(context), "mode": .string(mode)], deprecated: false,
                                 parameterRules: rules)
        if let name = str(c, "display_name"), !name.isEmpty { schema.label = i18n(name, name) }
        return schema
    }
}

import Foundation
