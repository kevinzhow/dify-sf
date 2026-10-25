import AsyncHTTPClient
import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

private func runAgentToolProbe(binary: String, launcher: String, input: JSONValue) async throws -> JSONValue {
    let child = Process(), incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
    child.executableURL = URL(fileURLWithPath: launcher); child.arguments = [binary]
    child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = errors
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(30))
        if !Task.isCancelled && child.isRunning { child.terminate() }
    }
    defer { watchdog.cancel() }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        child.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
        do {
            try child.run()
            incoming.fileHandleForWriting.write(Data(input.compactJSON().utf8))
            try incoming.fileHandleForWriting.close()
        } catch { continuation.resume(throwing: error) }
    }
    let output = outgoing.fileHandleForReading.readDataToEndOfFile()
    let error = errors.fileHandleForReading.readDataToEndOfFile()
    guard status == 0 else { throw NodeError("AgentTestProbeFailed", String(decoding: error, as: UTF8.self)) }
    return try JSONValue.parse(output)
}

/// Opt-in, hermetic process test: fixed agent binary + real signed provider plugin + deterministic model HTTP server.
/// These paths are fixture mounts; no account, token or running trial is reused.
@Suite("Agent model signed-plugin integration", .enabled(if: testDbHost != nil && ProcessInfo.processInfo.environment["AGENT_SERVICE_BINARY"] != nil))
struct AgentModelIntegrationTests {
    @Test func dartLoopUsesSwiftCredentialsImagesToolsAndPinnedOperation() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["AGENT_SERVICE_BINARY"])
        let launcher = try #require(ProcessInfo.processInfo.environment["AGENT_TEST_EXEC"])
        let toolDriver = try #require(ProcessInfo.processInfo.environment["AGENT_TOOL_DRIVER"])
        let daemon = try #require(ProcessInfo.processInfo.environment["AGENT_PLUGIN_DAEMON_URL"])
        let provider = try #require(ProcessInfo.processInfo.environment["AGENT_MODEL_PROVIDER_URL"])
        let recordsPath = ProcessInfo.processInfo.environment["AGENT_PROVIDER_RECORDS"] ?? "/fixture-evidence/requests.jsonl"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-joint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = runtimeConfig(daemon: daemon, key: "fixture-daemon-key", tenant: "00000000-0000-0000-0000-000000000001")
        config.agentService.url = "http://127.0.0.1:21305"
        config.agentService.key = AgentModelGatewayRouteTests.serviceKey
        config.files.directory = root.appendingPathComponent("uploads").path
        config.files.signingKey = String(repeating: "fixture-only-signing-key", count: 2)
        config.files.externalURL = "http://127.0.0.1:21306"
        config.files.internalURL = config.files.externalURL
        let frozen = config
        try await withStore { store, logger in
            let routes = try Routes(registry: DocumentRegistry(store: store, config: frozen, logger: logger),
                                    store: store, config: frozen, logger: logger)
            try await withApp(configure: { routes.register(on: $0) }) { app in
                try await app.testing(.running, options: .live(port: 21306)) { client in
                    let api = API(client: client)
                    let (_, owner, appID) = try await runtimeFixture(api, endpoint: provider)
                    // Agent models must explicitly enable tool calling in this provider's custom credentials.
                    let key = ModelKey(provider: "langgenius/openai_api_compatible/openai_api_compatible", model: "stub-chat", modelType: "llm")
                    let state = try await store.modelProviderState()
                    let credential = try #require(state.modelCredentials[key]?.first)
                    let credentialJSON = try #require(credential.config)
                    let parsedCredential = try JSONValue.parse(credentialJSON)
                    var credentials = try #require(parsedCredential.object)
                    credentials["function_calling_type"] = "tool_call"
                    credentials["agent_thought_support"] = "only_thinking_supported"
                    try await store.updateModelCredential(key, id: credential.id, name: nil, config: JSONValue.object(credentials).compactJSON())
                    let workflowID = UUID().uuidString.lowercased()
                    try await store.insertWorkflowRun(.init(id: workflowID, docId: appID, docSeq: 0, workflowId: "draft", type: "workflow",
                        triggeredFrom: "debugging", version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: owner, createdAt: Date()))
                    let imageBytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="))
                    let file = try await ServerWorkflowFiles(routes: routes, userId: owner).save(bytes: Array(imageBytes), filename: "pixel.png", mimeType: "image/png", sourceURL: nil)
                    let scope = AgentModelScope(operationID: "joint-execution:0:0", generation: 1,
                        execution: ["tenant_id": .string(frozen.pluginDaemonTenant), "app_id": .string(appID), "workflow_run_id": .string(workflowID),
                            "node_id": "agent-node", "execution_id": "joint-execution", "agent_config_snapshot_id": "joint-snapshot",
                            "user_id": .string(owner), "user_from": "account", "invoke_from": "debugger"],
                        provider: "langgenius/openai_api_compatible/openai_api_compatible", model: "stub-chat", maxCalls: 5,
                        expiresAt: Date().addingTimeInterval(90), inputFileIDs: [file.recordId], modelParameters: [:])
                    let token = try await routes.agentModelScopes.activate(scope)
                    let service = Process()
                    // Swift's async test runner blocks signals; reset them before exec so Dart receives SIGTERM.
                    service.executableURL = URL(fileURLWithPath: launcher)
                    service.arguments = [binary]
                    service.environment = ["AGENT_SERVICE_KEY": frozen.agentService.key, "AGENT_DATA_DIR": root.appendingPathComponent("sessions").path,
                        "AGENT_SERVICE_PORT": "21305", "AGENT_INNER_URL": "http://127.0.0.1:21306", "AGENT_LOG_LEVEL": "error"]
                    let logPath = root.appendingPathComponent("agent-service.log")
                    _ = FileManager.default.createFile(atPath: logPath.path, contents: nil)
                    let log = try FileHandle(forWritingTo: logPath)
                    service.standardOutput = log; service.standardError = log
                    try service.run()
                    defer {
                        if service.isRunning { service.terminate(); service.waitUntilExit() }
                        try? log.close()
                    }
                    let agent = AgentServiceClient(config: frozen.agentService)
                    var ready = false
                    for _ in 0..<100 {
                        if let (status, _) = try? await agent.request(.GET, path: "/v1/health"), status == 200 { ready = true; break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    #expect(ready, "the fixed agent binary must start successfully")
                    guard ready else { return }
                    let operation: JSONObject = ["operation_id": .string(scope.operationID), "generation": 1, "execution": .object(scope.execution),
                        "model": ["provider": .string(scope.provider), "name": .string(scope.model), "parameters": [:]],
                        "system_prompt": "Use the declared output tool.", "task": [["type": "text", "text": "fixture-output"],
                            ["type": "file", "file_id": .string(file.recordId), "mime_type": "image/png"]],
                        "output_schema": ["type": "object", "properties": ["text": ["type": "string"], "score": ["type": "number"]],
                                          "required": ["text", "score"]],
                        "tools": ["ask_human": false, "shell": false], "env": [:], "files": [],
                        "limits": ["max_turns": 5, "timeout_seconds": 60], "continuation": .null]
                    let priorCount = (try? String(contentsOfFile: recordsPath, encoding: .utf8))?.split(separator: "\n").count ?? 0
                    let runID = try await agent.start(operation, token: token)
                    let again = try await agent.start(operation, token: token)
                    #expect(runID == again, "an uncertain POST retry must address the same durable operation")
                    let final = try await agent.result(run: runID, operation: scope.operationID,
                        deadline: Date().addingTimeInterval(60), isAborted: { false })
                    #expect(final["status"] == "succeeded", "\(final.compactJSON())")
                    guard final["status"] == "succeeded" else { return }
                    #expect(final["result"]?["candidate"]?["score"] == 7)
                    #expect(final["result"]?["candidate"]?["text"] == "joint fixture answer")
                    #expect(!final.compactJSON().contains("sk-stub-not-a-real-key"))
                    // Even a valid operation token cannot request arbitrary URLs or another execution's file.
                    for foreign in ["http://127.0.0.1/private", "dify-sf-file:" + UUID().uuidString.lowercased()] {
                        var invalid = try #require(try JSONValue.parse(AgentModelGatewayRouteTests.body(scope, call: 2)).object)
                        var target = try #require(invalid["target"]?.object)
                        target["prompt_messages"] = [["role": "user", "content": [["type": "image", "url": .string(foreign), "mime_type": "image/png"]]]]
                        invalid["target"] = .object(target)
                        let denied = try await api.send(.post, AgentModelGatewayRouteTests.path, JSONValue.object(invalid).compactJSON(),
                            token: frozen.agentService.key, headers: [("X-Agent-Run-Token", token)])
                        #expect(denied.status == 422)
                        #expect(try JSONValue.parse(denied.text)["error"] == "file_error")
                    }
                    let usage = await routes.agentModelScopes.revoke(token: token)
                    #expect(usage.totalTokens > 0)
                    let records = try String(contentsOfFile: recordsPath, encoding: .utf8)
                    #expect(records.split(separator: "\n").count == priorCount + 1)
                    let last = try JSONValue.parse(try #require(records.split(separator: "\n").last).description)
                    #expect(last["tools"]?.array?.contains { $0["function"]?["name"] == "final_output" } == true)
                    let content = last["messages"]?.array?.flatMap { $0["content"]?.array ?? [] } ?? []
                    let imageReachedProvider = content.contains { $0["image_url"]?["url"]?.string == "data:image/png;base64," + imageBytes.base64EncodedString() }
                    #expect(imageReachedProvider)
                    try await agent.acknowledge(run: runID, generation: 1, event: try #require(final["last_event_id"]?.int))
                    try await agent.cleanup(execution: "joint-execution", generation: 1)
                    var toolScope = scope
                    toolScope.operationID = "tool-execution:0:0"; toolScope.execution["execution_id"] = "tool-execution"
                    toolScope.inputFileIDs = []
                    let toolToken = try await routes.agentModelScopes.activate(toolScope)
                    var toolOperation = operation
                    toolOperation["protocol"] = .string(AgentServiceClient.protocolName)
                    toolOperation["operation_id"] = .string(toolScope.operationID); toolOperation["execution"] = .object(toolScope.execution)
                    toolOperation["task"] = [["type": "text", "text": "fixture-interleaved"]]; toolOperation["output_schema"] = .null
                    let probe = try await runAgentToolProbe(binary: toolDriver, launcher: launcher, input: [
                        "operation": .object(toolOperation), "inner_url": "http://127.0.0.1:21306",
                        "service_key": .string(frozen.agentService.key), "run_token": .string(toolToken)])
                    #expect(probe["text"] == "joint fixture answer")
                    #expect(probe["reasoning"]?.array?.contains("fixture thought") == true)
                    #expect(probe["reasoning"]?.array?.contains("tool thought") == true)
                    #expect(probe["text"]?.string?.contains("thought") == false)
                    let calls = try #require(probe["calls"]?.array)
                    #expect(calls.count == 2)
                    #expect(calls.first { $0["name"] == "a" }?["input"]?["a"] == 1)
                    #expect(calls.first { $0["name"] == "b" }?["input"]?["b"] == 2)
                    #expect(probe["invocations"]?.array?.count == 2)
                    #expect(probe.compactJSON().contains("opaque/a") && probe.compactJSON().contains("opaque/b"))
                    let toolUsage = await routes.agentModelScopes.revoke(token: toolToken)
                    #expect(toolUsage.totalTokens > 0)
                    let allRecords = try String(contentsOfFile: recordsPath, encoding: .utf8).split(separator: "\n")
                    #expect(allRecords.count == priorCount + 3)
                    let lastToolRequest = try JSONValue.parse(try #require(allRecords.last).description)
                    let returnedIDs = lastToolRequest["messages"]?.array?.filter { $0["role"] == "tool" }.compactMap { $0["tool_call_id"]?.string } ?? []
                    let assistantHistory = lastToolRequest["messages"]?.array?.filter { $0["role"] == "assistant" } ?? []
                    // The signed plugin deliberately drops prior think blocks before sending history to its vendor.
                    #expect(!assistantHistory.contains { $0["content"]?.string?.contains("tool thought") == true })
                    let bridgeHistory = probe["requests"]?.array?.last?["target"]?["prompt_messages"]?.array ?? []
                    #expect(bridgeHistory.contains { $0["role"] == "assistant" && $0["content"]?.string?.contains("tool thought") == true })
                    #expect(Set(returnedIDs) == ["opaque/a", "opaque/b"])

                }
            }
        }
    }
}
