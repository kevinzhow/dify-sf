// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/nodes/question_classifier/question_classifier_node.py, entities.py, template_prompts.py; Dify 1.17.1
// (api/core/workflow/node_factory.py: the model and prompt serializer it gets). See ../../NOTICE.md.
//
// Vision attachments in classifier prompts remain outside this port; durable conversation memory uses the shared
// provider and the model's real token counter.

import Foundation

/// The question classifier: asks the model which class the query belongs to and branches on the class id.
public struct QuestionClassifierNode: RuntimeNode {
    public struct ClassConfig: Sendable {
        public var id: String
        public var name: String
        public var label: String
    }

    public let id: String
    public let base: BaseNodeData
    public let model: LLMNodeData.Model
    public let querySelector: [String]
    public let classes: [ClassConfig]
    public let instruction: String?
    public let visionEnabled: Bool
    let instance: ModelInstance
    let schema: AIModelEntity
    let models: any ModelRuntime
    let files: (any RuntimeFiles)?
    let memory: (any ConversationMemory)?
    let memoryConfig: LLMNodeData.Memory?

    public var nodeType: String { NodeType.questionClassifier }
    public var executionType: NodeExecutionType { .branch }

    public init(id: String, data: JSONObject, instance: ModelInstance, schema: AIModelEntity, models: any ModelRuntime, memory: (any ConversationMemory)? = nil, files: (any RuntimeFiles)? = nil) throws {
        self.id = id
        base = try BaseNodeData(data)
        model = try LLMPrompting.model(data)
        guard let q = data["query_variable_selector"]?.array else { throw NodeDataError("query_variable_selector: Field required") }
        querySelector = q.map { PythonText.str($0) }
        guard let cs = data["classes"]?.array else { throw NodeDataError("classes: Field required") }
        classes = try cs.map { c in
            guard let cid = c["id"].map({ $0.string ?? PythonText.str($0) }), let name = c["name"]?.string else {
                throw NodeDataError("classes: id and name are required")
            }
            return ClassConfig(id: cid, name: name, label: c["label"]?.string ?? "")
        }
        instruction = data["instruction"]?.string
        visionEnabled = data["vision"]?["enabled"]?.bool ?? false
        self.instance = instance
        self.schema = schema
        self.models = models
        self.files = files
        self.memory = memory
        self.memoryConfig = ConversationPromptMemory.config(data["memory"])
    }

    static let systemPrompt = """

        ### Job Description',
        You are a text classification engine that analyzes text data and assigns categories based on user input or automatically determined categories.
        ### Task
        Your task is to assign one categories ONLY to the input text and only one category may be assigned returned in the output.
        Additionally, you need to extract the key words from the text that are related to the classification.
        ### Format
        The input text is in the variable input_text. Categories are specified as a category list with two filed category_id and category_name in the variable categories. Classification instructions may be included to improve the classification accuracy.
        ### Constraint
        DO NOT include anything other than the JSON array in your response.
        ### Memory
        Here are the chat histories between human and assistant, inside <histories></histories> XML tags.
        <histories>
        {histories}
        </histories>

        """

    static let userPrompt1 = """

            {"input_text": ["I recently had a great experience with your company. The service was prompt and the staff was very friendly."],
            "categories": [{"category_id":"f5660049-284f-41a7-b301-fd24176a711c","category_name":"Customer Service"},{"category_id":"8d007d06-f2c9-4be5-8ff6-cd4381c13c60","category_name":"Satisfaction"},{"category_id":"5fbbbb18-9843-466d-9b8e-b9bfbb9482c8","category_name":"Sales"},{"category_id":"23623c75-7184-4a2e-8226-466c2e4631e4","category_name":"Product"}],
            "classification_instructions": ["classify the text based on the feedback provided by customer"]}

        """

    static let assistantPrompt1 = """

        ```json
            {"keywords": ["recently", "great experience", "company", "service", "prompt", "staff", "friendly"],
            "category_id": "f5660049-284f-41a7-b301-fd24176a711c",
            "category_name": "Customer Service"}
        ```

        """

    static let userPrompt2 = """

            {"input_text": ["bad service, slow to bring the food"],
            "categories": [{"category_id":"80fb86a0-4454-4bf5-924c-f253fdd83c02","category_name":"Food Quality"},{"category_id":"f6ff5bc3-aca0-4e4a-8627-e760d0aca78f","category_name":"Experience"},{"category_id":"cc771f63-74e7-4c61-882e-3eda9d8ba5d7","category_name":"Price"}],
            "classification_instructions": []}

        """

