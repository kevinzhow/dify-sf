// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/model_runtime/entities/message_entities.py, llm_entities.py, model_entities.py. See NOTICE.md.
// Only the entities: models are invoked through Dify's plugin daemon (see PluginDaemonWire.swift and the server's
// adapter), never in-process.

/// `PromptMessageRole`.
public enum PromptMessageRole: String, Sendable, Hashable {
    case system, user, assistant, tool
}

/// One part of a multi-part message (`PromptMessageContent`); only text before files exist (P5).
public enum PromptMessageContent: Sendable, Hashable {
    case text(String)

    public var type: String { "text" }
    public var json: JSONValue {
        switch self { case .text(let s): return ["type": "text", "data": .string(s)] }
    }
}

/// `PromptMessage` (`content` is a string, a list of parts, or None).
public struct PromptMessage: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        case none
        case text(String)
        case parts([PromptMessageContent])
    }

    public var role: PromptMessageRole
    public var content: Content
    public var name: String?

    public init(role: PromptMessageRole, content: Content, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }

    /// `is_empty()` (assistant messages without tool calls, the only kind built here, too).
    public var isEmpty: Bool {
        switch content {
        case .none: return true
        case .text(let s): return s.isEmpty
        case .parts(let p): return p.isEmpty
        }
    }

    /// `get_text_content()`.
    public var textContent: String {
        switch content {
        case .none: return ""
        case .text(let s): return s
        case .parts(let p): return p.map { if case .text(let s) = $0 { return s }; return "" }.joined()
        }
    }

    /// `jsonable_encoder(message)`: pydantic's field order (`role`, `content`, `name`, then the assistant's `tool_calls`).
    public var json: JSONValue {
        var o = JSONObject()
        o["role"] = .string(role.rawValue)
        switch content {
        case .none: o["content"] = .null
        case .text(let s): o["content"] = .string(s)
        case .parts(let p): o["content"] = .array(p.map(\.json))
        }
        o["name"] = name.map(JSONValue.string) ?? .null
        if role == .assistant { o["tool_calls"] = .array([]) }
        return .object(o)
    }
}

/// A `Decimal` field as Python prints it (`str(Decimal)`, which is how pydantic's JSON mode writes it): kept as text.
public struct DecimalText: Sendable, Hashable, CustomStringConvertible {
    public var text: String
    public init(_ text: String) { self.text = text }
    public static let zero = DecimalText("0.0")
    public var description: String { text }

    /// From JSON: a string as is, a number as pydantic converts it (`Decimal(str(number))`).
    public init(json: JSONValue?, default d: DecimalText = .zero) {
        switch json {
        case .string(let s)?: self.text = s
        case .int(let i)?: self.text = String(i)
        case .double(let x)?: self.text = PythonText.floatRepr(x)
        default: self = d
        }
    }
}

/// `LLMUsage`.
public struct LLMUsage: Sendable, Hashable {
    public var promptTokens = 0
    public var promptUnitPrice = DecimalText.zero
    public var promptPriceUnit = DecimalText.zero
    public var promptPrice = DecimalText.zero
    public var completionTokens = 0
    public var completionUnitPrice = DecimalText.zero
    public var completionPriceUnit = DecimalText.zero
    public var completionPrice = DecimalText.zero
    public var totalTokens = 0
    public var totalPrice = DecimalText.zero
    public var currency = "USD"
    public var latency = 0.0
    public var timeToFirstToken: Double?
    public var timeToGenerate: Double?

    public init() {}

    /// `LLMUsage.empty_usage()`.
    public static let empty = LLMUsage()

    /// From the plugin daemon's JSON (missing fields take `empty_usage`'s values).
    public init(json: JSONValue) {
        promptTokens = json["prompt_tokens"]?.int ?? 0
        promptUnitPrice = DecimalText(json: json["prompt_unit_price"])
        promptPriceUnit = DecimalText(json: json["prompt_price_unit"])
        promptPrice = DecimalText(json: json["prompt_price"])
        completionTokens = json["completion_tokens"]?.int ?? 0
        completionUnitPrice = DecimalText(json: json["completion_unit_price"])
        completionPriceUnit = DecimalText(json: json["completion_price_unit"])
        completionPrice = DecimalText(json: json["completion_price"])
        totalTokens = json["total_tokens"]?.int ?? 0
        totalPrice = DecimalText(json: json["total_price"])
        currency = json["currency"]?.string ?? "USD"
        latency = json["latency"]?.double ?? 0
        timeToFirstToken = json["time_to_first_token"]?.double
        timeToGenerate = json["time_to_generate"]?.double
    }

