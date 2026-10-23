// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/nodes/parameter_extractor/parameter_extractor_node.py, entities.py, exc.py, prompts.py,
// graphon/variables/types.py (SegmentType.is_valid, infer_segment_type). See ../../NOTICE.md.
//
// Vision attachments in extractor prompts remain outside this port. Conversation memory and its token reserve
// follow the pinned extractor's `_calculate_rest_token`.

import Foundation

/// The parameter extractor: asks the model for a JSON object of the configured parameters (by function calling when the
/// model can call tools and `reasoning_mode` is `function_call`, else by prompt) and outputs them, validated and
/// normalized, with `__is_success`, `__reason` and `__usage`.
public struct ParameterExtractorNode: RuntimeNode {
    public struct Parameter: Sendable {
        public var name: String
        /// After the legacy names: `select` -> `string`, `bool` -> `boolean`.
        public var type: SegmentType
        public var options: [String]?
        public var description: String
        public var required: Bool

        var json: JSONValue {
            ["name": .string(name), "type": .string(type.rawValue), "options": options.map { .array($0.map(JSONValue.string)) } ?? .null,
             "description": .string(description), "required": .bool(required)]
        }

        /// `_build_parameter_schema`.
        var schema: JSONValue {
            var o: JSONObject = ["description": .string(description)]
            if type == .string {
                o["type"] = "string"
            } else if type.isArray {
                o["type"] = "array"
                o["items"] = ["type": .string(ParameterExtractorNode.elementType(type)?.rawValue ?? "")]
            } else {
                o["type"] = .string(type.rawValue)
            }
            if let options, !options.isEmpty { o["enum"] = .array(options.map(JSONValue.string)) }
            return .object(o)
        }
    }

    public let id: String
    public let base: BaseNodeData
    public let model: LLMNodeData.Model
    public let querySelector: [String]
    public let parameters: [Parameter]
    public let instruction: String?
    public let reasoningMode: String
    public let visionEnabled: Bool
    let instance: ModelInstance
    let schema: AIModelEntity
    let models: any ModelRuntime
    let files: (any RuntimeFiles)?
    let memory: (any ConversationMemory)?
    let memoryConfig: LLMNodeData.Memory?

    public var nodeType: String { NodeType.parameterExtractor }

    static let validTypes: [String: SegmentType] = [
        "string": .string, "number": .number, "boolean": .boolean, "array[string]": .arrayString, "array[number]": .arrayNumber,
        "array[object]": .arrayObject, "array[boolean]": .arrayBoolean, "bool": .boolean, "select": .string,
    ]

    public init(id: String, data: JSONObject, instance: ModelInstance, schema: AIModelEntity, models: any ModelRuntime, memory: (any ConversationMemory)? = nil, files: (any RuntimeFiles)? = nil) throws {
        self.id = id
        base = try BaseNodeData(data)
        model = try LLMPrompting.model(data)
        guard let q = data["query"]?.array else { throw NodeDataError("query: Field required") }
        querySelector = q.map { PythonText.str($0) }
        guard let ps = data["parameters"]?.array else { throw NodeDataError("parameters: Field required") }
        parameters = try ps.map { p in
            guard let rawName = p["name"], rawName.isTruthy else { throw NodeDataError("parameters.name: Parameter name is required") }
            let name = PythonText.str(rawName)
            if name == "__reason" || name == "__is_success" {
                throw NodeDataError("parameters.name: Invalid parameter name, __reason and __is_success are reserved")
            }
            guard let t = p["type"]?.string, let type = Self.validTypes[t] else {
                throw NodeDataError("parameters.type: type \(p["type"].map { PythonText.str($0) } ?? "None") is not allowd to use in Parameter Extractor node.")
            }
            guard let description = p["description"]?.string else { throw NodeDataError("parameters.description: Field required") }
            guard let required = p["required"]?.bool else { throw NodeDataError("parameters.required: Field required") }
            return Parameter(name: name, type: type, options: p["options"]?.array?.compactMap(\.string), description: description,
                             required: required)
        }
        instruction = data["instruction"]?.string
        let mode = data["reasoning_mode"]?.string ?? ""
        let resolved = mode.isEmpty ? "function_call" : mode
        guard resolved == "function_call" || resolved == "prompt" else {
            throw NodeDataError("reasoning_mode: Input should be 'function_call' or 'prompt'")
        }
        reasoningMode = resolved
        visionEnabled = data["vision"]?["enabled"]?.bool ?? false
        self.instance = instance
        self.schema = schema
        self.models = models
        self.files = files
        self.memory = memory
        self.memoryConfig = ConversationPromptMemory.config(data["memory"])
    }

