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

/// `PromptMessageTool`: a function the model may call (`{name, description, parameters}`).
public struct PromptMessageTool: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONObject

    public init(name: String, description: String, parameters: JSONObject) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public var json: JSONValue { ["name": .string(name), "description": .string(description), "parameters": .object(parameters)] }
}

/// `PromptMessage` (`content` is a string, a list of parts, or None); the assistant's `tool_calls` and the tool message's
/// `tool_call_id` (`AssistantPromptMessage`, `ToolPromptMessage`).
public struct PromptMessage: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        case none
        case text(String)
        case parts([PromptMessageContent])
    }

    /// `AssistantPromptMessage.ToolCall`.
    public struct ToolCall: Sendable, Hashable {
        public var id: String
        public var type: String
        public var name: String
        public var arguments: String

        public init(id: String, type: String = "function", name: String, arguments: String) {
            self.id = id
            self.type = type
            self.name = name
            self.arguments = arguments
        }

        public var json: JSONValue {
            ["id": .string(id), "type": .string(type), "function": ["name": .string(name), "arguments": .string(arguments)]]
        }

        /// From the daemon's JSON (ids that are not strings become their text, as pydantic's validator does).
        public init(json j: JSONValue) {
            switch j["id"] {
            case .string(let s)?: id = s
            case nil, .null?: id = ""
            case let v?: id = PythonText.str(v)
            }
            type = j["type"]?.string ?? ""
            name = j["function"]?["name"]?.string ?? ""
            arguments = j["function"]?["arguments"]?.string ?? ""
        }
    }

    public var role: PromptMessageRole
    public var content: Content
    public var name: String?
    public var toolCalls: [ToolCall] = []
    public var toolCallId: String?

    public init(role: PromptMessageRole, content: Content, name: String? = nil, toolCalls: [ToolCall] = [], toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// `is_empty()`: no content (an assistant message also no tool calls, a tool message no `tool_call_id`).
    public var isEmpty: Bool {
        let noContent: Bool
        switch content {
        case .none: noContent = true
        case .text(let s): noContent = s.isEmpty
        case .parts(let p): noContent = p.isEmpty
        }
        switch role {
        case .assistant: return noContent && toolCalls.isEmpty
        case .tool: return noContent && (toolCallId ?? "").isEmpty
        default: return noContent
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

    /// `jsonable_encoder(message)`: pydantic's field order (`role`, `content`, `name`, then the assistant's `tool_calls` or
    /// the tool message's `tool_call_id`).
    public var json: JSONValue {
        var o = JSONObject()
        o["role"] = .string(role.rawValue)
        switch content {
        case .none: o["content"] = .null
        case .text(let s): o["content"] = .string(s)
        case .parts(let p): o["content"] = .array(p.map(\.json))
        }
        o["name"] = name.map(JSONValue.string) ?? .null
        if role == .assistant { o["tool_calls"] = .array(toolCalls.map(\.json)) }
        if role == .tool { o["tool_call_id"] = .string(toolCallId ?? "") }
        return .object(o)
    }
}

/// A `Decimal` field as Python prints it (`str(Decimal)`, which is how pydantic's JSON mode writes it): kept as text.
public struct DecimalText: Sendable, Hashable, CustomStringConvertible {
    public var text: String
    public init(_ text: String) { self.text = text }
    public static let zero = DecimalText("0.0")
    public var description: String { text }

    /// `Decimal + Decimal` for plain decimal texts (`-12.345`): the sum with the larger number of fraction digits, as
    /// Python's `Decimal` keeps the exponent. Texts in exponent notation fall back to `Double`.
    public static func + (a: DecimalText, b: DecimalText) -> DecimalText {
        func parse(_ s: String) -> (neg: Bool, digits: [Int], frac: Int)? {
            var t = Substring(s.trimmingCharacters(in: .whitespaces))
            var neg = false
            if t.first == "-" { neg = true; t = t.dropFirst() } else if t.first == "+" { t = t.dropFirst() }
            let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, !t.isEmpty else { return nil }
            let whole = parts[0], frac = parts.count == 2 ? parts[1] : ""
            guard (whole + frac).allSatisfy({ $0.isASCII && $0.isNumber }), !(whole + frac).isEmpty else { return nil }
            return (neg, (whole + frac).map { Int(String($0))! }, frac.count)
        }
        guard let x = parse(a.text), let y = parse(b.text) else {
            return DecimalText(PythonText.floatRepr((Double(a.text) ?? 0) + (Double(b.text) ?? 0)))
        }
        let frac = max(x.frac, y.frac)
        func scaled(_ v: (neg: Bool, digits: [Int], frac: Int)) -> (Bool, [Int]) {
            (v.neg, v.digits + Array(repeating: 0, count: frac - v.frac))
        }
        // Magnitudes as little-endian digit arrays.
        let (xn, xd) = scaled(x), (yn, yd) = scaled(y)
        let n = max(xd.count, yd.count) + 1
        let xl = Array(xd.reversed()) + Array(repeating: 0, count: n - xd.count)
        let yl = Array(yd.reversed()) + Array(repeating: 0, count: n - yd.count)
        func compare(_ p: [Int], _ q: [Int]) -> Int {
            for i in stride(from: n - 1, through: 0, by: -1) where p[i] != q[i] { return p[i] < q[i] ? -1 : 1 }
            return 0
        }
        var result = Array(repeating: 0, count: n)
        var neg: Bool
        if xn == yn {
            var carry = 0
            for i in 0..<n { let d = xl[i] + yl[i] + carry; result[i] = d % 10; carry = d / 10 }
            neg = xn
        } else {
            let (big, small, bigNeg) = compare(xl, yl) >= 0 ? (xl, yl, xn) : (yl, xl, yn)
            var borrow = 0
            for i in 0..<n {
                var d = big[i] - small[i] - borrow
                borrow = d < 0 ? 1 : 0
                if d < 0 { d += 10 }
                result[i] = d
            }
            neg = bigNeg
        }
        var digits = result.reversed().map(String.init).joined()
        var whole = String(digits.dropLast(frac))
        let fraction = String(digits.suffix(frac))
        while whole.count > 1, whole.first == "0" { whole.removeFirst() }
        if whole.isEmpty { whole = "0" }
        digits = frac > 0 ? whole + "." + fraction : whole
        if digits.allSatisfy({ $0 == "0" || $0 == "." }) { neg = false }
        return DecimalText((neg ? "-" : "") + digits)
    }

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

    /// `LLMUsage.plus`: counters and prices summed, unit prices and timings of `other`.
    public func plus(_ other: LLMUsage) -> LLMUsage {
        if totalTokens == 0 { return other }
        var u = other
        u.promptTokens = promptTokens + other.promptTokens
        u.promptPrice = promptPrice + other.promptPrice
        u.completionTokens = completionTokens + other.completionTokens
        u.completionPrice = completionPrice + other.completionPrice
        u.totalTokens = totalTokens + other.totalTokens
        u.totalPrice = totalPrice + other.totalPrice
        u.latency = latency + other.latency
        return u
    }

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
    /// `delta.message.tool_calls` (deltas: merged by id, see `LLMResultAccumulator`).
    public var toolCalls: [PromptMessage.ToolCall] = []

    public init(model: String, index: Int = 0, content: PromptMessage.Content, usage: LLMUsage? = nil, finishReason: String? = nil,
                structuredOutput: JSONObject? = nil, toolCalls: [PromptMessage.ToolCall] = []) {
        self.toolCalls = toolCalls
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
        toolCalls = (delta["message"]?["tool_calls"]?.array ?? []).map(PromptMessage.ToolCall.init(json:))
    }
}

/// `AIModelEntity`, kept as the daemon's JSON with the members the runtime reads.
public struct AIModelEntity: Sendable, Hashable {
    public var json: JSONValue
    public init(json: JSONValue) { self.json = json }

    public var model: String { json["model"]?.string ?? "" }
    public var features: [String]? { json["features"]?.array?.compactMap(\.string) }
    public var modelProperties: JSONObject { json["model_properties"]?.object ?? JSONObject() }
    /// `model_type` (`llm` when absent: only LLM schemas are asked for).
    public var modelType: String { json["model_type"]?.string ?? "llm" }
    /// `parameter_rules` (`{name, use_template, options, ...}`).
    public var parameterRules: [JSONValue] { json["parameter_rules"]?.array ?? [] }
    /// `support_structure_output`: the `structured-output` feature.
    public var supportsStructuredOutput: Bool { features?.contains("structured-output") ?? false }
    /// `tool-call` or `multi-tool-call`.
    public var supportsToolCall: Bool { features.map { $0.contains("tool-call") || $0.contains("multi-tool-call") } ?? false }

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

    /// `invoke_llm(..., tools=, stream=)`: with functions the model may call (`tools`, none = null on the wire) and
    /// Dify's `stream` flag (`false`: the daemon still answers chunks; callers merge them, `LLMResultAccumulator`).
    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, tools: [PromptMessageTool],
                   stop: [String], stream: Bool, user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error>
}

extension ModelRuntime {
    /// Runtimes without function calling: tools are dropped, the stream flag is ignored.
    public func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, tools: [PromptMessageTool],
                          stop: [String], stream: Bool, user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        invokeLLM(instance, promptMessages: promptMessages, parameters: parameters, stop: stop, user: user)
    }
}

/// graphon's `_LLMChunkAccumulator` (a non-streamed result built from chunks): text, tool calls merged by id
/// (`merge_tool_call_deltas`), the last usage, the first finish reason.
public struct LLMResultAccumulator: Sendable {
    public var text = ""
    public var toolCalls: [PromptMessage.ToolCall] = []
    public var usage = LLMUsage.empty
    public var finishReason: String?

    public init() {}

    public mutating func consume(_ chunk: LLMResultChunk) throws {
        switch chunk.content {
        case .none: break
        case .text(let s): text += s
        case .parts(let ps): for case .text(let s) in ps { text += s }
        }
        for var delta in chunk.toolCalls {
            if !delta.name.isEmpty && delta.id.isEmpty { delta.id = "chatcmpl-tool-" + UUIDHex.make() }
            var index: Int
            if delta.id.isEmpty {
                guard !toolCalls.isEmpty else {
                    throw NodeError("ValueError", "tool_call_id is empty but no existing tool call is available to apply the delta")
                }
                index = toolCalls.count - 1
            } else if let i = toolCalls.firstIndex(where: { $0.id == delta.id }) {
                index = i
            } else {
                toolCalls.append(PromptMessage.ToolCall(id: delta.id, type: "function", name: "", arguments: ""))
                index = toolCalls.count - 1
            }
            if !delta.id.isEmpty { toolCalls[index].id = delta.id }
            if !delta.type.isEmpty { toolCalls[index].type = delta.type }
            if !delta.name.isEmpty { toolCalls[index].name = delta.name }
            if !delta.arguments.isEmpty { toolCalls[index].arguments += delta.arguments }
        }
        if let u = chunk.usage { usage = u }
        if finishReason == nil, let f = chunk.finishReason, !f.isEmpty { finishReason = f }
    }
}

/// `uuid.uuid4().hex`.
enum UUIDHex {
    static func make() -> String {
        var g = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.map { b in let h = String(b, radix: 16); return h.count == 1 ? "0" + h : h }.joined()
    }
}
