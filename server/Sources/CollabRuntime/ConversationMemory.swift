// Dify 1.17.1 core/memory/token_buffer_memory.py and graphon 0.7.0 nodes/llm/node.py.
// Memory is scoped to a durable turn, never a shared mutable list attached to the model runtime.
import Foundation

public struct ConversationMemoryTurn: Sendable {
    public var query: String
    public var answer: String
    public var files: [JSONValue]
    public var outputFiles: [JSONValue]
    public init(query: String, answer: String, files: [JSONValue] = [], outputFiles: [JSONValue] = []) {
        self.query = query; self.answer = answer; self.files = files; self.outputFiles = outputFiles
    }
}
public protocol ConversationMemory: Sendable {
    /// Window applies to the original newest-first message query, including this turn's blank message, as in Dify.
    func history(messageLimit: Int) async throws -> [ConversationMemoryTurn]
}

public enum ConversationPromptMemory {
    public static func messages(memory: any ConversationMemory, config: LLMNodeData.Memory, models: any ModelRuntime,
                                instance: ModelInstance, schema: AIModelEntity, prompt: [PromptMessage] = [],
                                files: (any RuntimeFiles)? = nil, extraTokenReserve: Int = 0, imageBytes: inout Int) async throws -> [PromptMessage] {
        let turns = try await memory.history(messageLimit: config.windowEnabled ? (config.windowSize ?? 500) : 500)
        var messages: [PromptMessage] = []
        for turn in turns {
            for (role, text, selected) in [(PromptMessageRole.user, turn.query, turn.files), (.assistant, turn.answer, turn.outputFiles)] {
                var parts: [PromptMessageContent] = []
                if schema.supports(contentType: "image"), !selected.isEmpty {
                    guard let files else { throw RuntimeFileError("File storage is not configured") }
                    for value in selected {
                        let file = try await files.resolve(value, config: nil)
                        guard file.type == "image" else { continue }
                        guard file.size >= 0, file.size <= LLMNode.maximumImagePromptBytes - imageBytes else {
                            throw RuntimeFileError("Vision input exceeds the total image size limit")
                        }
                        let bytes = try await files.bytes(file.json)
                        guard bytes.count <= LLMNode.maximumImagePromptBytes - imageBytes else {
                            throw RuntimeFileError("Vision input exceeds the total image size limit")
                        }
                        imageBytes += bytes.count
                        parts.append(.image(base64Data: Data(bytes).base64EncodedString(),
                            format: file.extensionName.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                            mimeType: file.mimeType, filename: file.filename, detail: "high"))
                    }
                }
                // Historical content is literal, never a variable template/Jinja program.
                if parts.isEmpty { messages.append(PromptMessage(role: role, content: .text(text))) }
                else { parts.append(.text(text)); messages.append(PromptMessage(role: role, content: .parts(parts))) }
            }
        }
        guard !messages.isEmpty else { return [] }
        var budget = 2000
        if let contextSize = schema.modelProperties["context_size"]?.int, contextSize != 0 {
            let maxName = schema.parameterRules.first { $0["name"]?.string == "max_tokens" || $0["use_template"]?.string == "max_tokens" }?["name"]?.string ?? "max_tokens"
            let chosen = instance.parameters[maxName]?.int ?? 0
            let output = chosen != 0 ? chosen : (instance.parameters["max_tokens"]?.int ?? 0)
            let promptTokens = try await models.numTokens(instance, promptMessages: prompt)
            budget = max(contextSize - output - promptTokens - extraTokenReserve, 0)
        }
        while messages.count > 1 {
            let count = try await models.numTokens(instance, promptMessages: messages)
            if count <= budget { break }
            messages.removeFirst()
        }
        return messages
    }
    public static func text(_ messages: [PromptMessage], config: LLMNodeData.Memory) -> String {
        messages.map { message in
            let prefix = message.role == .user ? (config.rolePrefix?.user ?? "Human") : (config.rolePrefix?.assistant ?? "Assistant")
            let text: String
            switch message.content {
            case .none: text = ""
            case .text(let value): text = value
            case .parts(let parts): text = parts.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
            }
            return prefix + ": " + text
        }.joined(separator: "\n")
    }
    public static func config(_ value: JSONValue?) -> LLMNodeData.Memory? {
        guard let value, value.object != nil else { return nil }
        let prefix = value["role_prefix"]
        return .init(rolePrefix: prefix.map { (user: $0["user"]?.string ?? "Human", assistant: $0["assistant"]?.string ?? "Assistant") },
                     windowEnabled: value["window"]?["enabled"]?.bool ?? false,
                     windowSize: value["window"]?["size"]?.int, queryPromptTemplate: value["query_prompt_template"]?.string)
    }
}

extension ConversationPromptMemory {
    static let placeholder = "\u{E000}conversation_history\u{E001}"
    static func inserting(_ history: String, into messages: [PromptMessage]) -> [PromptMessage] {
        messages.map { original in
            var message = original
            switch message.content {
            case .text(let text): message.content = .text(text.replacingOccurrences(of: placeholder, with: history))
            case .parts(let parts): message.content = .parts(parts.map { part in
                if case .text(let text) = part { return .text(text.replacingOccurrences(of: placeholder, with: history)) }; return part
            })
            case .none: break
            }
            return message
        }
    }
}