    /// `get_parameter_json_schema`.
    var parameterSchema: JSONValue {
        var properties = JSONObject()
        for p in parameters { properties[p.name] = p.schema }
        return ["type": "object", "properties": .object(properties), "required": .array(parameters.filter(\.required).map { .string($0.name) })]
    }

    static func elementType(_ t: SegmentType) -> SegmentType? {
        switch t {
        case .arrayString: return .string
        case .arrayNumber: return .number
        case .arrayObject: return .object
        case .arrayBoolean: return .boolean
        default: return nil
        }
    }

    // MARK: - Prompts (prompts.py)

    static let functionName = "extract_parameters"

    static let functionCallingSystemPrompt = """
        You are a helpful assistant tasked with extracting structured information based on specific criteria provided. Follow the guidelines below to ensure consistency and accuracy.
        ### Task
        Always call the `extract_parameters` function with the correct parameters. Ensure that the information extraction is contextual and aligns with the provided criteria.
        ### Memory
        Here is the chat history between the human and assistant, provided within <histories> tags:
        <histories>
        {histories}
        </histories>
        ### Instructions:
        Some additional information is provided below. Always adhere to these instructions as closely as possible:
        <instruction>
        {instruction}
        </instruction>
        Steps:
        1. Review the chat history provided within the <histories> tags.
        2. Extract the relevant information based on the criteria given, output multiple values if there is multiple relevant information that match the criteria in the given text.
        3. Generate a well-formatted output using the defined functions and arguments.
        4. Use the `extract_parameters` function to create structured outputs with appropriate parameters.
        5. Do not include any XML tags in your output.
        ### Example
        To illustrate, if the task involves extracting a user's name and their request, your function call might look like this: Ensure your output follows a similar structure to examples.
        ### Final Output
        Produce well-formatted function calls in json without XML tags, as shown in the example.
        """

    static let functionCallingUserTemplate = """
        extract structured information from context inside <context></context> XML tags by calling the function extract_parameters with the correct parameters with structure inside <structure></structure> XML tags.
        <context>
        {content}
        </context>

        <structure>
        {structure}
        </structure>
        """

    /// `FUNCTION_CALLING_EXTRACTOR_EXAMPLE`: (query, assistant text, arguments).
    static let functionCallingExamples: [(query: String, text: String, arguments: JSONValue)] = [
        ("What is the weather today in SF?",
         "I need always call the function with the correct parameters. In this case, I need to call the function with the location parameter.",
         ["location": "San Francisco"]),
        ("I want to eat some apple pie.",
         "I need always call the function with the correct parameters. In this case, I need to call the function with the food parameter.",
         ["food": "apple pie"]),
    ]

