// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/llm/node.py,
// llm_utils.py, exc.py; Dify 1.17.1 (Apache-2.0 with conditions, https://github.com/langgenius/dify):
// api/core/app/llm/model_access.py (fetch_model_config), api/core/prompt/utils/prompt_message_util.py
// (prompt_messages_to_prompt_for_saving). See ../../NOTICE.md.
//
// Not ported yet: conversation memory (Dify gives single-step runs none), vision and multimodal output files (no file
// storage before P5), structured output, LLM polling, Jinja2 prompts without a renderer (they need the code sandbox).

import Foundation

/// Renders Jinja2 prompt templates (Dify: through the code sandbox).
public protocol Jinja2TemplateRenderer: Sendable {
    func renderTemplate(_ template: String, inputs: JSONObject) async throws -> String
}

/// The LLM node: builds the prompt from its templates and the run's values, invokes the model (streaming), and outputs
/// `text`, `reasoning_content`, `usage` and `finish_reason`.
public struct LLMNode: RuntimeNode {
    public static let contextPlaceholder = "{{#context#}}"
    static let maxResolvedValueLength = 1024
    static let looseVariablePattern = try! NSRegularExpression(pattern: "\\{\\{#[^#]+#\\}\\}")

    public let id: String
    public let data: LLMNodeData
    public let instance: ModelInstance
    public let schema: AIModelEntity
    let models: any ModelRuntime
    let jinja2: (any Jinja2TemplateRenderer)?
    /// Dify's `default_query_selector` for the memory query (`sys.query`).
    let defaultQuerySelector = ["sys", "query"]

    public var nodeType: String { NodeType.llm }
    public var base: BaseNodeData { data.base }

    public init(id: String, data: LLMNodeData, instance: ModelInstance, schema: AIModelEntity, models: any ModelRuntime,
                jinja2: (any Jinja2TemplateRenderer)? = nil) {
        self.id = id
        self.data = data
        self.instance = instance
        self.schema = schema
        self.models = models
        self.jinja2 = jinja2
    }

    // MARK: - Model (Dify's fetch_model_config)

    /// `fetch_model_config`: the model's credentials and schema, the completion params without `stop`, and the stop words.
    public static func prepareModel(_ m: LLMNodeData.Model, models: any ModelRuntime) async throws -> (ModelInstance, AIModelEntity) {
        if m.provider.isEmpty || m.name.isEmpty { throw NodeError("ValueError", "LLM provider and model are required.") }
        let credentials = try await models.credentials(provider: m.provider, model: m.name, modelType: "llm")
        guard let schema = try await models.modelSchema(provider: m.provider, model: m.name, modelType: "llm", credentials: credentials) else {
            throw NodeError("ModelNotExistError", "Model \(m.name) schema does not exist.")
        }
        var parameters = m.completionParams
        let stopValue = parameters["stop"]
        parameters["stop"] = nil
        var stop: [String] = []
        if case .array(let xs)? = stopValue, xs.allSatisfy({ $0.string != nil }) { stop = xs.compactMap(\.string) }
        return (ModelInstance(provider: m.provider, modelName: m.name, credentials: credentials, parameters: parameters, stop: stop), schema)
    }

