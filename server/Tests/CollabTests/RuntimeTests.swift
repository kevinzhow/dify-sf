import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

/// The runtime's pure parts (protocol 1.13): Python-compatible values, the variable pool, templates, reasoning, the
/// plugin daemon's wire format, the LLM node over a fake model runtime, and the single-step run.
@Suite("Runtime values")
struct RuntimeValueTests {
    @Test func jsonKeepsKeyOrderAndNumberKinds() throws {
        let v = try JSONValue.parse(#"{"b":1,"a":1.0,"c":[true,null,"xé\n"],"b":2}"#)
        #expect(v.object?.keys == ["b", "a", "c"])
        #expect(v["b"] == .int(2) && v["a"] == .double(1.0))
        #expect(v.compactJSON() == #"{"b":2,"a":1.0,"c":[true,null,"xé\n"]}"#)
        // Python's json.dumps(ensure_ascii=False) and its indent=2 form.
        #expect(v.pythonJSONDumps() == #"{"b": 2, "a": 1.0, "c": [true, null, "xé\n"]}"#)
        #expect(JSONValue.object(["k": .array([1, 2])]).pythonJSONDumps(indent: 2) == "{\n  \"k\": [\n    1,\n    2\n  ]\n}")
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{\"a\":}") }
        #expect(try JSONValue.parse(#""😀""#) == .string("😀"))
    }

    @Test func pythonTextForms() {
        #expect(PythonText.floatRepr(1.0) == "1.0")
        #expect(PythonText.floatRepr(0.1) == "0.1")
        #expect(PythonText.floatRepr(1e-05) == "1e-05")
        #expect(PythonText.floatRepr(0.0001) == "0.0001")
        #expect(PythonText.floatRepr(1e16) == "1e+16")
        #expect(PythonText.floatRepr(1e15) == "1000000000000000.0")
        #expect(PythonText.floatRepr(-2.5e-7) == "-2.5e-07")
        #expect(PythonText.floatRepr(123456.789) == "123456.789")
        #expect(PythonText.repr(["a": 1, "b": [true, .null, 1.5, "it's"]]) == #"{'a': 1, 'b': [True, None, 1.5, "it's"]}"#)
        #expect(PythonText.stringRepr("a'b\"c\n") == #"'a\'b"c\n'"#)
    }

    @Test func segmentsAreTypedAndPrintedAsGraphon() {
        #expect(Segment.build([1, 2.5]).valueType == .arrayNumber)
        #expect(Segment.build(["a", 1]).valueType == .arrayAny)
        #expect(Segment.build([]).valueType == .arrayAny)
        #expect(Segment.build([["x": 1]]).valueType == .arrayObject)
        #expect(Segment.build(true).valueType == .boolean)
        #expect(Segment.build(["a", "b"]).text == #"["a", "b"]"#)
        #expect(Segment.build([1, 2.5]).text == "[1, 2.5]")
        #expect(Segment.build([["x": 1]]).text == "[{'x': 1}]")
        #expect(Segment.build(["x": "é", "y": [1]]).text == #"{"x": "é", "y": [1]}"#)
        #expect(Segment.build(true).text == "True")
        #expect(Segment.build(3.0).text == "3.0")
        #expect(Segment.build(.null).text == "")
        #expect(Segment.build([]).text == "")
        #expect(Segment.build(["a", "b"]).markdown == "- a\n- b")
    }

    @Test func variablePoolReadsNestedObjectValues() throws {
        var pool = VariablePool()
        try pool.add(["n", "obj"], ["a": ["b": 1], "s": "x"])
        try pool.add(["n", "text"], "hello")
        #expect(pool.get(["n", "obj", "a", "b"]) == Segment(.integer, 1))
        #expect(pool.get(["n", "obj", "missing"]) == nil)
        #expect(pool.get(["n", "text", "x"]) == nil)
        #expect(pool.get(["n"]) == nil)
        #expect(throws: VariablePool.InvalidSelector.self) { try pool.add(["n", "a", "b"], 1) }
        try pool.add(["n", "text"], "again")
        #expect(pool.values(of: "n").keys == ["obj", "text"] && pool.get(["n", "text"])?.value == "again")
        pool.remove(["n", "obj"])
        #expect(pool.get(["n", "obj"]) == nil)
    }