    static let completionGenerateJSONPrompt = """
        ### Instructions:
        Some extra information are provided below, I should always follow the instructions as possible as I can.
        <instructions>
        {instruction}
        </instructions>

        ### Extract parameter Workflow
        I need to extract the following information from the input text. The <information to be extracted> tag specifies the 'type', 'description' and 'required' of the information to be extracted.
        <information to be extracted>
        {{ structure }}
        </information to be extracted>

        Step 1: Carefully read the input and understand the structure of the expected output.
        Step 2: Extract relevant parameters from the provided text based on the name and description of object.
        Step 3: Structure the extracted parameters to JSON object as specified in <structure>.
        Step 4: Ensure that the JSON object is properly formatted and valid. The output should not contain any XML tags. Only the JSON object should be outputted.

        ### Memory
        Here are the chat histories between human and assistant, inside <histories></histories> XML tags.
        <histories>
        {histories}
        </histories>

        ### Structure
        Here is the structure of the expected output, I should always follow the output structure.
        {{γγγ
          'properties1': 'relevant text extracted from input',
          'properties2': 'relevant text extracted from input',
        }}γγγ

        ### Input Text
        Inside <text></text> XML tags, there is a text that I should extract parameters and convert to a JSON object.
        <text>
        {text}
        </text>

        ### Answer
        I should always output a valid JSON object. Output nothing other than the JSON object.
        ```JSON
        """

    static let chatGenerateJSONPrompt = """
        You should always follow the instructions and output a valid JSON object.
        The structure of the JSON object you can found in the instructions.

        ### Memory
        Here are the chat histories between human and assistant, inside <histories></histories> XML tags.
        <histories>
        {histories}
        </histories>

        ### Instructions:
        Some extra information are provided below, you should always follow the instructions as possible as I can.
        <instructions>
        {instruction}
        </instructions>
        """

    static let chatGenerateJSONUserMessageTemplate = """
        ### Structure
        Here is the structure of the JSON object, you should always follow the structure.
        <structure>
        {structure}
        </structure>

        ### Text to be converted to JSON
        Inside <text></text> XML tags, there is a text that you should convert to a JSON object.
        <text>
        {text}
        </text>
        """

    /// `CHAT_EXAMPLE`: (query, schema, answer).
    static let chatExamples: [(query: String, json: JSONValue, answer: JSONValue)] = [
        ("What is the weather today in SF?",
         ["type": "object", "properties": ["location": ["type": "string", "description": "The location to get the weather information", "required": true]],
          "required": ["location"]],
         ["location": "San Francisco"]),
        ("I want to eat some apple pie.",
         ["type": "object", "properties": ["food": ["type": "string", "description": "The food to eat", "required": true]], "required": ["food"]],
         ["food": "apple pie"]),
    ]

    /// Python's `prompt_messages[:i] + examples + prompt_messages[i:]` with `i` the last user message (-1 when none).
    static func insertBeforeLastUser(_ messages: [PromptMessage], _ examples: [PromptMessage]) -> [PromptMessage] {
        var idx = -1
        for (i, m) in messages.enumerated() where m.role == .user { idx = i }
        let cut = idx >= 0 ? idx : max(messages.count - 1, 0)
        return Array(messages[..<cut]) + examples + Array(messages[cut...])
    }

