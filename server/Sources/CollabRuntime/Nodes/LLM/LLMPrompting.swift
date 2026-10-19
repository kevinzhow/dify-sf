// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/llm/llm_utils.py
// (handle_list_messages, handle_completion_template, _filter_prompt_messages for basic templates),
// graphon/utils/json_in_md_parser.py, graphon/nodes/parameter_extractor/parameter_extractor_node.py (extract_json);
// Dify 1.17.1 (Apache-2.0 with Dify's conditions, https://github.com/langgenius/dify):
// api/core/llm_generator/output_parser/structured_output.py, api/core/llm_generator/prompts.py
// (STRUCTURED_OUTPUT_PROMPT). See ../../NOTICE.md.
//
// Shared by the LLM-backed nodes (question classifier, parameter extractor) and the LLM node's structured output.
// Not ported: `json_repair` (a malformed structured output is repaired only by taking the first complete JSON object
// in the text, after code fences).

import Foundation

public enum LLMPrompting {
    // MARK: - Prompt messages from basic templates (fetch_prompt_messages without memory, files or Jinja2)

    /// `handle_list_messages` for basic templates: `{{#context#}}` -> `context`, references rendered, empty texts dropped.
    static func listMessages(_ templates: [(role: PromptMessageRole, text: String)], context: String = "", pool: VariablePool) throws
        -> [PromptMessage]
    {
        var out: [PromptMessage] = []
        for t in templates {
            let text = VariableTemplate.convert(pool, t.text.replacingOccurrences(of: LLMNode.contextPlaceholder, with: context)).text
            if text.isEmpty { continue }
            out.append(try LLMNode.message(t.role, .parts([.text(text)])))
        }
        return out
    }

    /// `handle_completion_template` + `_merge_completion_memory` without memory: the text with an empty history before it.
    static func completionMessages(_ text: String, context: String = "", pool: VariablePool) -> [PromptMessage] {
        var data = VariableTemplate.convert(pool, text.replacingOccurrences(of: LLMNode.contextPlaceholder, with: context)).text
        data = data.contains("#histories#") ? data.replacingOccurrences(of: "#histories#", with: "") : "\n" + data
        return [PromptMessage(role: .user, content: .parts([.text(data)]))]
    }

    /// `_filter_prompt_messages`: parts the model cannot take dropped, a single text part becomes plain text, empty
    /// messages dropped; none left fails.
    static func filter(_ messages: [PromptMessage], schema: AIModelEntity) throws -> [PromptMessage] {
        var out: [PromptMessage] = []
        for var m in messages {
            if case .parts(let ps) = m.content {
                let kept = ps.filter { schema.supports(contentType: $0.type) }
                if kept.isEmpty { continue }
                if kept.count == 1, case .text(let s) = kept[0] { m.content = .text(s) } else { m.content = .parts(kept) }
                out.append(m)
            } else if !m.isEmpty {
                out.append(m)
            }
        }
        if out.isEmpty {
            throw NodeError("NoPromptFoundError",
                            "No prompt found in the LLM configuration. Please ensure a prompt is properly configured before proceeding.")
        }
        return out
    }

    // MARK: - Python text forms

    /// `json.dumps(value)` (Python's defaults: `ensure_ascii=True`, separators `", "` and `": "`).
    public static func jsonDumpsASCII(_ v: JSONValue) -> String {
        var out = ""
        for u in v.pythonJSONDumps().unicodeScalars {
            if u.value < 0x80 { out.unicodeScalars.append(u); continue }
            func hex(_ x: UInt32) -> String { let h = String(x, radix: 16); return "\\u" + String(repeating: "0", count: 4 - h.count) + h }
            if u.value > 0xFFFF {
                let x = u.value - 0x10000
                out += hex(0xD800 + (x >> 10)) + hex(0xDC00 + (x & 0x3FF))
            } else {
                out += hex(u.value)
            }
        }
        return out
    }