    @Test func templatesFindReferencesAndRenderThem() throws {
        let t = "Hi {{#start.name#}}, {{#llm.out.a.b#}} {{#bad#}} {{#start.name#}} {{#x.1bad#}}"
        #expect(VariableTemplate.extractSelectors(t).map(\.variable) == ["#start.name#", "#llm.out.a.b#"])
        #expect(VariableTemplate.extractSelectors(t).last?.valueSelector == ["llm", "out", "a", "b"])
        var pool = VariablePool()
        try pool.add(["start", "name"], "Ann")
        try pool.add(["sys", "query"], "q?")
        #expect(VariableTemplate.convert(pool, "Hi {{#start.name#}}! {{#start.missing#}}").text == "Hi Ann! start.missing")
        // graphon looks up every part with a dot, text parts too.
        #expect(VariableTemplate.convert(pool, "{{#start.name#}}sys.query").text == "Annq?")
        #expect(VariableTemplate.convert(pool, "{{#a" + String(repeating: "x", count: 51) + ".b#}}").text == "{{#a" + String(repeating: "x", count: 51) + ".b#}}")
    }

    @Test func reasoningIsSeparatedFromTheAnswer() {
        let (clean, reasoning) = Reasoning.split("<think>\nplan A\n</think>\n\nAnswer\n\n\n here", format: "separated")
        #expect(clean == "Answer\n\n here" && reasoning == "plan A")
        #expect(Reasoning.split("<think>x</think>y", format: "tagged") == ("<think>x</think>y", ""))
        #expect(Reasoning.split("ok <THINK a=1>unfinished", format: "separated") == ("ok", "unfinished"))
        var f = ThinkStreamFilter()
        var pieces: [ThinkStreamFilter.Piece] = []
        for part in ["<thi", "nk>pla", "n</th", "ink>  Ans", "wer <", "b>"] { pieces += f.feed(part) }
        pieces += f.finalize()
        #expect(pieces == [.reasoning("pla"), .reasoning("n"), .text("Ans"), .text("wer "), .text("<b>")])
    }

    @Test func pluginDaemonLines() throws {
        #expect(try PluginDaemonWire.decodeLine("") == nil)
        #expect(try PluginDaemonWire.decodeLine(#"data: {"code":0,"message":"","data":{"x":1}}"#) == ["x": 1])
        let invoke = #"{"error_type":"InvokeAuthorizationError","message":"bad key"}"#
        let outer = JSONValue.object(["error_type": "PluginInvokeError", "message": .string(invoke)]).compactJSON()
        let line = JSONValue.object(["code": -500, "message": .string(outer), "data": .null]).compactJSON()
        #expect {
            try PluginDaemonWire.decodeLine(line)
        } throws: { e in
            (e as? ModelInvokeError).map { $0.errorType == "InvokeAuthorizationError" && $0.message == "bad key" } ?? false
        }
        #expect {
            try PluginDaemonWire.decodeLine(#"{"code":-404,"message":"plugin not found","data":null}"#)
        } throws: { e in "\(e)" == "plugin daemon: plugin not found, code: -404" }
        let body = PluginDaemonWire.dispatchBody(userId: "u", appId: nil, data: PluginDaemonWire.llmInvokeData(
            provider: "openai_api_compatible", model: "m", credentials: ["api_key": "k"],
            promptMessages: [PromptMessage(role: .user, content: .text("hi"))], parameters: ["temperature": 0.2], stop: []))
        #expect(body.compactJSON() == #"{"data":{"provider":"openai_api_compatible","model_type":"llm","model":"m","credentials":{"api_key":"k"},"#
            + #""prompt_messages":[{"role":"user","content":"hi","name":null}],"model_parameters":{"temperature":0.2},"tools":null,"#
            + #""stop":null,"stream":true},"user_id":"u"}"#)
    }
}