    /// The prompt messages and the tool (function calling) for one run.
    func buildPrompt(query: String, instruction: String, pool: VariablePool, histories: String = "") throws -> ([PromptMessage], [PromptMessageTool]) {
        let structure = LLMPrompting.jsonDumpsASCII(parameterSchema)
        if schema.supportsToolCall && reasoningMode == "function_call" {
            let input = LLMPrompting.pythonFormat(Self.functionCallingUserTemplate, ["content": query, "structure": structure])
            guard model.mode == "chat" else { throw NodeError("InvalidModelModeError", "Model mode \(model.mode) not support.") }
            let system = LLMPrompting.pythonFormat(Self.functionCallingSystemPrompt, ["histories": histories, "instruction": instruction])
            let compiled = try LLMPrompting.filter(try LLMPrompting.listMessages([(.system, system), (.user, input)], pool: pool), schema: schema)
            var examples: [PromptMessage] = []
            for e in Self.functionCallingExamples {
                let callId = UUIDHex.make()
                examples += [
                    PromptMessage(role: .user, content: .text(e.query)),
                    PromptMessage(role: .assistant, content: .text(e.text),
                                  toolCalls: [.init(id: callId, type: "function", name: Self.functionName,
                                                    arguments: LLMPrompting.jsonDumpsASCII(e.arguments))]),
                    PromptMessage(role: .tool, content: .text("Great! You have called the function with the correct parameters."), toolCallId: callId),
                    PromptMessage(role: .assistant, content: .text("I have extracted the parameters, let's move on.")),
                ]
            }
            let tool = PromptMessageTool(name: Self.functionName, description: "Extract parameters from the natural language text",
                                         parameters: parameterSchema.object ?? [:])
            return (Self.insertBeforeLastUser(compiled, examples), [tool])
        }
        switch model.mode {
        case "completion":
            let text = LLMPrompting.pythonFormat(Self.completionGenerateJSONPrompt, ["histories": histories, "text": query, "instruction": instruction])
                .replacingOccurrences(of: "{γγγ", with: "").replacingOccurrences(of: "}γγγ", with: "")
                .replacingOccurrences(of: "{ structure }", with: structure)
            return (try LLMPrompting.filter(LLMPrompting.completionMessages(text, pool: pool), schema: schema), [])
        case "chat":
            let input = LLMPrompting.pythonFormat(Self.chatGenerateJSONUserMessageTemplate, ["structure": structure, "text": query])
            let system = LLMPrompting.pythonFormat(Self.chatGenerateJSONPrompt, ["histories": histories, "instruction": instruction])
            let compiled = try LLMPrompting.filter(try LLMPrompting.listMessages([(.system, system), (.user, input)], pool: pool), schema: schema)
            var examples: [PromptMessage] = []
            for e in Self.chatExamples {
                examples += [
                    PromptMessage(role: .user, content: .text(LLMPrompting.pythonFormat(Self.chatGenerateJSONUserMessageTemplate,
                                                                                         ["structure": LLMPrompting.jsonDumpsASCII(e.json),
                                                                                          "text": e.query]))),
                    PromptMessage(role: .assistant, content: .text(LLMPrompting.jsonDumpsASCII(e.answer))),
                ]
            }
            return (Self.insertBeforeLastUser(compiled, examples), [])
        default:
            throw NodeError("InvalidModelModeError", "Invalid model mode: \(model.mode)")
        }
    }

    // MARK: - Run

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        let pool = context.pool
        let query = pool.get(querySelector)?.text ?? ""
        if visionEnabled { _ = try LLMNode.fetchFiles(pool, ["sys", "files"]) }
        var modelInstance = instance
        modelInstance.parameters = LLMNode.resolveCompletionParams(modelInstance.parameters, pool)
        guard schema.modelType == "llm" else { throw NodeError("InvalidModelTypeError", "Model is not a Large Language Model") }
        let renderedInstruction = VariableTemplate.convert(pool, instruction ?? "").text
        var histories = ""
        if let memory, var config = memoryConfig {
            if config.windowSize != nil { config.windowEnabled = true }
            let (baseline, _) = try buildPrompt(query: query, instruction: renderedInstruction, pool: pool)
            var bytes = 0
            let history = try await ConversationPromptMemory.messages(memory: memory, config: config, models: models,
                instance: modelInstance, schema: schema, prompt: baseline, files: files, extraTokenReserve: 1000, imageBytes: &bytes)
            histories = ConversationPromptMemory.text(history, config: config)
        }
        let (raw, tools) = try buildPrompt(query: query, instruction: renderedInstruction, pool: pool, histories: ConversationPromptMemory.placeholder)
        let messages = ConversationPromptMemory.inserting(histories, into: raw)
        let inputs: JSONObject = [
            "query": .string(query), "files": .array([]), "parameters": .array(parameters.map(\.json)),
            "instruction": instruction.map(JSONValue.string) ?? .null,
            "model_provider": .string(modelInstance.provider), "model_name": .string(modelInstance.modelName),
        ]
        var processData: JSONObject = [
            "model_mode": .string(model.mode),
            "prompts": LLMNode.serializePrompts(mode: model.mode, messages),
            "usage": .null,
            "function": tools.first?.json ?? .object([:]),
            "tool_call": .null,
            "model_provider": .string(modelInstance.provider),
            "model_name": .string(modelInstance.modelName),
        ]