    static let assistantPrompt2 = """

        ```json
            {"keywords": ["bad service", "slow", "food", "tip", "terrible", "waitresses"],
            "category_id": "f6ff5bc3-aca0-4e4a-8627-e760d0aca78f",
            "category_name": "Experience"}
        ```

        """

    static let userPrompt3 = """

            {{"input_text": ["{input_text}"],
            "categories": {categories},
            "classification_instructions": ["{classification_instructions}"]}}

        """

    static let completionPrompt = """

        ### Job Description
        You are a text classification engine that analyzes text data and assigns categories based on user input or automatically determined categories.
        ### Task
        Your task is to assign one categories ONLY to the input text and only one category may be assigned returned in the output.
        Additionally, you need to extract the key words from the text that are related to the classification.
        ### Format
        The input text is in the variable input_text. Categories are specified as a category list  with two filed category_id and category_name in the variable categories. Classification instructions may be included to improve the classification accuracy.
        ### Constraint
        DO NOT include anything other than the JSON array in your response.
        ### Example
        Here is the chat example between human and assistant, inside <example></example> XML tags.
        <example>
        User:{{"input_text": ["I recently had a great experience with your company. The service was prompt and the staff was very friendly."], "categories": [{{"category_id":"f5660049-284f-41a7-b301-fd24176a711c","category_name":"Customer Service"}},{{"category_id":"8d007d06-f2c9-4be5-8ff6-cd4381c13c60","category_name":"Satisfaction"}},{{"category_id":"5fbbbb18-9843-466d-9b8e-b9bfbb9482c8","category_name":"Sales"}},{{"category_id":"23623c75-7184-4a2e-8226-466c2e4631e4","category_name":"Product"}}], "classification_instructions": ["classify the text based on the feedback provided by customer"]}}
        Assistant:{{"keywords": ["recently", "great experience", "company", "service", "prompt", "staff", "friendly"],"category_id": "f5660049-284f-41a7-b301-fd24176a711c","category_name": "Customer Service"}}
        User:{{"input_text": ["bad service, slow to bring the food"], "categories": [{{"category_id":"80fb86a0-4454-4bf5-924c-f253fdd83c02","category_name":"Food Quality"}},{{"category_id":"f6ff5bc3-aca0-4e4a-8627-e760d0aca78f","category_name":"Experience"}},{{"category_id":"cc771f63-74e7-4c61-882e-3eda9d8ba5d7","category_name":"Price"}}], "classification_instructions": []}}
        Assistant:{{"keywords": ["bad service", "slow", "food", "tip", "terrible", "waitresses"],"category_id": "f6ff5bc3-aca0-4e4a-8627-e760d0aca78f","category_name": "Experience"}}
        </example>
        ### Memory
        Here are the chat histories between human and assistant, inside <histories></histories> XML tags.
        <histories>
        {histories}
        </histories>
        ### User Input
        {{"input_text" : ["{input_text}"], "categories" : {categories},"classification_instruction" : ["{classification_instructions}"]}}
        ### Assistant Output

        """

