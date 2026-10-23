// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/llm/entities.py,
// graphon/prompt_entities.py. See ../../NOTICE.md.

/// `LLMNodeData`.
public struct LLMNodeData: Sendable {
    /// `ModelConfig`.
    public struct Model: Sendable {
        public var provider: String
        public var name: String
        /// `LLMMode`: `chat` or `completion`.
        public var mode: String
        public var completionParams: JSONObject
    }

    /// A chat message template (`LLMNodeChatModelMessage`) or the completion template (`LLMNodeCompletionModelPromptTemplate`).
    public struct PromptTemplateMessage: Sendable {
        public var text: String
        /// Nil for the completion template.
        public var role: PromptMessageRole?
        /// `basic`, `jinja2` or nil.
        public var editionType: String?
        public var jinja2Text: String?
    }

    public enum PromptTemplate: Sendable {
        case chat([PromptTemplateMessage])
        case completion(PromptTemplateMessage)
    }

    /// `MemoryConfig`.
    public struct Memory: Sendable {
        public var rolePrefix: (user: String, assistant: String)?
        public var windowEnabled: Bool
        public var windowSize: Int?
        public var queryPromptTemplate: String?
    }

    public struct Context: Sendable {
        public var enabled: Bool
        public var variableSelector: [String]?
    }

    public struct Vision: Sendable {
        public var enabled = false
        public var variableSelector: [String] = ["sys", "files"]
        public var detail = "high"
    }

    public var base: BaseNodeData
    public var model: Model
    public var promptTemplate: PromptTemplate
    /// `prompt_config.jinja2_variables`.
    public var jinja2Variables: [VariableSelector]
    public var memory: Memory?
    public var context: Context
    public var vision: Vision
    public var structuredOutput: JSONObject?
    /// `structured_output_enabled` (the switch).
    public var structuredOutputSwitchOn: Bool
    /// `separated` or `tagged` (default).
    public var reasoningFormat: String

    /// `structured_output_enabled`: the switch is on and a schema is given.
    public var structuredOutputEnabled: Bool { structuredOutputSwitchOn && structuredOutput != nil }

    public init(_ data: JSONObject) throws {
        base = try BaseNodeData(data)
        guard let m = data["model"]?.object else { throw NodeDataError("model: Field required") }
        guard let provider = m["provider"]?.string, let name = m["name"]?.string else { throw NodeDataError("model: provider and name are required") }
        guard let mode = m["mode"]?.string, mode == "chat" || mode == "completion" else {
            throw NodeDataError("model.mode: Input should be 'completion' or 'chat'")
        }
        model = Model(provider: provider, name: name, mode: mode, completionParams: m["completion_params"]?.object ?? JSONObject())

        func message(_ j: JSONValue, chat: Bool) throws -> PromptTemplateMessage {
            guard let text = j["text"]?.string else { throw NodeDataError("prompt_template: text is required") }
            var role: PromptMessageRole?
            if chat {
                guard let r = j["role"]?.string, let pr = PromptMessageRole(rawValue: r) else {
                    throw NodeDataError("prompt_template: role must be system, user, assistant or tool")
                }
                role = pr
            }
            let edition = j["edition_type"]?.string
            if let edition, edition != "basic", edition != "jinja2" { throw NodeDataError("prompt_template: edition_type must be basic or jinja2") }
            return PromptTemplateMessage(text: text, role: role, editionType: edition, jinja2Text: j["jinja2_text"]?.string)
        }
        switch data["prompt_template"] {
        case .array(let list)?: promptTemplate = .chat(try list.map { try message($0, chat: true) })
        case .object?: promptTemplate = .completion(try message(data["prompt_template"]!, chat: false))
        default: throw NodeDataError("prompt_template: Field required")
        }
        jinja2Variables = (data["prompt_config"]?["jinja2_variables"]?.array ?? []).compactMap(VariableSelector.init(json:))

        if let mem = data["memory"]?.object {
            var prefix: (String, String)?
            if let rp = mem["role_prefix"]?.object, let u = rp["user"]?.string, let a = rp["assistant"]?.string { prefix = (u, a) }
            memory = Memory(rolePrefix: prefix, windowEnabled: mem["window"]?["enabled"]?.bool ?? false,
                            windowSize: mem["window"]?["size"]?.int, queryPromptTemplate: mem["query_prompt_template"]?.string)
        }
        guard let ctx = data["context"]?.object else { throw NodeDataError("context: Field required") }
        context = Context(enabled: ctx["enabled"]?.bool ?? false,
                          variableSelector: ctx["variable_selector"]?.array.map { $0.compactMap(\.string) })
        vision = Vision()
        if let v = data["vision"]?.object {
            vision.enabled = v["enabled"]?.bool ?? false
            if let c = v["configs"]?.object {
                if let sel = c["variable_selector"]?.array { vision.variableSelector = sel.compactMap(\.string) }
                if let d = c["detail"]?.string {
                    guard ["low", "high"].contains(d) else { throw NodeDataError("vision.configs.detail: expected low or high") }
                    vision.detail = d
                }
            }
        }
        structuredOutput = data["structured_output"]?.object
        structuredOutputSwitchOn = data["structured_output_enabled"]?.bool ?? false
        let rf = data["reasoning_format"]?.string ?? "tagged"
        guard rf == "tagged" || rf == "separated" else { throw NodeDataError("reasoning_format: Input should be 'separated' or 'tagged'") }
        reasoningFormat = rf
    }
}
