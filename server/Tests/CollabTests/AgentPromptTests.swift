import CollabRuntime
import Foundation
import Testing

private struct AgentPromptFiles: RuntimeFiles {
    let files: [String: RuntimeFile]
    func resolve(_ mapping: JSONValue, config: JSONObject?) async throws -> RuntimeFile {
        guard let id = RuntimeFile.recordId(in: mapping), let file = files[id] else { throw RuntimeFileError("Missing fixture file") }
        return file
    }
    func bytes(_ file: JSONValue) async throws -> [UInt8] { [] }
    func save(bytes: [UInt8], filename: String, mimeType: String, sourceURL: String?) async throws -> RuntimeFile {
        throw RuntimeFileError("This fixture is read-only")
    }
}

@Suite("Agent task inputs and file budget")
struct AgentPromptTests {
    static func node(task: String) throws -> AgentNodeData {
        try AgentNodeData(["type": "agent", "version": "2", "agent_node_kind": "dify_agent",
            "agent_binding": ["binding_type": "inline_agent", "agent_id": "private", "current_snapshot_id": "frozen"],
            "agent_task": .string(task), "agent_declared_outputs": [["name": "score", "type": "number"]]])
    }
    @Test func runtimeContextUsesActualNodeIDsAndStableFilesWithoutSoulSecrets() async throws {
        let id = UUID().uuidString.lowercased()
        let image = RuntimeFile(recordId: id, type: "image", filename: "photo.png", extensionName: "png", mimeType: "image/png", size: 4,
            url: "https://expired.invalid/private-signed-url")
        var pool = VariablePool()
        try pool.add(["start-a", "q"], .string("Current run"))
        try pool.add(["start-a", "picture"], image.json)
        try pool.add(["sys", "query"], .string("User query"))
        var soul = AgentInlineConfig.empty
        soul["prompt"] = ["system_prompt": .string("Read [§file:spec.png:Spec§] and ask [§human:reviewer:Person§]")]
        soul["config_files"] = [["name": "spec.png", "file_kind": "upload_file", "file_id": .string(id)]]
        soul["human"] = ["contacts": [["id": "reviewer", "name": "Reviewer"]], "tools": []]
        soul["env"] = ["variables": [], "secret_refs": [["name": "TOKEN", "value": "fixture-hidden-secret"]]]
        let node = try Self.node(task: "Check {{#start-a.q#}} {{#start-a.picture#}} and [§score:Score:output§] plus §output:score:Score§")
        let built = try await AgentPromptBuilder.build(node: node, config: AgentInlineConfig(soul), pool: pool,
            files: AgentPromptFiles(files: [id: image]))
        let text = JSONValue.array(built.task).compactJSON()
        #expect(text.contains("Current run") && text.contains("User query") && text.contains("score (number)"))
        #expect(!text.contains("private-signed-url") && !text.contains("fixture-hidden-secret"))
        #expect(!built.system.contains("Current run") && built.system.contains("files/spec.png") && built.system.contains("Reviewer"))
        #expect(built.inputFileIDs == [id])
        #expect(built.task.filter { $0["type"] == "file" }.count == 1)
        #expect(built.files.count == 2, "one input path and one explicitly named config path")
    }
    @Test func savedNodeJobContextAndFileRefsAreResolved() async throws {
        let id = UUID().uuidString.lowercased()
        let image = RuntimeFile(recordId: id, type: "image", filename: "photo.png", extensionName: "png", mimeType: "image/png", size: 4, url: "")
        var pool = VariablePool()
        try pool.add(["previous-node", "details"], ["label": "Loaded explicitly"])
        let built = try await AgentPromptBuilder.build(node: Self.node(task: "Read the context"), config: AgentInlineConfig(AgentInlineConfig.empty),
            pool: pool, files: AgentPromptFiles(files: [id: image]), nodeJob: [
                "previous_node_output_refs": [["selector": ["previous-node", "details"]]],
                "metadata": ["file_refs": [["file_id": .string(id)]]]])
        #expect(JSONValue.array(built.task).compactJSON().contains("Loaded explicitly"))
        #expect(built.inputFileIDs == [id])
    }
    @Test func missingInputsAndOverBudgetImagesFailBeforeCallingTheAgent() async throws {
        do {
            _ = try await AgentPromptBuilder.build(node: Self.node(task: "{{#missing-node.value#}}"),
                config: AgentInlineConfig(AgentInlineConfig.empty), pool: VariablePool(), files: nil)
            Issue.record("Missing previous-node data must reject preparation")
        } catch let error as NodeError { #expect(error.errorTypeName == "MissingPreviousNodeOutput") }
        let id = UUID().uuidString.lowercased()
        let image = RuntimeFile(recordId: id, type: "image", filename: "large.png", extensionName: "png", mimeType: "image/png", size: 7 << 20, url: "")
        var pool = VariablePool()
        try pool.add(["sys", "files"], .array([image.json]))
        do {
            _ = try await AgentPromptBuilder.build(node: Self.node(task: "Read image"), config: AgentInlineConfig(AgentInlineConfig.empty),
                pool: pool, files: AgentPromptFiles(files: [id: image]))
            Issue.record("Oversized initial images must reject preparation")
        } catch let error as NodeError { #expect(error.errorTypeName == "AgentFileBudgetExceeded") }
    }
}