    // MARK: - Run

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var nodeInputs = JSONObject()
        var processData = JSONObject()
        var usage = LLMUsage.empty
        do {
            let pool = context.pool
            let template = Self.transformChatMessages(data.promptTemplate)
            try fetchInputs(template, pool)
            try fetchJinjaInputs(pool)
            if data.vision.enabled { _ = try Self.fetchFiles(pool, data.vision.variableSelector) }

            var contextText: String?
            if let event = try fetchContext(pool) {
                contextText = event.context
                await emit(.retrieverResource(resources: event.resources, context: event.context))
            }
            if let c = contextText, !c.isEmpty { nodeInputs["#context#"] = .string(c) }

            var model = instance
            model.parameters = Self.resolveCompletionParams(model.parameters, pool)
            nodeInputs["model_provider"] = .string(model.provider)
            nodeInputs["model_name"] = .string(model.modelName)

            let promptMessages = try await fetchPromptMessages(sysQuery: resolveMemoryQuery(pool), context: contextText ?? "",
                                                               template: template, pool: pool)
            if data.structuredOutputEnabled {
                throw NodeError("LLMNodeError", "Structured output is not supported by this runtime yet.")
            }

            let completed = try await invokeStreaming(model, promptMessages, stop: model.stop, context: context, emit: emit)
            usage = completed.usage
            let cleanText = data.reasoningFormat == "tagged" ? completed.text
                : Reasoning.split(completed.text, format: data.reasoningFormat).clean
            nodeInputs["model_provider"] = .string(model.provider)
            nodeInputs["model_name"] = .string(model.modelName)
            processData = [
                "model_mode": .string(data.model.mode),
                "prompts": Self.serializePrompts(mode: data.model.mode, promptMessages),
                "usage": usage.json,
                "finish_reason": completed.finishReason.map(JSONValue.string) ?? .null,
                "model_provider": .string(model.provider),
                "model_name": .string(model.modelName),
            ]
            var outputs: JSONObject = [
                "text": .string(cleanText),
                "reasoning_content": .string(completed.reasoning),
                "usage": usage.json,
                "finish_reason": completed.finishReason.map(JSONValue.string) ?? .null,
            ]
            if let so = completed.structuredOutput { outputs["structured_output"] = .object(so) }
            await emit(.streamChunk(selector: [id, "text"], chunk: "", isFinal: true))
            await emit(.completed(NodeRunResult(
                status: .succeeded, inputs: nodeInputs, processData: processData, outputs: outputs,
                metadata: [MetadataKey.totalTokens: .int(usage.totalTokens), MetadataKey.totalPrice: .string(usage.totalPrice.text),
                           MetadataKey.currency: .string(usage.currency)],
                llmUsage: usage)))
        } catch {
            await emit(.completed(NodeRunResult(status: .failed, inputs: nodeInputs, processData: processData, llmUsage: usage,
                                                error: "\(error)", errorType: Self.errorTypeName(error))))
        }
    }

    static func errorTypeName(_ e: any Error) -> String {
        if let e = e as? any NodeRunError { return e.errorTypeName }
        if let e = e as? ModelInvokeError { return e.errorType }
        if e is VariablePool.InvalidSelector { return "ValueError" }
        return "Exception"
    }

    // MARK: - Streaming (_yield_streaming_invoke_result)

    struct Completed {
        var text: String
        var reasoning: String
        var usage: LLMUsage
        var finishReason: String?
        var structuredOutput: JSONObject?
    }

    func invokeStreaming(_ model: ModelInstance, _ messages: [PromptMessage], stop: [String], context: NodeRunContext,
                         emit: @Sendable (NodeEvent) async -> Void) async throws -> Completed {
        let start = ContinuousClock.now
        var firstToken: ContinuousClock.Instant?
        var hasContent = false
        var fullText = ""
        var usage = LLMUsage.empty
        var finishReason: String?
        var structuredOutput: JSONObject?
        var filter: ThinkStreamFilter? = data.reasoningFormat == "separated" ? ThinkStreamFilter() : nil
        var reasoningStarted = false
        let textSelector = [id, "text"], reasoningSelector = [id, "reasoning_content"]

        func emitPiece(_ p: ThinkStreamFilter.Piece, isFinal: Bool = false) async {
            switch p {
            case .text(let t): await emit(.streamChunk(selector: textSelector, chunk: t, isFinal: false))
            case .reasoning(let r):
                reasoningStarted = true
                await emit(.streamReasoning(selector: reasoningSelector, chunk: r, isFinal: isFinal))
            }
        }

        for try await chunk in models.invokeLLM(model, promptMessages: messages, parameters: model.parameters, stop: stop, user: context.userId) {
            if let so = chunk.structuredOutput { structuredOutput = so }
            let parts: [String]
            switch chunk.content {
            case .none: parts = []
            case .text(let s): parts = [s]
            case .parts(let ps): parts = ps.map { if case .text(let s) = $0 { return s }; return "" }
            }
            for part in parts {
                if !part.isEmpty && !hasContent {
                    firstToken = ContinuousClock.now
                    hasContent = true
                }
                fullText += part
                if filter == nil {
                    await emit(.streamChunk(selector: textSelector, chunk: part, isFinal: false))
                } else {
                    for piece in filter!.feed(part) { await emitPiece(piece) }
                }
            }
            if usage.promptTokens == 0, let u = chunk.usage { usage = u }
            if finishReason == nil, let f = chunk.finishReason, !f.isEmpty { finishReason = f }
        }
        if filter != nil {
            let final = filter!.finalize()
            var hasFinalReasoning = false
            for (i, piece) in final.enumerated() {
                var isFinalReasoning = false
                if case .reasoning = piece, i == final.count - 1 { isFinalReasoning = true }
                hasFinalReasoning = hasFinalReasoning || isFinalReasoning
                await emitPiece(piece, isFinal: isFinalReasoning)
            }
            if reasoningStarted && !hasFinalReasoning {
                await emit(.streamReasoning(selector: reasoningSelector, chunk: "", isFinal: true))
            }
        }
        let (clean, reasoning) = Reasoning.extractStream(fullText, format: data.reasoningFormat)
        let end = ContinuousClock.now
        usage.latency = Self.round3(Self.seconds(end - start))
        if hasContent, let firstToken {
            usage.timeToFirstToken = Self.round3(Self.seconds(firstToken - start))
            usage.timeToGenerate = Self.round3(Self.seconds(end - firstToken))
        }
        return Completed(text: data.reasoningFormat == "separated" ? clean : fullText, reasoning: reasoning, usage: usage,
                         finishReason: finishReason, structuredOutput: structuredOutput)
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    // MARK: - Inputs

    /// `_transform_chat_messages`: a jinja2 message's text becomes its `jinja2_text`.
    static func transformChatMessages(_ t: LLMNodeData.PromptTemplate) -> LLMNodeData.PromptTemplate {
        func tr(_ m: LLMNodeData.PromptTemplateMessage) -> LLMNodeData.PromptTemplateMessage {
            var m = m
            if m.editionType == "jinja2", let j = m.jinja2Text, !j.isEmpty { m.text = j }
            return m
        }
        switch t {
        case .chat(let ms): return .chat(ms.map(tr))
        case .completion(let m): return .completion(tr(m))
        }
    }

    func requiredVariable(_ s: VariableSelector, _ pool: VariablePool) throws -> Segment {
        guard let v = pool.get(s.valueSelector) else { throw NodeError("VariableNotFoundError", "Variable \(s.variable) not found") }
        return v
    }

    /// `_fetch_inputs`: every reference in the templates (and the memory query) must exist.
    func fetchInputs(_ t: LLMNodeData.PromptTemplate, _ pool: VariablePool) throws {
        let selectors: [VariableSelector]
        switch t {
        case .chat(let ms): selectors = ms.flatMap { VariableTemplate.extractSelectors($0.text) }
        case .completion(let m): selectors = VariableTemplate.extractSelectors(m.text)
        }
        for s in selectors { _ = try requiredVariable(s, pool) }
        if let q = data.memory?.queryPromptTemplate, !q.isEmpty {
            for s in VariableTemplate.extractSelectors(q) { _ = try requiredVariable(s, pool) }
        }
    }

    /// `_fetch_jinja_inputs`: every Jinja2 variable must exist (also for basic prompts, as graphon checks them always).
    func fetchJinjaInputs(_ pool: VariablePool) throws {
        for s in data.jinja2Variables { _ = try requiredVariable(s, pool) }
    }

    /// `llm_utils.fetch_files`: no file values exist before P5, so this only rejects a variable of another type.
    static func fetchFiles(_ pool: VariablePool, _ selector: [String]) throws -> [JSONValue] {
        guard let v = pool.get(selector) else { return [] }
        switch v.valueType {
        case .none, .arrayAny: return []
        case .file, .arrayFile: return []
        default: throw NodeError("InvalidVariableTypeError", "Invalid variable type: <class 'graphon.variables.segments.\(segmentClassName(v.valueType))'>")
        }
    }

    static func segmentClassName(_ t: SegmentType) -> String {
        switch t {
        case .string: return "StringSegment"
        case .integer: return "IntegerSegment"
        case .float: return "FloatSegment"
        case .boolean: return "BooleanSegment"
        case .object: return "ObjectSegment"
        case .arrayString: return "ArrayStringSegment"
        case .arrayNumber: return "ArrayNumberSegment"
        case .arrayObject: return "ArrayObjectSegment"
        case .arrayBoolean: return "ArrayBooleanSegment"
        case .arrayAny: return "ArrayAnySegment"
        case .file: return "FileSegment"
        case .arrayFile: return "ArrayFileSegment"
        case .none: return "NoneSegment"
        default: return "Segment"
        }
    }

    /// `_fetch_context`: a string value is the context; an array is joined (strings, and knowledge chunks with their
    /// `content`, which also become retriever resources).
    func fetchContext(_ pool: VariablePool) throws -> (resources: [JSONValue], context: String)? {
        guard data.context.enabled, let sel = data.context.variableSelector, !sel.isEmpty, let v = pool.get(sel) else { return nil }
        if v.valueType == .string { return ([], v.value.string ?? "") }
        guard v.valueType.isArray, let items = v.value.array else { return nil }
        var context = ""
        var resources: [JSONValue] = []
        for item in items {
            if case .string(let s) = item { context += s + "\n"; continue }
            guard case .object(let o) = item, let content = o["content"] else {
                throw NodeError("InvalidContextStructureError", "Invalid context structure: \(PythonText.repr(item))")
            }
            if let summary = o["summary"], summary.isTruthy { context += PythonText.str(summary) + "\n" }
            context += PythonText.str(content) + "\n"
            if let r = Self.retrieverResource(o) { resources.append(r) }
        }
        return (resources, context.pythonStrip())
    }

    /// `_convert_to_original_retriever_resource`.
    static func retrieverResource(_ o: JSONObject) -> JSONValue? {
        guard case .object(let meta)? = o["metadata"], meta["_source"]?.string == "knowledge" else { return nil }
        func m(_ k: String) -> JSONValue { meta[k] ?? .null }
        return .object([
            "position": m("position"), "dataset_id": m("dataset_id"), "dataset_name": m("dataset_name"),
            "document_id": m("document_id"), "document_name": m("document_name"), "data_source_type": m("data_source_type"),
            "segment_id": m("segment_id"), "retriever_from": m("retriever_from"), "score": m("score"),
            "hit_count": m("segment_hit_count"), "word_count": m("segment_word_count"), "segment_position": m("segment_position"),
            "index_node_hash": m("segment_index_node_hash"), "content": o["content"] ?? .null, "page": m("page"),
            "doc_metadata": m("doc_metadata"), "files": o["files"] ?? .null, "summary": o["summary"] ?? .null,
        ])
    }

    /// `_resolve_memory_query`: only with memory (Dify's single-step runs have no conversation memory, but the query
    /// template still applies).
    func resolveMemoryQuery(_ pool: VariablePool) -> String? {
        guard let memory = data.memory else { return nil }
        if let q = memory.queryPromptTemplate, !q.isEmpty { return q }
        return pool.get(defaultQuerySelector)?.text
    }

    /// `resolve_completion_params_variables`: string params with references are rendered (at most 1024 characters) and
    /// turned back into numbers or booleans when they read as such.
    static func resolveCompletionParams(_ params: JSONObject, _ pool: VariablePool) -> JSONObject {
        var out = JSONObject()
        for (k, v) in params {
            guard case .string(let s) = v,
                  looseVariablePattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil else {
                out[k] = v
                continue
            }
            var text = VariableTemplate.convert(pool, s).text
            if text.unicodeScalars.count > maxResolvedValueLength { text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxResolvedValueLength))) }
            out[k] = coerce(text)
        }
        return out
    }

    /// `_coerce_resolved_value`.
    static func coerce(_ raw: String) -> JSONValue {
        let stripped = raw.pythonStrip()
        if stripped.isEmpty { return .string(raw) }
        guard let parsed = try? JSONValue.parse(stripped) else { return .string(raw) }
        switch parsed {
        case .int, .double, .bool: return parsed
        default: return .string(raw)
        }
    }

    // MARK: - Prompt (fetch_prompt_messages)

    func fetchPromptMessages(sysQuery: String?, context: String, template: LLMNodeData.PromptTemplate,
                             pool: VariablePool) async throws -> [PromptMessage] {
        var messages: [PromptMessage]
        switch template {
        case .chat(let ms):
            messages = try await listMessages(ms, context: context, pool: pool)
            // Conversation memory: none in this runtime yet (Dify's single-step runs have none either).
            if let q = sysQuery, !q.isEmpty {
                messages += try await listMessages([.init(text: q, role: .user, editionType: "basic", jinja2Text: nil)], context: "", pool: pool)
            }
        case .completion(let m):
            let text: String
            if m.editionType == "jinja2" {
                text = try await renderJinja2(m.jinja2Text ?? "", pool)
            } else {
                text = VariableTemplate.convert(pool, m.text.replacingOccurrences(of: Self.contextPlaceholder, with: context)).text
            }
            var data = text
            // _merge_completion_memory with no memory: "#histories#" -> "", else "" + "\n" + text.
            let memoryText = ""
            data = data.contains("#histories#") ? data.replacingOccurrences(of: "#histories#", with: memoryText) : memoryText + "\n" + data
            if let q = sysQuery, !q.isEmpty { data = q + "\n" + data }
            messages = [PromptMessage(role: .user, content: .parts([.text(data)]))]
        }
        let filtered = filter(messages)
        if filtered.isEmpty {
            throw NodeError("NoPromptFoundError",
                            "No prompt found in the LLM configuration. Please ensure a prompt is properly configured before proceeding.")
        }
        return filtered
    }

    /// `handle_list_messages`.
    func listMessages(_ ms: [LLMNodeData.PromptTemplateMessage], context: String, pool: VariablePool) async throws -> [PromptMessage] {
        var out: [PromptMessage] = []
        for m in ms {
            let role = m.role ?? .user
            if m.editionType == "jinja2" {
                let text = try await renderJinja2(m.jinja2Text ?? "", pool)
                out.append(try Self.message(role, .parts([.text(text)])))
                continue
            }
            let template = m.text.replacingOccurrences(of: Self.contextPlaceholder, with: context)
            let plain = VariableTemplate.convert(pool, template).text
            if !plain.isEmpty { out.append(try Self.message(role, .parts([.text(plain)]))) }
        }
        return out
    }

    /// `_combine_message_content_with_role`.
    static func message(_ role: PromptMessageRole, _ content: PromptMessage.Content) throws -> PromptMessage {
        if role == .tool { throw NodeError("NotImplementedError", "Role tool is not supported") }
        return PromptMessage(role: role, content: content)
    }

    /// `_render_jinja2_message`.
    func renderJinja2(_ template: String, _ pool: VariablePool) async throws -> String {
        if template.isEmpty { return "" }
        var inputs = JSONObject()
        for v in data.jinja2Variables { inputs[v.variable] = pool.get(v.valueSelector)?.object ?? .string("") }
        guard let jinja2 else {
            throw NodeError("TemplateRenderError", "LLMNode requires an injected jinja2_template_renderer for jinja2 prompts.")
        }
        return try await jinja2.renderTemplate(template, inputs: inputs)
    }

    /// `_filter_prompt_messages`: parts the model cannot take are dropped, a single text part becomes plain text, empty
    /// messages go.
    func filter(_ messages: [PromptMessage]) -> [PromptMessage] {
        var out: [PromptMessage] = []
        for var m in messages {
            if case .parts(let ps) = m.content {
                let kept = ps.filter { schema.supports(contentType: $0.type) }
                if kept.count == 1, case .text(let s) = kept[0] { m.content = .text(s) } else { m.content = .parts(kept) }
            }
            if m.isEmpty { continue }
            out.append(m)
        }
        return out
    }

    /// Dify's `PromptMessageUtil.prompt_messages_to_prompt_for_saving` (the `prompts` of the process data).
    static func serializePrompts(mode: String, _ messages: [PromptMessage]) -> JSONValue {
        if mode == "chat" {
            return .array(messages.map { m in
                ["role": .string(m.role.rawValue), "text": .string(m.textContent), "files": .array([])]
            })
        }
        guard let first = messages.first else { return .array([]) }
        return .array([["role": "user", "text": .string(first.textContent)]])
    }

    // MARK: - Single-step mapping

    /// `_extract_variable_selector_to_variable_mapping`: the templates' references (not jinja2 ones), the memory query's,
    /// `#context#`, `#files#` (vision) and the Jinja2 variables when a template uses Jinja2.
    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var mapping: [(String, [String])] = []
        func put(_ k: String, _ s: [String]) {
            if let i = mapping.firstIndex(where: { $0.0 == k }) { mapping[i].1 = s } else { mapping.append((k, s)) }
        }
        var usesJinja = false
        switch data.promptTemplate {
        case .chat(let ms):
            for m in ms {
                if m.editionType == "jinja2" { usesJinja = true; continue }
                for s in VariableTemplate.extractSelectors(m.text) { put(s.variable, s.valueSelector) }
            }
        case .completion(let m):
            if m.editionType == "jinja2" { usesJinja = true } else {
                for s in VariableTemplate.extractSelectors(m.text) { put(s.variable, s.valueSelector) }
            }
        }
        if let q = data.memory?.queryPromptTemplate, !q.isEmpty {
            for s in VariableTemplate.extractSelectors(q) { put(s.variable, s.valueSelector) }
        }
        if data.context.enabled, let sel = data.context.variableSelector { put("#context#", sel) }
        if data.vision.enabled { put("#files#", data.vision.variableSelector) }
        if usesJinja { for v in data.jinja2Variables { put(v.variable, v.valueSelector) } }
        return mapping.map { (id + "." + $0.0, $0.1) }
    }
}
