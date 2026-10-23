import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

@Suite("Chatflow prompt memory")
struct ConversationMemoryTests {
    final class Memory: ConversationMemory {
        let limits = Mutex<[Int]>([])
        let turns: [ConversationMemoryTurn]
        init(_ turns: [ConversationMemoryTurn]) { self.turns = turns }
        func history(messageLimit: Int) async throws -> [ConversationMemoryTurn] {
            limits.withLock { $0.append(messageLimit) }; return turns
        }
    }
    final class Counter: ModelRuntime {
        let counted = Mutex<[[PromptMessage]]>([])
        func credentials(provider: String, model: String, modelType: String) async throws -> JSONObject { [:] }
        func modelSchema(provider: String, model: String, modelType: String, credentials: JSONObject) async throws -> AIModelEntity? { nil }
        func numTokens(_ instance: ModelInstance, promptMessages: [PromptMessage]) async throws -> Int {
            counted.withLock { $0.append(promptMessages) }; return promptMessages.count * 4 + 1
        }
        func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, stop: [String],
                       user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
            AsyncThrowingStream { $0.finish(throwing: NodeError("UnexpectedInvocation", "memory only")) }
        }
    }
    static let instance = ModelInstance(provider: "fixture/provider", modelName: "test", credentials: [:], parameters: ["max_tokens": 1], stop: [])
    @Test func realCounterBudgetPrunesIndividualOldMessagesAndKeepsLiteralText() async throws {
        let model = Counter()
        let memory = Memory([.init(query: "old", answer: "old-answer"), .init(query: "{{#sys.query#}}", answer: "latest")])
        let config = LLMNodeData.Memory(rolePrefix: nil, windowEnabled: true, windowSize: 3, queryPromptTemplate: nil)
        var bytes = 0
        let schema = AIModelEntity(json: ["model": "test", "model_type": "llm", "model_properties": ["context_size": 11]])
        let messages = try await ConversationPromptMemory.messages(memory: memory, config: config, models: model,
            instance: Self.instance, schema: schema, imageBytes: &bytes)
        #expect(messages.count == 2)
        #expect(ConversationPromptMemory.text(messages, config: config) == "Human: {{#sys.query#}}\nAssistant: latest")
        #expect(memory.limits.withLock { $0 } == [3])
        #expect(model.counted.withLock { $0.first?.isEmpty } == true, "model context accounting counts even the empty prompt")
    }
    @Test func templateInjectionCannotInterpretHistoryAsVariables() throws {
        var pool = VariablePool(); try pool.add(["sys", "query"], "secret-current-query")
        let messages = try LLMPrompting.listMessages([(.system, "History=" + ConversationPromptMemory.placeholder)], pool: pool)
        let inserted = ConversationPromptMemory.inserting("Human: {{#sys.query#}}", into: messages)
        let config = LLMNodeData.Memory(rolePrefix: nil, windowEnabled: false, windowSize: nil, queryPromptTemplate: nil)
        #expect(ConversationPromptMemory.text(inserted, config: config).contains("{{#sys.query#}}"))
        #expect(!ConversationPromptMemory.text(inserted, config: config).contains("secret-current-query"))
    }
}
