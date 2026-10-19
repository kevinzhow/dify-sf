import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

/// A model runtime with a scripted answer (text pieces, tool calls), schema features and parameter rules; it records
/// every invocation (messages, parameters, tools, the stream flag).
final class ScriptedModels: ModelRuntime, Sendable {
    struct Call: Sendable {
        var messages: [PromptMessage]
        var parameters: JSONObject
        var tools: [PromptMessageTool]
        var stop: [String]
        var stream: Bool
    }
    let pieces: [String]
    let toolCalls: [PromptMessage.ToolCall]
    let features: [String]
    let rules: [JSONValue]
    let failure: (any Error)?
    private let calls = Mutex<[Call]>([])

    init(_ pieces: [String] = [], toolCalls: [PromptMessage.ToolCall] = [], features: [String] = [], rules: [JSONValue] = [],
         failure: (any Error)? = nil) {
        self.pieces = pieces
        self.toolCalls = toolCalls
        self.features = features
        self.rules = rules
        self.failure = failure
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func credentials(provider: String, model: String, modelType: String) async throws -> JSONObject { ["api_key": "sk-test"] }

    func modelSchema(provider: String, model: String, modelType: String, credentials: JSONObject) async throws -> AIModelEntity? {
        AIModelEntity(json: ["model": .string(model), "model_type": "llm", "features": .array(features.map(JSONValue.string)),
                             "parameter_rules": .array(rules), "model_properties": ["mode": "chat"]])
    }

    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, stop: [String],
                   user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        invokeLLM(instance, promptMessages: promptMessages, parameters: parameters, tools: [], stop: stop, stream: true, user: user)
    }

    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, tools: [PromptMessageTool],
                   stop: [String], stream: Bool, user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        calls.withLock { $0.append(Call(messages: promptMessages, parameters: parameters, tools: tools, stop: stop, stream: stream)) }
        let (s, c) = AsyncThrowingStream<LLMResultChunk, any Error>.makeStream()
        if let failure { c.finish(throwing: failure); return s }
        for p in pieces { c.yield(LLMResultChunk(model: instance.modelName, content: .text(p))) }
        // Tool calls arrive as deltas: the first with id and name, the rest only arguments.
        for call in toolCalls {
            let half = call.arguments.index(call.arguments.startIndex, offsetBy: call.arguments.count / 2)
            c.yield(LLMResultChunk(model: instance.modelName, content: .text(""),
                                   toolCalls: [.init(id: call.id, type: "function", name: call.name, arguments: String(call.arguments[..<half]))]))
            c.yield(LLMResultChunk(model: instance.modelName, content: .text(""),
                                   toolCalls: [.init(id: "", type: "", name: "", arguments: String(call.arguments[half...]))]))
        }
        var u = LLMUsage()
        u.promptTokens = 11
        u.completionTokens = 3
        u.totalTokens = 14
        c.yield(LLMResultChunk(model: instance.modelName, content: .text(""), usage: u, finishReason: "stop"))
        c.finish()
        return s
    }
}

let stubModel: JSONObject = ["provider": "langgenius/openai_api_compatible/openai_api_compatible", "name": "stub-chat", "mode": "chat",
                             "completion_params": ["temperature": 0.1]]

func runNode(_ data: JSONObject, models: ScriptedModels, pool: VariablePool) async throws -> NodeRunResult {
    let g = try graph([("n", data)])
    let node = try await BuiltinNodeFactory(services: RuntimeServices(models: models)).createNode(g.node("n")!, graph: g)
    let box = Mutex<NodeRunResult?>(nil)
    await NodeRunner.run(node, executionId: "x", context: NodeRunContext(pool: pool, userId: "u")) { e in
        if let r = e.result { box.withLock { $0 = r } }
    }
    return try #require(box.withLock { $0 })
}

func pool(_ values: [([String], JSONValue)]) throws -> VariablePool {
    var p = VariablePool()
    for (s, v) in values { try p.add(s, v) }
    return p
}