    /// `str.format(**values)` for the prompt constants: `{name}` replaced, `{{` / `}}` become `{` / `}`.
    static func pythonFormat(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if c == "{", next < template.endIndex, template[next] == "{" { out.append("{"); i = template.index(after: next); continue }
            if c == "}", next < template.endIndex, template[next] == "}" { out.append("}"); i = template.index(after: next); continue }
            if c == "{", let close = template[next...].firstIndex(of: "}") {
                let name = String(template[next..<close])
                if let v = values[name] { out += v; i = template.index(after: close); continue }
            }
            out.append(c)
            i = next
        }
        return out
    }

    // MARK: - JSON in model answers

    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public var errorType: String
        public var description: String
    }

    /// `parse_json_markdown`: the first JSON object or array of a text (inside code fences or bare).
    public static func parseJSONMarkdown(_ text: String) throws -> JSONValue {
        let s = text.pythonStrip()
        var start: String.Index?
        for marker in ["```json", "```", "``", "`", "{", "["] {
            if let r = s.range(of: marker) {
                start = (s[r.lowerBound] == "{" || s[r.lowerBound] == "[") ? r.lowerBound : r.upperBound
                break
            }
        }
        var end: String.Index?
        if let start {
            for marker in ["```", "``", "`", "}", "]"] {
                if let r = s.range(of: marker, options: .backwards, range: start..<s.endIndex) {
                    end = (s[r.lowerBound] == "}" || s[r.lowerBound] == "]") ? r.upperBound : r.lowerBound
                    break
                }
            }
        }
        guard let start, let end, start < end else {
            throw ParseError(errorType: "ValueError", description: "could not find json block in the output.")
        }
        do {
            return try JSONValue.parse(String(s[start..<end]).pythonStrip())
        } catch {
            throw ParseError(errorType: "OutputParserError", description: "got invalid json object. error: \(error)")
        }
    }

    /// `parse_and_check_json_markdown`: an object (a one-object array is unwrapped) with the expected keys.
    public static func parseAndCheckJSONMarkdown(_ text: String, expectedKeys: [String]) throws -> JSONObject {
        var obj = try parseJSONMarkdown(text)
        if case .array(let a) = obj {
            guard a.count == 1, case .object = a[0] else {
                throw ParseError(errorType: "OutputParserError", description: "got invalid return object. obj:\(PythonText.str(obj))")
            }
            obj = a[0]
        }
        guard case .object(let o) = obj else {
            throw ParseError(errorType: "OutputParserError", description: "got invalid return object. obj:\(PythonText.str(obj))")
        }
        for k in expectedKeys where o[k] == nil {
            throw ParseError(errorType: "OutputParserError",
                             description: "got invalid return object. expected key `\(k)` to be present, but got \(PythonText.str(obj))")
        }
        return o
    }

    /// `extract_json`: from a text starting with `{` or `[`, the balanced JSON prefix (or the text up to a bad closer).
    static func extractJSON(_ chars: ArraySlice<Character>) -> String? {
        var stack: [Character] = []
        for (n, c) in chars.enumerated() {
            if c == "{" || c == "[" { stack.append(c) }
            else if c == "}" || c == "]" {
                guard let last = stack.last else { return String(chars.prefix(n)) }
                if (c == "}" && last == "{") || (c == "]" && last == "[") {
                    stack.removeLast()
                    if stack.isEmpty { return String(chars.prefix(n + 1)) }
                } else {
                    return String(chars.prefix(n))
                }
            }
        }
        return nil
    }

    /// `_extract_complete_json_response`: the first JSON object found from any `{` / `[` of the text.
    static func firstJSONObject(_ text: String) -> JSONObject? {
        let chars = Array(text)
        for i in chars.indices where chars[i] == "{" || chars[i] == "[" {
            if let s = extractJSON(chars[i...]), !s.isEmpty, case .object(let o)? = try? JSONValue.parse(s) { return o }
        }
        return nil
    }

    // MARK: - Structured output (Dify's invoke_llm_with_structured_output)

    static let structuredOutputPrompt = """
        You’re a helpful AI assistant. You could answer questions and output in JSON format.
        constraints:
            - You must output in JSON format.
            - Do not output boolean value, use string type instead.
            - Do not output integer or float value, use number type instead.
        eg:
            Here is the JSON schema:
            {"additionalProperties": false, "properties": {"age": {"type": "number"}, "name": {"type": "string"}}, "required": ["name", "age"], "type": "object"}

            Here is the user's question:
            My name is John Doe and I am 30 years old.

            output:
            {"name": "John Doe", "age": 30}
        Here is the JSON schema:
        {{schema}}

        """

    /// `fetch_structured_output_schema`.
    static func structuredOutputSchema(_ structuredOutput: JSONObject?) throws -> JSONObject {
        guard let so = structuredOutput, !so.isEmpty else { throw NodeError("LLMNodeError", "Please provide a valid structured output schema") }
        guard case .object(let schema) = so["schema"] ?? .object([:]) else {
            throw NodeError("LLMNodeError", "structured_output_schema must be a JSON object")
        }
        return schema
    }

    /// The request changes for structured output: the native JSON schema parameter (and `response_format`) for models with
    /// the `structured-output` feature, else a JSON `response_format` when offered and the schema prompt as the system
    /// message.
    static func applyStructuredOutput(schema: JSONObject, model: AIModelEntity, provider: String, parameters: JSONObject,
                                      messages: [PromptMessage]) -> (JSONObject, [PromptMessage]) {
        var params = parameters
        var messages = messages
        func options(_ rule: JSONValue) -> [String] { (rule["options"]?.array ?? []).compactMap(\.string) }
        if model.supportsStructuredOutput {
            var processed = convertBooleanToString(.object(schema))
            let prepared: JSONValue
            if model.model.contains("gemini") {
                processed = removeAdditionalProperties(processed)
                prepared = processed
            } else if provider.contains("ollama") {
                prepared = processed
            } else {
                prepared = ["schema": processed, "name": "llm_response"]
            }
            params["json_schema"] = .string(prepared.pythonJSONDumps())
            for rule in model.parameterRules where rule["name"]?.string == "response_format" && options(rule).contains("json_schema") {
                params["response_format"] = "json_schema"
            }
        } else {
            for rule in model.parameterRules where rule["name"]?.string == "response_format" {
                if options(rule).contains("JSON") { params["response_format"] = "JSON" }
                else if options(rule).contains("json_object") { params["response_format"] = "json_object" }
            }
            let prompt = structuredOutputPrompt.replacingOccurrences(of: "{{schema}}", with: JSONValue.object(schema).pythonJSONDumps())
            var content = prompt
            if let system = messages.first(where: { $0.role == .system }), case .text(let s) = system.content { content = prompt + "\n\n" + s }
            messages = [PromptMessage(role: .system, content: .text(content))] + messages.filter { $0.role != .system }
        }
        return (params, messages)
    }

    static func convertBooleanToString(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(var o):
            if o["type"] == "boolean" { o["type"] = "string" }
            var out = JSONObject()
            for (k, x) in o { out[k] = (x.object != nil || x.array != nil) ? convertBooleanToString(x) : x }
            return .object(out)
        case .array(let a): return .array(a.map { $0.object != nil ? convertBooleanToString($0) : $0 })
        default: return v
        }
    }

    static func removeAdditionalProperties(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(var o):
            o["additionalProperties"] = nil
            var out = JSONObject()
            for (k, x) in o { out[k] = (x.object != nil || x.array != nil) ? removeAdditionalProperties(x) : x }
            return .object(out)
        case .array(let a): return .array(a.map { $0.object != nil ? removeAdditionalProperties($0) : $0 })
        default: return v
        }
    }

    /// `_parse_structured_output`: a JSON object, else the first object of a repaired text.
    static func parseStructuredOutput(_ text: String) throws -> JSONObject {
        if case .object(let o)? = try? JSONValue.parse(text) { return o }
        var t = text.pythonStrip()
        if let r = t.range(of: "```json") ?? t.range(of: "```") {
            t = String(t[r.upperBound...])
            if let e = t.range(of: "```", options: .backwards) { t = String(t[..<e.lowerBound]) }
        }
        if case .object(let o)? = try? JSONValue.parse(t.pythonStrip()) { return o }
        if let o = firstJSONObject(t) { return o }
        throw NodeError("LLMNodeError", "Failed to parse structured output: Failed to parse structured output: \(text)")
    }

    // MARK: - Invocation

    /// A whole answer (`invoke_llm(..., stream=False)` or a stream read to its end without events).
    static func invokeCollect(_ models: any ModelRuntime, _ instance: ModelInstance, messages: [PromptMessage], tools: [PromptMessageTool] = [],
                              stream: Bool, user: String?) async throws -> LLMResultAccumulator {
        let start = ContinuousClock.now
        var acc = LLMResultAccumulator()
        var firstToken: ContinuousClock.Instant?
        for try await chunk in models.invokeLLM(instance, promptMessages: messages, parameters: instance.parameters, tools: tools,
                                                stop: instance.stop, stream: stream, user: user) {
            let before = acc.text.count
            try acc.consume(chunk)
            if firstToken == nil, acc.text.count > before { firstToken = ContinuousClock.now }
        }
        let end = ContinuousClock.now
        acc.usage.latency = LLMNode.round3(LLMNode.seconds(end - start))
        if stream, let firstToken {
            acc.usage.timeToFirstToken = LLMNode.round3(LLMNode.seconds(firstToken - start))
            acc.usage.timeToGenerate = LLMNode.round3(LLMNode.seconds(end - firstToken))
        }
        return acc
    }

    /// `ModelConfig` from node data (`model`: provider, name, mode, completion_params).
    static func model(_ data: JSONObject) throws -> LLMNodeData.Model {
        guard let m = data["model"]?.object else { throw NodeDataError("model: Field required") }
        guard let provider = m["provider"]?.string, let name = m["name"]?.string else { throw NodeDataError("model: provider and name are required") }
        guard let mode = m["mode"]?.string, mode == "chat" || mode == "completion" else {
            throw NodeDataError("model.mode: Input should be 'completion' or 'chat'")
        }
        return LLMNodeData.Model(provider: provider, name: name, mode: mode, completionParams: m["completion_params"]?.object ?? JSONObject())
    }

    static func usageMetadata(_ usage: LLMUsage) -> JSONObject {
        [MetadataKey.totalTokens: .int(usage.totalTokens), MetadataKey.totalPrice: .string(usage.totalPrice.text),
         MetadataKey.currency: .string(usage.currency)]
    }
}
