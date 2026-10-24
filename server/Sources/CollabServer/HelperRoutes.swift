// Dify 1.17.1 controllers/console/app/{generator,audio}.py and core/llm_generator.
// Suggestions are proposals: only the client's normal collaborative apply writes the document.
import CollabCore
import CollabRuntime
import Foundation
import HTTPTypes
import Vapor

extension Routes {
    func registerHelpers(on r: any RoutesBuilder) {
        for kind in ["rule-generate", "rule-code-generate", "rule-structured-output-generate", "instruction-generate", "workflow-generate"] {
            r.post("v1", .constant(kind)) { req in await handle(req) { try await generateHelper(req, kind: kind) } }
        }
        let apps = r.grouped("v1", "apps", ":app", "text-to-audio")
        apps.get("voices") { req in await handle(req) { try await helperVoices(req) } }
        apps.post { req in await handle(req) { try await helperAudio(req) } }
    }
    func helperRuntime(app: String? = nil) throws -> PluginDaemonModelRuntime {
        guard runtimeConfigured else { throw ServerError.http(status: 503, code: "runtime_not_configured", message: "Configure the plugin runtime first") }
        return .init(daemon: toolDaemon(), credentialsOf: { provider, model, type in
            try await self.currentCredentials(provider: provider, model: model, modelType: type)
        }, appId: app)
    }
    func helperModel(_ config: JSONValue?, type: String) async throws -> (provider: String, model: String, parameters: JSONObject) {
        if let provider = config?["provider"]?.string, let model = config?["name"]?.string, !provider.isEmpty, !model.isEmpty {
            return (provider, model, config?["completion_params"]?.object ?? [:])
        }
        guard let selected = try await store.modelProviderState().defaults[type] else {
            throw ServerError.http(status: 400, code: "provider_not_initialize", message: "Choose a default \(type) model in model settings")
        }
        return (selected.provider, selected.model, [:])
    }
    func helperVoices(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .member)
        let app = try await liveApp(try appId(req), viewer: p.id)
        guard let language = queryAll(req)["language"]?.last, !language.isEmpty, language.count <= 64 else {
            throw ServerError.badRequest("A language query parameter is required")
        }
        let selected = try await helperModel(nil, type: "tts")
        let voices = try await helperRuntime(app: app.id).voices(provider: selected.provider, model: selected.model, language: language)
        return try json(JSONValue.array(voices))
    }
    func helperAudio(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let app = try await liveApp(try appId(req), viewer: p.id)
        let raw = try JSONValue.parse(Array(try await body(req)))
        var text = raw["text"]?.string ?? ""
        if let messageId = raw["message_id"]?.string, !messageId.isEmpty {
            guard let message = try await store.chatMessage(id: messageId), message.docId == app.id,
                  message.accountId == p.id, message.endUserId == nil else { throw ServerError.missing("Message not found") }
            text = message.answer
        }
        guard !text.isEmpty, text.utf8.count <= 16384 else { throw ServerError.badRequest("Text must contain 1–16384 UTF-8 bytes") }
        let selected = try await helperModel(nil, type: "tts")
        let runtime = try helperRuntime(app: app.id)
        let choices = try await runtime.voices(provider: selected.provider, model: selected.model, language: nil)
        let voice = raw["voice"]?.string ?? choices.first?["value"]?.string ?? ""
        guard choices.contains(where: { $0["value"]?.string == voice }) else { throw ServerError.badRequest("Voice is not available for this model") }
        let (audio, mime) = try await runtime.audio(provider: selected.provider, model: selected.model, text: text, voice: voice)
        var headers = HTTPFields(); headers[.contentType] = mime; headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        return Response(status: .ok, headers: headers, body: .init(data: audio))
    }
    func generateHelper(_ req: Request, kind: String) async throws -> Response {
        let p = try await authenticate(req, .edit)
        var b = try JSONValue.parse(Array(try await body(req)))
        guard let instruction = b["instruction"]?.string, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instruction.count <= 10000 else { throw ServerError.badRequest("Instruction must contain 1–10000 characters") }
        let app = b["flow_id"]?.string
        if let app {
            _ = try await liveApp(app, viewer: p.id)
            if kind == "instruction-generate", let node = b["node_id"]?.string {
                var payload = b.object ?? [:]
                let last = try await store.lastNodeExecution(doc:app,nodeId:node,createdBy:p.id)
                payload["last_run"] = last.map { entry -> JSONValue in ["inputs":(try? JSONValue.parse(entry.inputs ?? "{}")) ?? [:],
                    "status":.string(entry.status),"error":entry.error.map(JSONValue.string) ?? .null] } ?? .null
                let snapshot = try await registry.sequencer(app).currentSnapshot()
                if let node = snapshot.doc.nodes[node] { payload["node_type"] = .string(node.type) }
                b = .object(payload)
            }
        }
        let selected = try await helperModel(b["model_config"], type: "llm")
        let runtime = try helperRuntime(app: app)
        let credentials = try await runtime.credentials(provider: selected.provider, model: selected.model, modelType: "llm")
        let instance = ModelInstance(provider: selected.provider, modelName: selected.model, credentials: credentials,
                                     parameters: selected.parameters, stop: [])
        if kind == "workflow-generate" {
            var payload = b.object ?? [:]
            payload["available_tools"] = .array(try await generatorToolCatalog(appId:app))
            b = .object(payload)
        }
        let engine = HelperGenerator(runtime: runtime, model: instance, user: p.id)
        do {
            let result = try await engine.generateWithDeadline(kind:kind,body:b,instruction:instruction)
            return try json(result)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A model/format failure never mutates the app, nor masquerades as a generated sample.
            return try json(JSONValue.object(["error": .string("Generation failed: \(error)"), "prompt": "", "code": "", "output": ""]))
        }
    }
}