    /// `jsonable_encoder(usage)`: pydantic's JSON mode (decimals as strings), field order kept.
    public var json: JSONValue {
        .object([
            "prompt_tokens": .int(promptTokens),
            "prompt_unit_price": .string(promptUnitPrice.text),
            "prompt_price_unit": .string(promptPriceUnit.text),
            "prompt_price": .string(promptPrice.text),
            "completion_tokens": .int(completionTokens),
            "completion_unit_price": .string(completionUnitPrice.text),
            "completion_price_unit": .string(completionPriceUnit.text),
            "completion_price": .string(completionPrice.text),
            "total_tokens": .int(totalTokens),
            "total_price": .string(totalPrice.text),
            "currency": .string(currency),
            "latency": .double(latency),
            "time_to_first_token": timeToFirstToken.map(JSONValue.double) ?? .null,
            "time_to_generate": timeToGenerate.map(JSONValue.double) ?? .null,
        ])
    }
}

/// `LLMResultChunk` (what `dispatch/llm/invoke` streams), reduced to what the LLM node reads.
public struct LLMResultChunk: Sendable, Hashable {
    public var model: String
    public var index: Int
    /// The delta message's content.
    public var content: PromptMessage.Content
    public var usage: LLMUsage?
    public var finishReason: String?
    /// `LLMResultChunkWithStructuredOutput.structured_output`.
    public var structuredOutput: JSONObject?

    public init(model: String, index: Int = 0, content: PromptMessage.Content, usage: LLMUsage? = nil, finishReason: String? = nil,
                structuredOutput: JSONObject? = nil) {
        self.model = model
        self.index = index
        self.content = content
        self.usage = usage
        self.finishReason = finishReason
        self.structuredOutput = structuredOutput
    }

    /// From the daemon's chunk JSON (`{model, prompt_messages, system_fingerprint, delta: {index, message, usage,
    /// finish_reason}}`).
    public init(json: JSONValue) {
        model = json["model"]?.string ?? ""
        let delta = json["delta"] ?? .null
        index = delta["index"]?.int ?? 0
        switch delta["message"]?["content"] {
        case .string(let s)?: content = .text(s)
        case .array(let parts)?:
            content = .parts(parts.compactMap { p in
                p["type"]?.string == "text" ? .text(p["data"]?.string ?? "") : nil
            })
        default: content = .none
        }
        if let u = delta["usage"], u != .null { usage = LLMUsage(json: u) } else { usage = nil }
        finishReason = delta["finish_reason"]?.string
        structuredOutput = json["structured_output"]?.object
    }
}

/// `AIModelEntity`, kept as the daemon's JSON with the members the runtime reads.
public struct AIModelEntity: Sendable, Hashable {
    public var json: JSONValue
    public init(json: JSONValue) { self.json = json }

    public var model: String { json["model"]?.string ?? "" }
    public var features: [String]? { json["features"]?.array?.compactMap(\.string) }
    public var modelProperties: JSONObject { json["model_properties"]?.object ?? JSONObject() }

    /// `supports_prompt_content_type`: text always; images need `vision`, documents `document`, and so on.
    public func supports(contentType: String) -> Bool {
        guard let features, !features.isEmpty else { return contentType == "text" }
        let required = ["image": "vision", "document": "document", "video": "video", "audio": "audio"][contentType]
        return required == nil || features.contains(required!)
    }
}

/// The model a node runs with (`ModelInstance` after `fetch_model_config`): provider, model, credentials, the node's
/// completion params without `stop`, and the stop words.
public struct ModelInstance: Sendable {
    public var provider: String
    public var modelName: String
    public var credentials: JSONObject
    public var parameters: JSONObject
    public var stop: [String]

    public init(provider: String, modelName: String, credentials: JSONObject, parameters: JSONObject, stop: [String]) {
        self.provider = provider
        self.modelName = modelName
        self.credentials = credentials
        self.parameters = parameters
        self.stop = stop
    }
}

/// An error from a model invocation, with Dify's error class name (`InvokeAuthorizationError`, ...) and message; its
/// description is what `str(exc)` prints in Dify.
public struct ModelInvokeError: Error, CustomStringConvertible, Sendable {
    public var errorType: String
    public var message: String
    public init(errorType: String, message: String) {
        self.errorType = errorType
        self.message = message
    }
    public var description: String { message }
}

/// Where models come from: credentials of the workspace, schemas and invocations (Dify's model manager + plugin daemon).
public protocol ModelRuntime: Sendable {
    /// The current credentials of `model` (Dify's `CredentialsProvider.fetch`): the custom model's, else the provider's.
    /// Throws when the provider or model is not configured.
    func credentials(provider: String, model: String, modelType: String) async throws -> JSONObject

    /// `get_model_schema` (nil: the model has none).
    func modelSchema(provider: String, model: String, modelType: String, credentials: JSONObject) async throws -> AIModelEntity?

    /// `invoke_llm(..., stream=True)`: the chunks as they come.
    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, stop: [String],
                   user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error>
}