/// A model runtime that answers from a script: the prompt it got is recorded, the answer comes as the given chunks.
final class FakeModels: ModelRuntime, Sendable {
    struct Call: Sendable {
        var instance: ModelInstance
        var messages: [PromptMessage]
        var parameters: JSONObject
        var stop: [String]
        var user: String?
    }
    let chunks: [String]
    let failure: (any Error)?
    let credentialsFailure: (any Error)?
    let usage: LLMUsage
    private let calls = Mutex<[Call]>([])

    init(chunks: [String] = ["Hello", " world"], failure: (any Error)? = nil, credentialsFailure: (any Error)? = nil) {
        self.chunks = chunks
        self.failure = failure
        self.credentialsFailure = credentialsFailure
        var u = LLMUsage()
        u.promptTokens = 7
        u.completionTokens = 2
        u.totalTokens = 9
        u.totalPrice = DecimalText("0.000009")
        usage = u
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func credentials(provider: String, model: String, modelType: String) async throws -> JSONObject {
        if let credentialsFailure { throw credentialsFailure }
        return ["api_key": "sk-test"]
    }

    func modelSchema(provider: String, model: String, modelType: String, credentials: JSONObject) async throws -> AIModelEntity? {
        AIModelEntity(json: ["model": .string(model), "features": [], "model_properties": ["mode": "chat"]])
    }

    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, stop: [String],
                   user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        calls.withLock { $0.append(Call(instance: instance, messages: promptMessages, parameters: parameters, stop: stop, user: user)) }
        let (s, c) = AsyncThrowingStream<LLMResultChunk, any Error>.makeStream()
        for t in chunks { c.yield(LLMResultChunk(model: instance.modelName, content: .text(t))) }
        if let failure { c.finish(throwing: failure); return s }
        c.yield(LLMResultChunk(model: instance.modelName, content: .text(""), usage: usage, finishReason: "stop"))
        c.finish()
        return s
    }
}

/// An LLM node's data as Dify's editor writes it.
func llmData(_ prompts: JSONValue, mode: String = "chat", extra: JSONObject = [:]) -> JSONObject {
    var d: JSONObject = [
        "type": "llm", "title": "LLM", "desc": "",
        "model": ["provider": "langgenius/openai_api_compatible/openai_api_compatible", "name": "stub-chat", "mode": .string(mode),
                  "completion_params": ["temperature": 0.7, "stop": ["END"]]],
        "prompt_template": prompts,
        "context": ["enabled": false, "variable_selector": []],
        "vision": ["enabled": false],
    ]
    for (k, v) in extra { d[k] = v }
    return d
}

func graph(_ nodes: [(String, JSONObject)]) throws -> GraphConfig {
    try GraphConfig(json: ["nodes": .array(nodes.map { ["id": .string($0.0), "data": .object($0.1)] }), "edges": []])
}

@Suite("Runtime LLM node and single-step run")
struct RuntimeLLMTests {
    func run(_ data: JSONObject, inputs: JSONObject = [:], models: FakeModels = FakeModels(), env: [JSONValue] = []) async throws -> (NodeExecution, [GraphNodeEvent]) {
        let g = try graph([("llm", data)])
        let events = Mutex<[GraphNodeEvent]>([])
        let run = SingleStepRun(graph: g, environmentVariables: env, factory: BuiltinNodeFactory(models: models))
        let e = try await run.run(nodeId: "llm", userInputs: inputs, userId: "acc-1", appId: "app-1") { ev in events.withLock { $0.append(ev) } }
        return (e, events.withLock { $0 })
    }