struct HelperGenerator: Sendable {
    let runtime: any ModelRuntime
    let model: ModelInstance
    let user: String

    func invoke(system: String? = nil, text: String) async throws -> String {
        var parameters = model.parameters
        let stop = parameters["stop"]?.array?.compactMap(\.string) ?? []
        parameters["stop"] = nil
        for key in ["max_tokens", "max_output_tokens"] where (parameters[key]?.double ?? 1) <= 0 { parameters[key] = nil }
        var messages: [PromptMessage] = []
        if let system { messages.append(.init(role: .system, content: .text(system))) }
        messages.append(.init(role: .user, content: .text(text)))
        var result = LLMResultAccumulator()
        for try await chunk in runtime.invokeLLM(model, promptMessages: messages, parameters: parameters, tools: [], stop: stop, stream: false, user: user) {
            try Task.checkCancellation()
            try result.consume(chunk)
            guard result.text.utf8.count <= 1 << 20 else { throw NodeError("GeneratorOutputError", "Generated output is too large") }
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NodeError("GeneratorOutputError", "The model returned no text") }
        return result.text
    }
    func generateWithDeadline(kind: String, body: JSONValue, instruction: String, timeout: Duration = .seconds(120)) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await generate(kind:kind,body:body,instruction:instruction) }
            group.addTask { try await Task.sleep(for:timeout); throw NodeError("GeneratorTimeout","Generation timed out; try a shorter instruction or another model") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    static func object(_ text: String) throws -> JSONValue {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last,
              let value = try? JSONValue.parse(String(text[first...last])), value.object != nil else {
            throw NodeError("GeneratorOutputError", "The model did not return a valid JSON object")
        }
        return value
    }
    func generate(kind: String, body: JSONValue, instruction: String) async throws -> JSONValue {
        switch kind {
        case "rule-generate":
            let noVariable = body["no_variable"]?.bool == true
            let template = noVariable ? HelperPrompts.WORKFLOW_RULE_CONFIG_PROMPT_GENERATE_TEMPLATE : HelperPrompts.RULE_CONFIG_PROMPT_GENERATE_TEMPLATE
            let prompt = try await invoke(text:template.replacingOccurrences(of:"{{TASK_DESCRIPTION}}",with:instruction))
            if noVariable { return ["prompt":.string(prompt),"variables":[],"opening_statement":"","error":""] }
            let parameters = try await invoke(text:HelperPrompts.RULE_CONFIG_PARAMETER_GENERATE_TEMPLATE.replacingOccurrences(of:"{{INPUT_TEXT}}",with:prompt))
            let expression = try NSRegularExpression(pattern: #""\s*([^"]+)\s*""#)
            let variables = expression.matches(in:parameters,range:NSRange(parameters.startIndex...,in:parameters)).compactMap { match -> JSONValue? in
                guard let range=Range(match.range(at:1),in:parameters) else { return nil };return .string(String(parameters[range]))
            }
            let opening = try await invoke(text:HelperPrompts.RULE_CONFIG_STATEMENT_GENERATE_TEMPLATE.replacingOccurrences(of:"{{TASK_DESCRIPTION}}",with:instruction).replacingOccurrences(of:"{{INPUT_TEXT}}",with:prompt))
            return ["prompt":.string(prompt),"variables":.array(variables),"opening_statement":.string(opening),"error":""]
        case "rule-code-generate":
            let language = body["code_language"]?.string ?? "javascript"
            guard ["javascript", "python3"].contains(language) else { throw NodeError("GeneratorInputError", "Unsupported code language") }
            let prompt = (language == "python3" ? HelperPrompts.PYTHON_CODE_GENERATOR_PROMPT_TEMPLATE : HelperPrompts.JAVASCRIPT_CODE_GENERATOR_PROMPT_TEMPLATE)
                .replacingOccurrences(of: "{{INSTRUCTION}}", with: instruction).replacingOccurrences(of: "{{CODE_LANGUAGE}}", with: language)
            let code = try await invoke(text: prompt)
            guard !code.contains("```"), code.contains(language == "python3" ? "def main(" : "function main(") else {
                throw NodeError("GeneratorOutputError", "Return raw code with a main function")
            }
            return ["code": .string(code), "language": .string(language), "error": ""]
        case "rule-structured-output-generate":
            let schema = try Self.object(await invoke(system: HelperPrompts.SYSTEM_STRUCTURED_OUTPUT_GENERATE, text: instruction))
            try Self.validateSchema(schema)
            return ["output": .string(schema.compactJSON()), "error": ""]
        case "instruction-generate":
            let code = body["node_type"]?.string == "code" || body["language"]?.string == "python3" || body["language"]?.string == "javascript"
            let current = body["current"]?.string ?? ""
            let injected = instruction.replacingOccurrences(of: "{{#current#}}", with: current)
                .replacingOccurrences(of: "{{#last_run#}}", with: (body["last_run"] ?? .null).compactJSON()).replacingOccurrences(of: "{{#error_message#}}", with: body["last_run"]?["error"]?.string ?? "null")
            let result = try Self.object(await invoke(system: code ? HelperPrompts.LLM_MODIFY_CODE_SYSTEM : HelperPrompts.LLM_MODIFY_PROMPT_SYSTEM,
                text: JSONValue.object(["current": .string(current), "last_run": body["last_run"] ?? .null, "instruction": .string(injected), "ideal_output": body["ideal_output"] ?? .null]).compactJSON()))
            guard let modified = result["modified"]?.string, !modified.isEmpty else { throw NodeError("GeneratorOutputError","The model returned no modified content") }
            return result
        case "workflow-generate": return try await generateWorkflow(body: body, instruction: instruction)
        default: throw NodeError("GeneratorInputError", "Unsupported generator")
        }
    }
    static func validateSchema(_ value: JSONValue, depth: Int = 0) throws {
        guard depth < 32, let obj = value.object, let type = obj["type"]?.string,
              ["object", "array", "string", "number", "integer", "boolean", "null"].contains(type) else {
            throw NodeError("GeneratorOutputError", "Invalid JSON Schema type or nesting")
        }
        if let properties=obj["properties"], properties.object == nil { throw NodeError("GeneratorOutputError","Schema properties must be an object") }
        if let required=obj["required"], required.array == nil { throw NodeError("GeneratorOutputError","Schema required must be an array") }
        if let properties = obj["properties"]?.object {
            for (_, child) in properties { try validateSchema(child, depth: depth + 1) }
        }
        if let items = obj["items"] { try validateSchema(items, depth: depth + 1) }
        if type == "array", obj["items"] == nil { throw NodeError("GeneratorOutputError", "Array schemas require items") }
        if let required = obj["required"]?.array {
            guard required.allSatisfy({ $0.string != nil && obj["properties"]?.object?[$0.string!] != nil }) else {
                throw NodeError("GeneratorOutputError", "Required fields must exist in properties")
            }
        }
    }
}