@Suite("Runtime question classifier")
struct RuntimeQuestionClassifierTests {
    func qcData(mode: String = "chat", instruction: String = "Be strict about {{#start.topic#}}") -> JSONObject {
        var m = stubModel
        m["mode"] = .string(mode)
        return ["type": "question-classifier", "title": "QC", "model": .object(m), "query_variable_selector": ["start", "q"],
                "classes": [["id": "c1", "name": "Billing"], ["id": "c2", "name": "Tech {{#start.topic#}}", "label": "Tech"]],
                "instruction": .string(instruction)]
    }

    @Test func classifiesFromTheJSONAnswerAndBranches() async throws {
        let models = ScriptedModels(["```json\n{\"keywords\": [\"wifi\"], ", "\"category_id\": \"c2\", \"category_name\": \"Tech\"}\n```"])
        let r = try await runNode(qcData(), models: models, pool: pool([(["start", "q"], "my wifi is down"), (["start", "topic"], "networks")]))
        #expect(r.status == .succeeded, "\(r.error)")
        #expect(r.edgeSourceHandle == "c2")
        #expect(r.outputs["class_id"] == "c2" && r.outputs["class_name"] == "Tech networks" && r.outputs["class_label"] == "Tech")
        #expect(r.inputs["query"] == "my wifi is down" && r.inputs["model_name"] == "stub-chat")
        #expect(r.metadata[MetadataKey.totalTokens] == 14)
        let call = try #require(models.recorded.first)
        #expect(call.stream && call.tools.isEmpty)
        #expect(call.messages.map(\.role) == [.system, .user, .assistant, .user, .assistant, .user])
        #expect(call.messages[0].textContent.hasPrefix("\n### Job Description',\nYou are a text classification engine"))
        #expect(call.messages[0].textContent.hasSuffix("<histories>\n\n</histories>\n"))
        // The categories are JSON (ensure_ascii=False), then the whole text is rendered (the class name's reference too).
        #expect(call.messages[5].textContent == """

                {"input_text": ["my wifi is down"],
                "categories": [{"category_id": "c1", "category_name": "Billing"}, {"category_id": "c2", "category_name": "Tech networks"}],
                "classification_instructions": ["Be strict about networks"]}

            """)
        let prompts = try #require(r.processData["prompts"]?.array)
        #expect(prompts.count == 6 && prompts[2]["role"] == "assistant")
    }

    @Test func unknownCategoryFallsBackToTheFirstClassAndNoJSONFails() async throws {
        let p = try pool([(["start", "q"], "x"), (["start", "topic"], "t")])
        let r = try await runNode(qcData(), models: ScriptedModels(["<think>hmm {\"category_id\": \"c2\"}</think>[{\"category_id\": \"zz\", \"category_name\": \"?\"}]"]), pool: p)
        #expect(r.status == .succeeded && r.edgeSourceHandle == "c1" && r.outputs["class_label"] == "CLASS 1" && r.outputs["class_name"] == "Billing")
        let bad = try await runNode(qcData(), models: ScriptedModels(["I think it is billing"]), pool: p)
        #expect(bad.status == .failed && bad.error == "could not find json block in the output." && bad.errorType == "ValueError")
        #expect(bad.inputs["query"] == "x" && bad.outputs.isEmpty)
        let invalid = try await runNode(qcData(), models: ScriptedModels(["{\"category_id\": }"]), pool: p)
        #expect(invalid.status == .failed && invalid.errorType == "OutputParserError" && invalid.error.hasPrefix("got invalid json object. error:"))
        let failing = try await runNode(qcData(), models: ScriptedModels(failure: ModelInvokeError(errorType: "InvokeRateLimitError", message: "slow down")), pool: p)
        #expect(failing.status == .failed && failing.error == "slow down" && failing.errorType == "InvokeRateLimitError")
    }

    @Test func completionModeIsOneUserMessage() async throws {
        let models = ScriptedModels(["{\"category_id\": \"c1\", \"category_name\": \"Billing\"}"])
        let r = try await runNode(qcData(mode: "completion", instruction: ""), models: models,
                                  pool: pool([(["start", "q"], 42), (["start", "topic"], "t")]))
        #expect(r.status == .succeeded && r.edgeSourceHandle == "c1" && r.inputs["query"] == 42)
        let messages = try #require(models.recorded.first?.messages)
        #expect(messages.count == 1 && messages[0].role == .user)
        let text = messages[0].textContent
        #expect(text.hasPrefix("\n\n### Job Description\n"))
        #expect(text.contains(#"User:{"input_text": ["I recently had"#))
        #expect(text.contains(#"{"input_text" : ["42"], "categories" : [{"category_id": "c1""#))
        #expect(text.hasSuffix("### Assistant Output\n"))
        #expect(r.processData["prompts"] == [["role": "user", "text": .string(text)]])
    }

    @Test func branchesTheGraph() async throws {
        let config = try GraphConfig(json: [
            "nodes": [
                ["id": "start", "data": ["type": "start", "title": "Start", "variables": []]],
                ["id": "qc", "data": .object(qcData())],
                ["id": "a", "data": ["type": "end", "title": "A", "outputs": [["variable": "c", "value_selector": ["qc", "class_name"]]]]],
                ["id": "b", "data": ["type": "end", "title": "B", "outputs": [["variable": "c", "value_selector": ["qc", "class_name"]]]]],
            ],
            "edges": [
                ["source": "start", "target": "qc", "sourceHandle": "source"],
                ["source": "qc", "target": "a", "sourceHandle": "c1"],
                ["source": "qc", "target": "b", "sourceHandle": "c2"],
            ],
        ])
        let models = ScriptedModels(["{\"category_id\": \"c2\", \"category_name\": \"Tech\"}"])
        let g = try await RuntimeGraph.build(config, rootId: "start", factory: BuiltinNodeFactory(services: RuntimeServices(models: models)))
        #expect(g.executionType("qc") == .branch)
        var started: [String] = []
        var outputs = JSONObject()
        for await e in GraphEngine(graph: g).run(pool: try pool([(["start", "q"], "help"), (["start", "topic"], "dns")])) {
            if case .node(.started(_, let n, _, _, _, _)) = e { started.append(n) }
            if case .runSucceeded(let s) = e { outputs = s.outputs }
        }
        #expect(started == ["start", "qc", "b"])
        #expect(outputs == ["c": "Tech dns"])
    }

    @Test func singleRunMapping() throws {
        let node = try QuestionClassifierNode(id: "qc", data: qcData(), instance: ModelInstance(provider: "p", modelName: "m", credentials: [:],
                                                                                                parameters: [:], stop: []),
                                              schema: AIModelEntity(json: [:]), models: ScriptedModels())
        let m = node.variableMapping(graph: try graph([]))
        #expect(m.map(\.key) == ["qc.query", "qc.#start.topic#"] && m[0].selector == ["start", "q"])
    }
}

@Suite("Runtime parameter extractor")
struct RuntimeParameterExtractorTests {
    func peData(mode: String = "chat", reasoning: String = "function_call", parameters: JSONValue? = nil) -> JSONObject {
        var m = stubModel
        m["mode"] = .string(mode)
        return ["type": "parameter-extractor", "title": "PE", "model": .object(m), "query": ["start", "q"],
                "parameters": parameters ?? [
                    ["name": "name", "type": "string", "description": "The person's name", "required": true],
                    ["name": "age", "type": "number", "description": "Âge", "required": false],
                ],
                "instruction": "Context: {{#start.ctx#}}", "reasoning_mode": .string(reasoning)]
    }

    let input: [([String], JSONValue)] = [(["start", "q"], "Ann is 31"), (["start", "ctx"], "people")]

    @Test func functionCallingWithToolCallDeltas() async throws {
        let models = ScriptedModels(["Calling it."], toolCalls: [.init(id: "call_1", name: "extract_parameters", arguments: #"{"name": "Ann", "age": "31"}"#)],
                                    features: ["tool-call"])
        let r = try await runNode(peData(), models: models, pool: pool(input))
        #expect(r.status == .succeeded)
        // "31" is not a number: the reason says so, the value is still normalized.
        #expect(r.outputs["__is_success"] == 0)
        #expect(r.outputs["__reason"] == "Invalid value for parameter age, expected segment type: number, actual_type: string, python_type: <class 'str'>, value: 31")
        #expect(r.outputs["name"] == "Ann" && r.outputs["age"] == 31)
        #expect(r.outputs.keys == ["__is_success", "__reason", "__usage", "name", "age"])
        let call = try #require(models.recorded.first)
        #expect(!call.stream)
        #expect(call.tools.map(\.name) == ["extract_parameters"])
        #expect(call.tools[0].parameters["required"] == ["name"])
        #expect(call.messages.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user, .assistant, .tool, .assistant, .user])
        #expect(call.messages[2].toolCalls.first?.arguments == #"{"location": "San Francisco"}"#)
        #expect(call.messages[2].toolCalls.first?.id.count == 32 && call.messages[3].toolCallId == call.messages[2].toolCalls.first?.id)
        #expect(call.messages[0].textContent.contains("<instruction>\nContext: people\n</instruction>"))
        let user = call.messages[9].textContent
        #expect(user.hasPrefix("extract structured information from context inside <context></context> XML tags"))
        #expect(user.contains("<context>\nAnn is 31\n</context>"))
        // json.dumps with ensure_ascii: "Âge" escaped.
        #expect(user.contains(#""age": {"description": "\u00c2ge", "type": "number"}"#))
        #expect(r.processData["tool_call"] == ["id": "call_1", "type": "function", "function": ["name": "extract_parameters", "arguments": #"{"name": "Ann", "age": "31"}"#]])
        #expect(r.processData["function"]?["name"] == "extract_parameters" && r.processData["llm_text"] == "Calling it.")
        #expect(r.processData.keys == ["model_mode", "prompts", "usage", "function", "tool_call", "model_provider", "model_name", "llm_text"])
        #expect(r.inputs["instruction"] == "Context: {{#start.ctx#}}" && r.inputs["parameters"]?.array?.count == 2)
        #expect(r.metadata[MetadataKey.totalTokens] == 14 && r.llmUsage.totalTokens == 14)
    }

    @Test func promptModeChatParsesTheFirstObject() async throws {
        let models = ScriptedModels(["Sure: {\"name\": \"Bo\", \"age\": 7} done"], features: ["tool-call"])
        let r = try await runNode(peData(reasoning: "prompt"), models: models, pool: pool(input))
        #expect(r.status == .succeeded && r.outputs["__is_success"] == 1 && r.outputs["__reason"] == .null)
        #expect(r.outputs["name"] == "Bo" && r.outputs["age"] == 7)
        let call = try #require(models.recorded.first)
        #expect(call.tools.isEmpty && call.messages.map(\.role) == [.system, .user, .assistant, .user, .assistant, .user])
        #expect(call.messages[2].textContent == #"{"location": "San Francisco"}"#)
        #expect(call.messages[5].textContent.hasPrefix("### Structure\nHere is the structure of the JSON object"))
        #expect(call.messages[5].textContent.hasSuffix("<text>\nAnn is 31\n</text>"))
        #expect(r.processData["function"] == .object([:]) && r.processData["tool_call"] == .null)
    }

    @Test func completionModeAndDefaults() async throws {
        let models = ScriptedModels(["no json here"])
        let r = try await runNode(peData(mode: "completion"), models: models, pool: pool(input))
        #expect(r.status == .succeeded && r.outputs["__is_success"] == 0)
        #expect(r.outputs["__reason"] == "Failed to extract result from function call or text response, using empty result.")
        #expect(r.outputs["name"] == "" && r.outputs["age"] == 0)
        let text = try #require(models.recorded.first?.messages.first?.textContent)
        #expect(text.hasPrefix("\n### Instructions:\n"))
        #expect(text.contains(#"<information to be extracted>"# + "\n" + #"{"type": "object", "properties": {"name""#))
        #expect(text.contains("output structure.\n\n  'properties1'") && !text.contains("γγγ"))
        #expect(text.hasSuffix("```JSON"))
    }

    @Test func validationAndNormalization() async throws {
        let params: JSONValue = [
            ["name": "kind", "type": "select", "options": ["a", "b"], "description": "", "required": true],
            ["name": "flag", "type": "bool", "description": "", "required": true],
            ["name": "tags", "type": "array[string]", "description": "", "required": false],
            ["name": "nums", "type": "array[number]", "description": "", "required": false],
        ]
        let p = try pool(input)
        let bad = try await runNode(peData(reasoning: "prompt", parameters: params),
                                    models: ScriptedModels([#"{"kind": "a", "flag": 1, "tags": ["x", 2], "nums": ["3", 4.5, true]}"#]), pool: p)
        #expect(bad.outputs["__reason"] == "Invalid value for parameter flag, expected segment type: boolean, actual_type: integer, python_type: <class 'int'>, value: 1")
        #expect(bad.outputs["kind"] == "a")
        #expect(bad.outputs["flag"] == true)
        #expect(bad.outputs["tags"] == ["x"])
        #expect(bad.outputs["nums"] == [3, 4.5, 1])
        let select = try await runNode(peData(reasoning: "prompt", parameters: params),
                                       models: ScriptedModels([#"{"kind": "c", "flag": true, "tags": [], "nums": []}"#]), pool: p)
        #expect(select.outputs["__reason"] == "Invalid `select` value for parameter kind")
        let count = try await runNode(peData(reasoning: "prompt", parameters: params), models: ScriptedModels([#"{"kind": "a"}"#]), pool: p)
        #expect(count.outputs["__reason"] == "Invalid number of parameters" && count.outputs["tags"] == [] && count.outputs["flag"] == false)
        #expect(throws: NodeDataError.self) {
            _ = try ParameterExtractorNode(id: "p", data: peData(parameters: [["name": "__reason", "type": "string", "description": "", "required": true]]),
                                           instance: ModelInstance(provider: "p", modelName: "m", credentials: [:], parameters: [:], stop: []),
                                           schema: AIModelEntity(json: [:]), models: ScriptedModels())
        }
    }

    @Test func invokeFailure() async throws {
        let r = try await runNode(peData(), models: ScriptedModels(failure: ModelInvokeError(errorType: "InvokeBadRequestError", message: "nope")),
                                  pool: pool(input))
        #expect(r.status == .failed && r.error == "nope")
        #expect(r.outputs == ["__is_success": 0, "__reason": "Failed to invoke model", "__error": "nope"])
    }
}

@Suite("Runtime LLM structured output and helpers")
struct RuntimeStructuredOutputTests {
    func data(_ extra: JSONObject = [:]) -> JSONObject {
        var e: JSONObject = [
            "structured_output_enabled": true,
            "structured_output": ["schema": ["type": "object", "properties": ["ok": ["type": "boolean"]], "additionalProperties": false]],
        ]
        for (k, v) in extra { e[k] = v }
        return llmData([["role": "system", "text": "Be terse."], ["role": "user", "text": "Who?"]], extra: e)
    }

    @Test func promptBasedSchema() async throws {
        let models = ScriptedModels(["```json\n{\"ok\": ", "true}\n```"], rules: [["name": "response_format", "options": ["JSON", "text"]]])
        let r = try await runNode(data(), models: models, pool: VariablePool())
        #expect(r.status == .succeeded, "\(r.error)")
        #expect(r.outputs["structured_output"] == ["ok": true])
        let call = try #require(models.recorded.first)
        #expect(call.parameters["response_format"] == "JSON")
        #expect(call.messages.map(\.role) == [.system, .user])
        let system = call.messages[0].textContent
        #expect(system.hasPrefix("You’re a helpful AI assistant. You could answer questions and output in JSON format.\n"))
        #expect(system.hasSuffix(#"Here is the JSON schema:"# + "\n" + #"{"type": "object", "properties": {"ok": {"type": "boolean"}}, "additionalProperties": false}"# + "\n\n\nBe terse."))
        // The process data keeps the node's own prompts.
        #expect(r.processData["prompts"]?.array?.first?["text"] == "Be terse.")
    }

    @Test func nativeSchema() async throws {
        let models = ScriptedModels(["{\"ok\": \"yes\"}"], features: ["structured-output"],
                                    rules: [["name": "response_format", "options": ["text", "json_schema"]]])
        let r = try await runNode(data(), models: models, pool: VariablePool())
        #expect(r.outputs["structured_output"] == ["ok": "yes"] && r.outputs["text"] == #"{"ok": "yes"}"#)
        let call = try #require(models.recorded.first)
        #expect(call.parameters["response_format"] == "json_schema")
        #expect(call.parameters["json_schema"] == #"{"schema": {"type": "object", "properties": {"ok": {"type": "string"}}, "additionalProperties": false}, "name": "llm_response"}"#)
        #expect(call.messages.first?.textContent == "Be terse.")
    }

    @Test func badSchemaAndBadAnswer() async throws {
        let bad = try await runNode(data(["structured_output": ["schema": ["a", "b"]]]), models: ScriptedModels(["{}"]), pool: VariablePool())
        #expect(bad.status == .failed && bad.error == "structured_output_schema must be a JSON object")
        let unparsable = try await runNode(data(), models: ScriptedModels(["not json"]), pool: VariablePool())
        #expect(unparsable.status == .failed && unparsable.error == "Failed to parse structured output: Failed to parse structured output: not json")
    }

    @Test func helpers() throws {
        #expect(LLMPrompting.jsonDumpsASCII(["k": "é😀\n"]) == #"{"k": "\u00e9\ud83d\ude00\n"}"#)
        #expect(LLMPrompting.pythonFormat("{{a}} {x} {y}", ["x": "1"]) == "{a} 1 {y}")
        #expect(try LLMPrompting.parseJSONMarkdown("text ```json\n[1, 2]\n``` tail") == [1, 2])
        #expect(try LLMPrompting.parseAndCheckJSONMarkdown("[{\"a\": 1}]", expectedKeys: ["a"]) == ["a": 1])
        #expect(throws: LLMPrompting.ParseError.self) { try LLMPrompting.parseAndCheckJSONMarkdown("{\"a\": 1}", expectedKeys: ["b"]) }
        #expect(LLMPrompting.firstJSONObject("x ] {\"a\": [1, {\"b\": 2}]} y") == ["a": [1, ["b": 2]]])
        #expect(LLMPrompting.extractJSON(ArraySlice(Array("{]"))) == "{")
        var acc = LLMResultAccumulator()
        try acc.consume(LLMResultChunk(model: "m", content: .text("a"), toolCalls: [.init(id: "", type: "", name: "f", arguments: "{")]))
        try acc.consume(LLMResultChunk(model: "m", content: .text("b"), toolCalls: [.init(id: "", type: "", name: "", arguments: "}")]))
        #expect(acc.text == "ab" && acc.toolCalls.count == 1 && acc.toolCalls[0].arguments == "{}" && acc.toolCalls[0].id.hasPrefix("chatcmpl-tool-"))
        let wire = PluginDaemonWire.llmInvokeData(provider: "p", model: "m", credentials: [:], promptMessages: [
            PromptMessage(role: .assistant, content: .text(""), toolCalls: [.init(id: "1", name: "f", arguments: "{}")]),
            PromptMessage(role: .tool, content: .text("ok"), toolCallId: "1"),
        ], parameters: [:], tools: [PromptMessageTool(name: "f", description: "d", parameters: ["type": "object"])], stop: [], stream: false)
        #expect(wire["tools"] == [["name": "f", "description": "d", "parameters": ["type": "object"]]] && wire["stream"] == false)
        #expect(wire["prompt_messages"]?.array?[0]["tool_calls"] == [["id": "1", "type": "function", "function": ["name": "f", "arguments": "{}"]]])
        #expect(wire["prompt_messages"]?.array?[1]["tool_call_id"] == "1")
        let chunk = LLMResultChunk(json: ["model": "m", "delta": ["index": 0, "message": ["content": "", "tool_calls": [
            ["id": 7, "type": "function", "function": ["name": "f", "arguments": "{"]]]]]])
        #expect(chunk.toolCalls.first?.id == "7")
    }
}