    @Test func chatPromptFromTemplatesAndUserInputs() async throws {
        let models = FakeModels()
        let data = llmData([
            ["role": "system", "text": "You answer {{#env.tone#}}.", "edition_type": "basic"],
            ["role": "user", "text": "Q: {{#start.query#}} ({{#start.n#}})"],
            ["role": "assistant", "text": "{{#start.empty#}}"],
        ])
        let (e, events) = try await run(data, inputs: ["#start.query#": "why?", "llm.#start.n#": 2.0, "#start.empty#": ""],
                                        models: models, env: [["name": "tone", "value": "briefly", "value_type": "string"]])
        #expect(e.status == .succeeded, "\(e.error ?? "")")
        let call = try #require(models.recorded.first)
        #expect(call.messages.map(\.role) == [.system, .user])
        #expect(call.messages.map(\.textContent) == ["You answer briefly.", "Q: why? (2.0)"])
        #expect(call.parameters == ["temperature": 0.7] && call.stop == ["END"] && call.user == "acc-1")
        #expect(call.instance.credentials == ["api_key": "sk-test"])
        #expect(e.outputs?["text"] == "Hello world" && e.outputs?["finish_reason"] == "stop" && e.outputs?["reasoning_content"] == "")
        #expect(e.outputs?.keys == ["text", "reasoning_content", "usage", "finish_reason"])
        #expect(e.outputs?["usage"]?["total_tokens"] == 9 && e.outputs?["usage"]?["total_price"] == "0.000009")
        #expect(e.inputs == ["model_provider": "langgenius/openai_api_compatible/openai_api_compatible", "model_name": "stub-chat"])
        #expect(e.processData?.keys == ["model_mode", "prompts", "usage", "finish_reason", "model_provider", "model_name"])
        #expect(e.processData?["prompts"] == [["role": "system", "text": "You answer briefly.", "files": []],
                                              ["role": "user", "text": "Q: why? (2.0)", "files": []]])
        #expect(e.metadata == ["total_tokens": 9, "total_price": "0.000009", "currency": "USD"])
        let chunks: [String] = events.compactMap { if case .streamChunk(_, _, _, let c, _) = $0 { return c }; return nil }
        #expect(chunks == ["Hello", " world", "", ""])
        if case .started? = events.first {} else { Issue.record("no started event") }
        if case .succeeded? = events.last {} else { Issue.record("no succeeded event") }
        let json = e.responseJSON(createdByAccount: ["id": "acc-1", "name": "A", "email": "a@x"])
        #expect(json.object?.keys == ["id", "index", "predecessor_node_id", "node_id", "node_type", "title", "inputs", "process_data",
                                      "outputs", "status", "error", "elapsed_time", "execution_metadata", "extras", "created_at",
                                      "created_by_role", "created_by_account", "created_by_end_user", "finished_at", "inputs_truncated",
                                      "outputs_truncated", "process_data_truncated"])
    }

    @Test func completionModeAndContext() async throws {
        let models = FakeModels()
        let data = llmData(["text": "Context: {{#context#}}\nQ: {{#start.q#}}", "edition_type": "basic"], mode: "completion",
                           extra: ["context": ["enabled": true, "variable_selector": ["kr", "result"]]])
        let chunks: JSONValue = [["content": "chunk one", "metadata": ["_source": "knowledge", "position": 1, "dataset_id": "d"]], "plain"]
        let (e, events) = try await run(data, inputs: ["#start.q#": "x", "#context#": chunks], models: models)
        #expect(e.status == .succeeded, "\(e.error ?? "")")
        // _merge_completion_memory without memory prepends "\n".
        #expect(models.recorded.first?.messages.map(\.textContent) == ["\nContext: chunk one\nplain\nQ: x"])
        #expect(e.inputs?["#context#"] == "chunk one\nplain")
        #expect(e.processData?["prompts"] == [["role": "user", "text": "\nContext: chunk one\nplain\nQ: x"]])
        let resources = events.compactMap { if case .retrieverResource(_, _, let r, _) = $0 { return r }; return nil }
        #expect(resources.first?.first?["dataset_id"] == "d")
    }

    @Test func failuresAreFailedExecutions() async throws {
        // A missing variable (no input, nothing in the pool): Dify's mapping error before the node runs.
        await #expect(throws: SingleStepRun.InvalidInput.self) {
            _ = try await run(llmData([["role": "user", "text": "{{#start.q#}}"]]))
        }
        // The model fails mid-stream: failed, with the model's error type and the inputs so far.
        let failing = FakeModels(chunks: ["partial"], failure: ModelInvokeError(errorType: "InvokeRateLimitError", message: "slow down"))
        let (e, _) = try await run(llmData([["role": "user", "text": "hi"]]), models: failing)
        #expect(e.status == .failed && e.error == "slow down" && e.inputs == nil && e.outputs == nil)
        // Nothing to say: NoPromptFoundError.
        let (empty, _) = try await run(llmData([["role": "user", "text": "{{#start.q#}}"]]), inputs: ["#start.q#": ""])
        #expect(empty.status == .failed && empty.error?.hasPrefix("No prompt found in the LLM configuration.") == true)
        // Jinja2 prompts need a renderer (the sandbox, a later phase).
        let (jinja, _) = try await run(llmData([["role": "user", "text": "", "edition_type": "jinja2", "jinja2_text": "{{ x }}"]]))
        #expect(jinja.error == "LLMNode requires an injected jinja2_template_renderer for jinja2 prompts.")
        // The model's credentials: Dify raises these out of the request.
        await #expect(throws: NodeError.self) {
            _ = try await run(llmData([["role": "user", "text": "hi"]]),
                              models: FakeModels(credentialsFailure: NodeError("ValueError", "Model is not configured")))
        }
    }

    @Test func errorStrategyDefaultValue() async throws {
        let failing = FakeModels(chunks: [], failure: ModelInvokeError(errorType: "InvokeServerUnavailableError", message: "down"))
        let data = llmData([["role": "user", "text": "hi"]], extra: [
            "error_strategy": "default-value",
            "default_value": [["key": "text", "type": "string", "value": "fallback"]],
        ])
        let (e, _) = try await run(data, models: failing)
        #expect(e.status == .exception && e.error == "down")
        #expect(e.outputs == ["error_message": "down", "error_type": "InvokeServerUnavailableError", "text": "fallback"])
        #expect(e.metadata == ["error_strategy": "default-value"])
    }

    @Test func separatedReasoningAndParamVariables() async throws {
        let models = FakeModels(chunks: ["<think>pl", "an</think>", "Done"])
        // A completion param may reference a value; single runs only have the values the node's prompts reference.
        let data = llmData([["role": "user", "text": "go {{#start.t#}}"]], extra: ["reasoning_format": "separated"])
        var d = data
        d["model"] = ["provider": "openai", "name": "gpt-4o", "mode": "chat", "completion_params": ["temperature": "{{#start.t#}}"]]
        let (e, events) = try await run(d, inputs: ["#start.t#": "0.3"], models: models)
        #expect(e.outputs?["text"] == "Done" && e.outputs?["reasoning_content"] == "plan")
        #expect(models.recorded.first?.parameters == ["temperature": 0.3])
        let reasoning: [String] = events.compactMap { if case .reasoningChunk(_, _, _, let c, _) = $0 { return c }; return nil }
        #expect(reasoning.joined() == "plan")
    }

    @Test func unsupportedNodesAndStructuredOutput() async throws {
        let g = try graph([("code", ["type": "tool", "title": "Code"]), ("llm", llmData([["role": "user", "text": "hi"]], extra: [
            "structured_output_enabled": true, "structured_output": ["schema": ["type": "object"]],
        ]))])
        let run = SingleStepRun(graph: g, environmentVariables: [], factory: BuiltinNodeFactory(models: FakeModels()))
        await #expect(throws: UnsupportedNodeType.self) { _ = try await run.run(nodeId: "code", userInputs: [:], userId: nil, appId: nil) }
        await #expect(throws: SingleStepRun.NodeNotFound.self) { _ = try await run.run(nodeId: "nope", userInputs: [:], userId: nil, appId: nil) }
        let e = try await run.run(nodeId: "llm", userInputs: [:], userId: nil, appId: nil)
        // Structured output (prompt-based for a model without the feature): "Hello world" is no JSON object.
        #expect(e.status == .failed && e.error == "Failed to parse structured output: Failed to parse structured output: Hello world")
    }
}