    /// `_get_prompt_template` (no memory: empty histories).
    func promptMessages(query: String, instruction: String, pool: VariablePool, histories: String = "") throws -> [PromptMessage] {
        let categories = JSONValue.array(classes.map { ["category_id": .string($0.id), "category_name": .string($0.name)] }).pythonJSONDumps()
        let values = ["histories": histories, "input_text": query, "categories": categories, "classification_instructions": instruction]
        let messages: [PromptMessage]
        if model.mode == "chat" {
            messages = try LLMPrompting.listMessages([
                (.system, LLMPrompting.pythonFormat(Self.systemPrompt, values)),
                (.user, Self.userPrompt1), (.assistant, Self.assistantPrompt1),
                (.user, Self.userPrompt2), (.assistant, Self.assistantPrompt2),
                (.user, LLMPrompting.pythonFormat(Self.userPrompt3, values)),
            ], pool: pool)
        } else {
            messages = LLMPrompting.completionMessages(LLMPrompting.pythonFormat(Self.completionPrompt, values), pool: pool)
        }
        return try LLMPrompting.filter(messages, schema: schema)
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        let pool = context.pool
        let queryValue = querySelector.isEmpty ? nil : pool.get(querySelector)?.value
        let renderedInstruction = VariableTemplate.convert(pool, instruction ?? "").text
        var modelInstance = instance
        modelInstance.parameters = LLMNode.resolveCompletionParams(modelInstance.parameters, pool)
        if visionEnabled { _ = try LLMNode.fetchFiles(pool, ["sys", "files"]) }
        let queryText: String = {
            guard let q = queryValue, q.isTruthy else { return "" }
            return PythonText.str(q)
        }()
        var histories = ""
        if let memory {
            var config = memoryConfig ?? .init(rolePrefix: nil, windowEnabled: false, windowSize: nil, queryPromptTemplate: nil)
            if config.windowSize != nil { config.windowEnabled = true }
            let baseline = try promptMessages(query: queryText, instruction: renderedInstruction, pool: pool)
            var bytes = 0
            let history = try await ConversationPromptMemory.messages(memory: memory, config: config, models: models,
                instance: modelInstance, schema: schema, prompt: baseline, files: files, imageBytes: &bytes)
            histories = ConversationPromptMemory.text(history, config: config)
        }
        let raw = try promptMessages(query: queryText, instruction: renderedInstruction, pool: pool, histories: ConversationPromptMemory.placeholder)
        let messages = ConversationPromptMemory.inserting(histories, into: raw)
        let inputs: JSONObject = ["query": queryValue ?? .null, "model_provider": .string(modelInstance.provider),
                                  "model_name": .string(modelInstance.modelName)]
        let rendered = classes.map { c in ClassConfig(id: c.id, name: VariableTemplate.convert(pool, c.name).text, label: c.label) }

        var usage = LLMUsage.empty
        do {
            // LLMNode.invoke_llm (streamed, no chunk events), tagged reasoning: the whole text.
            let result = try await LLMPrompting.invokeCollect(models, modelInstance, messages: messages, stream: true, user: context.userId)
            usage = result.usage
            guard let first = rendered.first else { throw NodeError("IndexError", "list index out of range") }
            var category = (name: first.name, id: first.id, label: first.label.isEmpty ? "CLASS 1" : first.label)
            let json = try LLMPrompting.parseAndCheckJSONMarkdown(Self.stripThinkTags(result.text), expectedKeys: [])
            if json["category_name"] != nil, let resultId = json["category_id"]?.string {
                if let i = rendered.firstIndex(where: { $0.id == resultId }) {
                    category = (rendered[i].name, resultId, rendered[i].label.isEmpty ? "CLASS \(i + 1)" : rendered[i].label)
                }
            }
            let processData: JSONObject = [
                "model_mode": .string(model.mode),
                "prompts": LLMNode.serializePrompts(mode: model.mode, messages),
                "usage": usage.json,
                "finish_reason": result.finishReason.map(JSONValue.string) ?? .null,
                "model_provider": .string(modelInstance.provider),
                "model_name": .string(modelInstance.modelName),
            ]
            var r = NodeRunResult(status: .succeeded, inputs: inputs, processData: processData,
                                  outputs: ["class_name": .string(category.name), "class_label": .string(category.label),
                                            "class_id": .string(category.id), "usage": usage.json],
                                  metadata: LLMPrompting.usageMetadata(usage), llmUsage: usage)
            r.edgeSourceHandle = category.id
            await emit(.completed(r))
        } catch {
            let typeName = (error as? LLMPrompting.ParseError)?.errorType ?? LLMNode.errorTypeName(error)
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, metadata: LLMPrompting.usageMetadata(usage), llmUsage: usage,
                                                error: "\(error)", errorType: typeName)))
        }
    }

    /// `_strip_think_tags`.
    static func stripThinkTags(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        let re = try! NSRegularExpression(pattern: "<think[^>]*>[\\s\\S]*?</think>", options: [.caseInsensitive])
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
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
    func makeQuestionClassifier(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        let models = try services.requireModels()
        let m = try LLMPrompting.model(config.data)
        let (instance, schema) = try await LLMNode.prepareModel(m, models: models)
        return try QuestionClassifierNode(id: config.id, data: config.data, instance: instance, schema: schema, models: models, memory: services.memory, files: services.files)
    }
}
