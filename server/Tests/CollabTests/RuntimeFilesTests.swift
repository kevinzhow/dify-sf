import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

/// Byte-preserving scoped service; the DB-backed adapter has separate route/isolation tests.
final class TestRuntimeFiles: RuntimeFiles, Sendable {
    let file: RuntimeFile
    let content: [UInt8]
    let reads = Mutex(0)
    let saves = Mutex<[[UInt8]]>([])
    init(_ content: [UInt8] = [0x89, 0x50, 0, 255]) {
        self.content = content
        file = RuntimeFile(recordId: "00000000-0000-4000-8000-000000000013", type: "image", filename: "图片.png",
                           extensionName: "png", mimeType: "image/png", size: content.count, url: "https://fresh.test/file")
    }
    func resolve(_ mapping: JSONValue, config: JSONObject?) async throws -> RuntimeFile {
        guard RuntimeFile.recordId(in: mapping) == file.recordId else { throw RuntimeFileError("File not found") }
        try RuntimeFile.validate(file, config: config)
        return file
    }
    func bytes(_ mapping: JSONValue) async throws -> [UInt8] {
        _ = try await resolve(mapping, config: nil)
        reads.withLock { $0 += 1 }
        return content
    }
    func save(bytes: [UInt8], filename: String, mimeType: String, sourceURL: String?) async throws -> RuntimeFile {
        saves.withLock { $0.append(bytes) }
        return file
    }
}

@Suite("Runtime file values and consumers")
struct RuntimeFilesTests {
    @Test func fileIdentityAttributesAndMarkdownMatchGraphon() async throws {
        let f = TestRuntimeFiles().file.json
        #expect(Segment.build(f).valueType == .file)
        #expect(Segment.build(.array([f])).valueType == .arrayFile)
        #expect(Segment.build(f).text.isEmpty && Segment.build(f).log.isEmpty)
        #expect(Segment.build(f).markdown == "![图片.png](https://fresh.test/file)")
        var pool = VariablePool()
        try pool.add(["start", "picture"], f)
        #expect(pool.get(["start", "picture", "name"])?.value == "图片.png")
        #expect(pool.get(["start", "picture", "size"])?.value == 4)
        #expect(pool.get(["start", "picture", "reference"]) == nil)
        #expect(pool.get(["start", "picture", "storage_key"]) == nil)
        #expect(RuntimeFile.recordId(in: f) == TestRuntimeFiles().file.recordId)
        #expect(RuntimeFile.recordId(in: ["id": .string(TestRuntimeFiles().file.recordId)]) == nil)
        let malicious = Data("{\"record_id\":\"00000000-0000-4000-8000-000000000013\",\"storage_key\":\"../../etc/passwd\"}".utf8).base64EncodedString()
        #expect(RuntimeFile.recordId(in: ["reference": .string("dify-file-ref:" + malicious)]) == TestRuntimeFiles().file.recordId)
    }