        let result: LLMResultAccumulator
        do {
            result = try await LLMPrompting.invokeCollect(models, modelInstance, messages: messages, tools: tools, stream: false,
                                                          user: context.userId)
            processData["usage"] = result.usage.json
            processData["tool_call"] = result.toolCalls.first?.json ?? .null
            processData["llm_text"] = .string(result.text)
        } catch {
            // ParameterExtractorNodeError: its message as the reason; anything else: "Failed to invoke model".
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, processData: processData,
                                                outputs: ["__is_success": 0, "__reason": "Failed to invoke model", "__error": .string("\(error)")],
                                                error: "\(error)")))
            return
        }
        let usage = result.usage
        var error: String?
        var extracted: JSONObject?
        if let call = result.toolCalls.first {
            extracted = call.arguments.isEmpty ? nil : LLMPrompting.firstJSONObject(call.arguments)
        } else {
            extracted = LLMPrompting.firstJSONObject(result.text)
            if extracted == nil || extracted!.isEmpty {
                extracted = defaultResult()
                error = "Failed to extract result from function call or text response, using empty result."
            }
        }
        do { try validate(extracted ?? [:]) } catch let e as NodeError { error = e.message }
        var outputs: JSONObject = ["__is_success": .int(error == nil ? 1 : 0), "__reason": error.map(JSONValue.string) ?? .null,
                                   "__usage": usage.json]
        for (k, v) in transform(extracted ?? [:]) { outputs[k] = v }
        await emit(.completed(NodeRunResult(status: .succeeded, inputs: inputs, processData: processData, outputs: outputs,
                                            metadata: LLMPrompting.usageMetadata(usage), llmUsage: usage)))
    }

    // MARK: - Validation and normalization

    /// `SegmentType.is_valid(value, ArrayValidation.ALL)`.
    static func isValid(_ type: SegmentType, _ v: JSONValue) -> Bool {
        switch type {
        case .boolean: return v.bool != nil
        case .number, .integer, .float:
            switch v { case .int, .double, .bool: return true; default: return false }
        case .string, .secret: return v.string != nil
        case .object: return v.object != nil
        case .arrayAny, .arrayString, .arrayNumber, .arrayObject, .arrayBoolean, .arrayFile:
            guard case .array(let a) = v else { return false }
            if a.isEmpty || type == .arrayAny { return true }
            guard let e = elementType(type) else { return type == .arrayFile ? false : true }
            return a.allSatisfy { isValid(e, $0) }
        case .none: return v == .null
        default: return false
        }
    }

    /// `SegmentType.infer_segment_type`.
    static func inferType(_ v: JSONValue) -> SegmentType? {
        switch v {
        case .null: return SegmentType.none
        case .bool: return .boolean
        case .int: return .integer
        case .double: return .float
        case .string: return .string
        case .object: return .object
        case .array(let a):
            var types = Set<SegmentType>()
            for x in a {
                guard let t = inferType(x) else { return nil }
                types.insert(t)
            }
            if types.count != 1 {
                return types.isSubset(of: [.number, .integer, .float]) ? .arrayNumber : .arrayAny
            }
            switch types.first! {
            case .string: return .arrayString
            case .number, .integer, .float: return .arrayNumber
            case .object: return .arrayObject
            case .boolean: return .arrayBoolean
            case .file: return .arrayFile
            default: return .arrayAny
            }
        }
    }

    /// `_validate_result`.
    func validate(_ result: JSONObject) throws {
        if parameters.count != result.count { throw NodeError("InvalidNumberOfParametersError", "Invalid number of parameters") }
        for p in parameters {
            if p.required && result[p.name] == nil { throw NodeError("RequiredParameterMissingError", "Parameter \(p.name) is required") }
            let value = result[p.name] ?? .null
            if !Self.isValid(p.type, value) {
                let actual = Self.inferType(value).map(\.rawValue) ?? "None"
                throw NodeError("InvalidValueTypeError",
                                "Invalid value for parameter \(p.name), expected segment type: \(p.type.rawValue), actual_type: \(actual), python_type: \(WorkflowBootstrap.pythonTypeName(value)), value: \(PythonText.str(value))")
            }
            if p.type == .string, let options = p.options, !options.isEmpty, !options.contains(value.string ?? "") {
                throw NodeError("InvalidSelectValueError", "Invalid `select` value for parameter \(p.name)")
            }
        }
    }

    /// `_transform_number`.
    static func transformNumber(_ v: JSONValue) -> JSONValue? {
        switch v {
        case .bool(let b): return .int(b ? 1 : 0)
        case .int, .double: return v
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.contains(".") { return Double(t).map(JSONValue.double) }
            return Int(t).map(JSONValue.int)
        default: return nil
        }
    }

    static func transformScalar(_ type: SegmentType, _ v: JSONValue, arrayItem: Bool) -> JSONValue? {
        switch type {
        case .number: return transformNumber(v)
        case .boolean:
            if arrayItem { return v.bool.map(JSONValue.bool) }
            switch v {
            case .bool: return v
            case .int(let i): return .bool(i != 0)
            default: return nil
            }
        // (JSONValue is ExpressibleByNilLiteral: spell out "no value".)
        case .string: return v.string != nil ? Optional(v) : Optional<JSONValue>.none
        case .object: return v.object != nil ? Optional(v) : Optional<JSONValue>.none
        default: return nil
        }
    }

    /// `_transform_result`: every parameter, normalized; missing or unusable values become the type's default.
    func transform(_ result: JSONObject) -> JSONObject {
        var out = JSONObject()
        for p in parameters {
            guard let value = result[p.name] else { out[p.name] = Self.defaultValue(p.type); continue }
            if p.type.isArray {
                guard case .array(let items) = value else { out[p.name] = Self.defaultValue(p.type); continue }
                guard let e = Self.elementType(p.type) else { out[p.name] = .array([]); continue }
                out[p.name] = .array(items.compactMap { Self.transformScalar(e, $0, arrayItem: true) })
            } else if let v = Self.transformScalar(p.type, value, arrayItem: false) {
                out[p.name] = v
            } else {
                out[p.name] = Self.defaultValue(p.type)
            }
        }
        return out
    }

    /// `_build_default_parameter_value`.
    static func defaultValue(_ t: SegmentType) -> JSONValue {
        switch t {
        case .string, .secret: return ""
        case .number: return 0
        case .boolean: return false
        default: return .array([])
        }
    }

    /// `_generate_default_result`.
    func defaultResult() -> JSONObject {
        var out = JSONObject()
        for p in parameters {
            switch p.type {
            case .number: out[p.name] = 0
            case .boolean: out[p.name] = false
            case .string: out[p.name] = ""
            default: break
            }
        }
        return out
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var mapping: [(String, [String])] = [("query", querySelector)]
        for s in VariableTemplate.extractSelectors(instruction ?? "") {
            if let i = mapping.firstIndex(where: { $0.0 == s.variable }) { mapping[i].1 = s.valueSelector } else { mapping.append((s.variable, s.valueSelector)) }
        }
        return mapping.map { (id + "." + $0.0, $0.1) }
    }
}

extension BuiltinNodeFactory {
    func makeParameterExtractor(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        let models = try services.requireModels()
        let m = try LLMPrompting.model(config.data)
        let (instance, schema) = try await LLMNode.prepareModel(m, models: models)
        return try ParameterExtractorNode(id: config.id, data: config.data, instance: instance, schema: schema, models: models, memory: services.memory, files: services.files)
    }
}
