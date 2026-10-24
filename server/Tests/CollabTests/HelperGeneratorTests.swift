import CollabRuntime
import Testing
@testable import CollabServer

private struct HelperFixtureModel: ModelRuntime {
    let replies: [String]
    let cursor = HelperReplyCursor()
    func credentials(provider: String, model: String, modelType: String) async throws -> JSONObject { [:] }
    func modelSchema(provider: String, model: String, modelType: String, credentials: JSONObject) async throws -> AIModelEntity? { nil }
    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, stop: [String], user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let i = await cursor.next()
                guard i < replies.count else { continuation.finish(throwing: NodeError("TestError", "Unexpected extra invocation")); return }
                continuation.yield(.init(model: instance.modelName, content: .text(replies[i])))
                continuation.finish()
            }
        }
    }
}
private actor HelperReplyCursor { var i = 0; func next() -> Int { defer { i += 1 }; return i } }
private func generator(_ replies: [String]) -> HelperGenerator {
    .init(runtime: HelperFixtureModel(replies: replies), model: .init(provider: "fixture/p/model", modelName: "local", credentials: [:], parameters: [:], stop: []), user: "fixture")
}
@Suite("Real helper generation boundary") struct HelperGeneratorTests {
    @Test func badModelOutputIsNeverAUsableSchemaOrCode() async throws {
        await #expect(throws: (any Error).self) { _ = try await generator(["not JSON"]).generate(kind: "rule-structured-output-generate", body: [:], instruction: "schema") }
        await #expect(throws: (any Error).self) { _ = try await generator(["```python\nprint('no main')\n```"]).generate(kind: "rule-code-generate", body: ["code_language": "python3"], instruction: "code") }
        await #expect(throws: (any Error).self) { _ = try await generator([#"{"type":"object","required":["missing"],"properties":{}}"#]).generate(kind: "rule-structured-output-generate", body: [:], instruction: "schema") }
        let good = try await generator([#"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#]).generate(kind: "rule-structured-output-generate", body: [:], instruction: "schema")
        #expect(good["output"]?.string?.contains("name") == true)
    }
    @Test func plannerAndNodeBuildersProduceAnExecutableProposalWithoutRunningIt() async throws {
        let plan = #"{"nodes":[{"id":"s","node_type":"start","label":"Start"},{"id":"e","node_type":"end","label":"End"}],"edges":[{"source":"s","target":"e"}]}"#
        let graph = try await generator([plan, #"{"config":{"variables":[]}}"#, #"{"config":{"outputs":[]}}"#]).generate(kind: "workflow-generate", body: ["mode": "workflow"], instruction: "Empty workflow")
        #expect(graph["graph"]?["nodes"]?.array?.count == 2)
        #expect(graph["mode"] == "workflow")
        await #expect(throws: (any Error).self) {
            _ = try await generator([#"{"nodes":[{"id":"s","node_type":"start"},{"id":"s","node_type":"end"}],"edges":[{"source":"s","target":"s"}]}"#]).generate(kind: "workflow-generate", body: [:], instruction: "bad")
        }
    }
    @Test func variablePromptUsesTheOriginalThreeModelCalls() async throws {
        let result=try await generator(["Prompt {{topic}}",#"["topic"]"#,"Welcome"]).generate(kind:"rule-generate",body:[:],instruction:"Help with a topic")
        #expect(result["prompt"] == "Prompt {{topic}}")
        #expect(result["variables"] == ["topic"] && result["opening_statement"] == "Welcome")
        await #expect(throws:(any Error).self) {
            _ = try await generator([#"{"message":"No modified text"}"#]).generate(kind:"instruction-generate",body:[:],instruction:"edit")
        }
    }
    @Test func workflowRejectsUnresolvedSelectors() async throws {
        let plan = #"{"nodes":[{"id":"s","node_type":"start","label":"Start"},{"id":"e","node_type":"end","label":"End"}],"edges":[{"source":"s","target":"e"}]}"#
        await #expect(throws:(any Error).self) {
            _ = try await generator([plan,#"{"config":{"variables":[]}}"#,#"{"config":{"outputs":[{"variable":"q","value_selector":["missing","q"]}]}}"#]).generate(kind:"workflow-generate",body:[:],instruction:"bad reference")
        }
    }

}