    @Test func formValidatesTypeMethodCountAndUsesFileMarkdown() async throws {
        let files = TestRuntimeFiles()
        let form = try HumanInputFormConfig(["form_content": "Picked {{#$output.file#}}", "inputs": [
            ["type": "file", "output_variable_name": "file", "allowed_file_types": ["image"], "allowed_file_upload_methods": ["local_file"]]],
            "user_actions": [["id": "ok", "title": "Confirm"]]])
        let raw: JSONObject = ["file": ["transfer_method": "local_file", "upload_file_id": .string(files.file.recordId)]]
        await #expect(throws: HumanInputFormConfig.InvalidSubmission.self) { try await form.normalizedFiles(raw, using: nil) }
        let normalized = try await form.normalizedFiles(raw, using: files)
        let result = try form.completion(action: "ok", values: normalized, renderedContent: form.content)
        #expect(result.outputs["__rendered_content"] == "Picked ![图片.png](https://fresh.test/file)")
        await #expect(throws: RuntimeFileError.self) {
            try await files.resolve(files.file.json, config: ["allowed_file_types": ["document"]])
        }
        await #expect(throws: RuntimeFileError.self) {
            try await files.resolveList([files.file.json, files.file.json], config: ["number_limits": 1])
        }
        await #expect(throws: RuntimeFileError.self) {
            try await files.resolveList([files.file.json, files.file.json], config: ["number_limits": 3, "image": ["number_limits": 1]])
        }
        var stale = files.file.json.object!
        stale["url"] = "https://expired.test"
        var p = VariablePool()
        try p.add(["start", "file"], .object(stale))
        try await p.materializeFiles(using: files)
        #expect(p.get(["start", "file", "url"])?.value == "https://fresh.test/file")
    }

    @Test(arguments: ["binary", "form-data"]) func HTTPTransmitsExactBinaryAndPersistsFileResponse(_ kind: String) async throws {
        let files = TestRuntimeFiles()
        let http = FakeHTTP { _ in RuntimeHTTPResponse(status: 200, headers: [("Content-Type", "image/png")], body: [0, 255, 10]) }
        let body: JSONValue = ["type": .string(kind), "data": [["type": "file", "key": "upload", "file": ["start", "file"]]]]
        let node = try HTTPRequestNode(id: "h", data: RuntimeHTTPNodeTests().data(method: "post", body: body), client: http, files: files)
        var p = VariablePool()
        try p.add(["start", "file"], files.file.json)
        let result = await runNode(node, pool: p).0
        #expect(result.status == .succeeded, "\(result.error)")
        let sent = try #require(http.requests.withLock { $0.first })
        if kind == "binary" { #expect(sent.body == files.content) }
        else {
            let bytes = sent.body ?? []
            #expect(Data(bytes).range(of: Data(files.content)) != nil)
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(text.contains("name=\"upload\"") && text.contains("Content-Type: image/png"))
        }
        #expect(files.saves.withLock { $0 } == [[0, 255, 10]])
        #expect(result.outputs["body"] == "")
        #expect(Segment.build(result.outputs["files"] ?? .null).valueType == .arrayFile)
    }

    @Test(arguments: [true, false]) func visionUsesActualBytesDetailAndModelCapability(_ supported: Bool) async throws {
        let files = TestRuntimeFiles()
        let models = ScriptedModels(["ok"], features: supported ? ["vision"] : [])
        let data: JSONObject = ["type": "llm", "title": "Vision", "model": .object(stubModel),
                               "prompt_template": [["role": "user", "text": "Describe the picture"]],
                               "context": ["enabled": false, "variable_selector": []], "vision": ["enabled": true, "configs": ["variable_selector": ["start", "image"], "detail": "low"]]]
        let graph = try graph([("n", data)])
        let node = try await BuiltinNodeFactory(services: RuntimeServices(models: models, files: files)).createNode(graph.node("n")!, graph: graph)
        var p = VariablePool()
        try p.add(["start", "image"], files.file.json)
        let r = await runNode(node, pool: p).0
        #expect(r.status == .succeeded, "\(r.error)")
        let messages = try #require(models.recorded.first?.messages)
        let parts = messages.flatMap { m -> [PromptMessageContent] in if case .parts(let p) = m.content { return p }; return [] }
        let images = parts.filter { $0.type == "image" }
        #expect(images.count == (supported ? 1 : 0))
        #expect(files.reads.withLock { $0 } == (supported ? 1 : 0))
        if let image = images.first {
            #expect(image.json["base64_data"] == .string(Data(files.content).base64EncodedString()))
            #expect(image.json["detail"] == "low" && image.json["mime_type"] == "image/png")
            #expect(image.json["url"] == "")
            let saved = r.processData["prompts"]?.array?.flatMap { $0["files"]?.array ?? [] } ?? []
            #expect(saved.first?["detail"] == "low" && saved.first?["data"]?.string?.contains("...[TRUNCATED]...") == true)
        }
    }

    @Test func inlineImagesUseSeparatePromptPartsEvenWithVisionSwitchOff() async throws {
        let files = TestRuntimeFiles()
        let models = ScriptedModels(["ok"], features: ["vision"])
        let data: JSONObject = ["type": "llm", "title": "Inline image", "model": .object(stubModel),
                               "context": ["enabled": false, "variable_selector": []],
                               "prompt_template": [["role": "user", "text": "Inspect {{#start.image#}}"]],
                               "vision": ["enabled": false]]
        let g = try graph([("n", data)])
        let node = try await BuiltinNodeFactory(services: RuntimeServices(models: models, files: files)).createNode(g.node("n")!, graph: g)
        var p = VariablePool(); try p.add(["start", "image"], files.file.json)
        let r = await runNode(node, pool: p).0
        #expect(r.status == .succeeded, "\(r.error)")
        let messages = try #require(models.recorded.first?.messages)
        #expect(messages.count == 2 && messages[0].textContent == "Inspect ")
        if case .parts(let parts) = messages[1].content {
            #expect(parts.count == 1 && parts[0].type == "image" && parts[0].json["detail"] == "high")
        } else { Issue.record("Inline file was not sent as image content") }
    }

    @Test func imageBudgetCoversAllPromptMessagesAndVisionSelectorBeforeInvocation() async throws {
        let files = TestRuntimeFiles(Array(repeating: 0x50, count: 6 * 1024 * 1024))
        let models = ScriptedModels(["must never invoke"], features: ["vision"])
        let data: JSONObject = ["type": "llm", "title": "Budget", "model": .object(stubModel),
                               "context": ["enabled": false, "variable_selector": []],
                               "prompt_template": [["role": "user", "text": "{{#start.image#}}{{#start.image#}}{{#start.image#}}"]],
                               "vision": ["enabled": true, "configs": ["variable_selector": ["start", "image"], "detail": "low"]]]
        let g = try graph([("n", data)])
        let node = try await BuiltinNodeFactory(services: RuntimeServices(models: models, files: files)).createNode(g.node("n")!, graph: g)
        var p = VariablePool(); try p.add(["start", "image"], files.file.json)
        let r = await runNode(node, pool: p).0
        #expect(r.status == .failed && r.error.contains("total image size limit"))
        #expect(models.recorded.isEmpty)
        #expect(files.reads.withLock { $0 } == 3)
    }

    @Test func fileShapedNestedJSONIsNotAnUploadRequest() async throws {
        let files = TestRuntimeFiles()
        let raw: JSONValue = ["transfer_method": "remote_url", "url": "https://ordinary-json.test/value"]
        #expect(try await files.canonicalize(raw, allowInputMappings: true) == raw)
        let object: JSONValue = ["payload": raw]
        #expect(try await files.canonicalize(object, allowInputMappings: true) == object)
        let mixed: JSONValue = ["normal JSON", raw]
        #expect(try await files.canonicalize(mixed, allowInputMappings: true) == mixed)
        // Durable identities nested in JSON still materialize through the adapter, unlike raw input mappings.
        var stale = files.file.json.object!; stale["url"] = "https://expired.test"
        let materialized = try await files.canonicalize(["payload": .object(stale)])
        #expect(materialized["payload"]?["url"] == "https://fresh.test/file")
    }

    @Test func multipartCannotSilentlyDropASelectedFileWhenStorageIsMissing() async throws {
        let file = TestRuntimeFiles().file.json
        let http = FakeHTTP { _ in FakeHTTP.json("{}") }
        let body: JSONValue = ["type": "form-data", "data": [["type": "file", "key": "attachment", "file": ["start", "file"]]]]
        let node = try HTTPRequestNode(id: "h", data: RuntimeHTTPNodeTests().data(method: "post", body: body), client: http)
        var p = VariablePool(); try p.add(["start", "file"], file)
        let result = await runNode(node, pool: p).0
        #expect(result.status == .failed && result.errorType == "FileFetchError")
        #expect(http.requests.withLock { $0 }.isEmpty)
    }
}
