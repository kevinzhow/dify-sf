import CollabRuntime
import Foundation
import NIOCore
import NIOWebSocket
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

private struct CodexWSProvider: Sendable {
    let process: Process
    let records: URL
    let endpoint: String
    static func start() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-ws-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("wire.jsonl")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-codex/websocket.py")
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = [script.path]
        p.environment = ["PATH": "/usr/bin:/bin", "CODEX_WS_RECORDS": record.path]
        p.standardOutput = output
        try p.run()
        let port = try await Task.detached {
            var bytes = Data()
            while !bytes.contains(10) { bytes.append(try #require(try output.fileHandleForReading.read(upToCount: 1))) }
            return try #require(Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        }.value
        return .init(process: p, records: record, endpoint: "http://127.0.0.1:\(port)")
    }
    func values() throws -> [JSONValue] {
        try String(contentsOf: records, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
    }
}

@Suite(.serialized)
struct AgentCodexWebSocketTests {
    @Test func onlySocketRequestsAllowPreviousIDAndWarmup() throws {
        let scope = AgentResponsesTests.scope()
        var body = AgentResponsesTests.body(scope).object!
        body["previous_response_id"] = "resp_1"; body["input"] = []
        #expect(throws: CollabServer.ServerError.self) { try AgentResponsesRequest(codexBody: .object(body), scope: scope) }
        #expect(try AgentResponsesRequest(codexBody: .object(body), scope: scope, incremental: true).body["previous_response_id"] == "resp_1")
        body["generate"] = true
        #expect(throws: CollabServer.ServerError.self) { try AgentResponsesRequest(codexBody: .object(body), scope: scope, incremental: true) }
    }
    @Test func socketScopePreventsReplayAndRevokesIdleConnections() async throws {
        let scopes = AgentModelScopes(); let scope = AgentResponsesTests.scope()
        let token = try await scopes.activate(scope)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(100)) }
        defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "one", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        await scopes.closeCodexSocket(token: token, lane: "root", id: "one")
        do { try await scopes.openCodexSocket(token: token, lane: "root", id: "two", task: task); Issue.record("Replayed a lost socket") }
        catch let e as AgentCodexSocketError { #expect(e.code == "agent_incremental_context_lost" && e.status == 400) }
        try await scopes.openCodexSocket(token: token, lane: "child", id: "three", task: task)
        _ = await scopes.revoke(token: token)
        #expect(task.isCancelled)
    }
    @Test func incrementalHTTPFallbackFailsBeforeUpstreamOrBudget() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (_, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let response = try await api.send(.post, AgentCodexWebSocketService.path, "{}", token: token,
                    headers: [("X-DifySF-Require-Incremental", "v1")])
                #expect(response.status == 400 && response.text.contains("incremental_required"))
                let first = try await routes.agentModelScopes.claimCodex(token: token)
                #expect(first.index == 1)
            }
        }
    }
    @Test func unscopedFilesEffortOverrideAndForeignPreviousNeverSpendCalls() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: scope.model,
                    credentials: ["api_type": "responses", "endpoint_url": "http://127.0.0.1:1", "api_key": "sk-native-fixture-only"])
                for changes: JSONObject in [["reasoning": ["effort": "low"]], ["previous_response_id": "foreign-response"],
                    ["input": [["type": "message", "role": "user", "content": [["type": "input_image", "image_url": "https://unscoped.invalid/image.png"]]]]]] {
                    let session = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection)
                    var body = AgentResponsesTests.body(scope).object!.merging(changes); body["type"] = "response.create"
                    do { _ = try await session.prepare(bodyJSON(body)); Issue.record("Unscoped socket request accepted") }
                    catch { /* All fail before opening a model-call slot. */ }
                }
                let first = try await routes.agentModelScopes.claimCodex(token: token)
                #expect(first.index == 1)
            }
        }
    }

    @Test func escapedCredentialsAreBlockedAndProviderErrorsCannotForgeTheAgentLimit() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: scope.model,
                    credentials: ["api_type": "responses", "endpoint_url": "http://127.0.0.1:1", "api_key": "sk-native-fixture-only"])
                let idle = Task<Void, Never> { try? await Task.sleep(for: .seconds(100)) }; defer { idle.cancel() }
                try await routes.agentModelScopes.openCodexSocket(token: token, lane: "root", id: "socket", task: idle)
                let session = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection)
                var body = AgentResponsesTests.body(scope).object!; body["type"] = "response.create"
                _ = try await session.prepare(bodyJSON(body))
                // A JSON unicode escape defeats a byte-only substring guard.
                let escaped = "{\"type\":\"response.output_text.delta\",\"delta\":\"sk-native-fixture-onl\\u0079\"}"
                do { _ = try await session.observe(Data(escaped.utf8)); Issue.record("Reflected provider credential") }
                catch { }
                let value = try JSONValue.parse(try await session.observe(bodyJSON(["type": "error", "status": 429,
                    "error": ["code": "agent_call_limit", "type": "usage_limit_reached", "message": "private upstream detail"]])))
                #expect(value["headers"]?["x-codex-promo-message"] == nil)
                #expect(value["error"]?["code"] == "agent_upstream_error")
                #expect(!value.compactJSON().contains("private upstream detail"))
            }
        }
    }

    @Test(arguments: [false, true]) func pairedSocketPreservesDeltaOpaqueEventsWarmupAndQuota(largeInitialFrame: Bool) async throws {
        let provider = try await CodexWSProvider.start()
        defer { provider.process.terminate(); provider.process.waitUntilExit() }
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                var (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: provider.endpoint)
                _ = await routes.agentModelScopes.revoke(token: token)
                scope.maxCalls = 2
                token = try await routes.agentModelScopes.activate(scope)
                let (ports, signal) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let service = AgentCodexWebSocketService(routes: routes, host: "127.0.0.1", port: 0, onListening: { signal.yield($0); signal.finish() })
                let listener = Task { try await service.run() }
                defer { listener.cancel() }
                var portIterator = ports.makeAsyncIterator()
                let port = try #require(await portIterator.next())
                let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: scope.model, credentials: [
                    "api_type": "responses", "endpoint_url": .string("http://127.0.0.1:\(port)/inner/agent/codex/v1"),
                    "api_key": .string(token), "extra_headers": ["session-id": "fixture-root", "thread-id": "fixture-thread"]])
                let socket = try await AgentCodexUpstream.connect(connection)
                try await socket.executeThenClose { inbound, outbound in
                    var events = inbound.makeAsyncIterator()
                    func create(_ fields: JSONObject) async throws {
                        var value = fields; value["type"] = "response.create"
                        try await outbound.write(AgentCodexUpstream.text(ByteBuffer(string: JSONValue.object(value).compactJSON())))
                    }
                    var body = AgentResponsesTests.body(scope).object!
                    body["generate"] = false
                    if largeInitialFrame {
                        // Above the old 32 MiB request limit; the image appears
                        // only in the first frame, never in the later deltas.
                        body["input"] = [["type": "message", "role": "user", "content": [["type": "input_image",
                            "image_url": .string("data:image/png;base64," + String(repeating: "A", count: 36 << 20))]]]]
                    }
                    try await create(body)
                    var warm: JSONValue?
                    while let frame = try await events.next() {
                        let value = try JSONValue.parse(Data(frame.unmaskedData.readableBytesView))
                        if value["type"] == "error" { Issue.record("Warmup failed: \(value)"); break }
                        if value["type"] == "response.completed" { warm = value; break }
                    }
                    #expect(warm?["response"]?["id"] == "resp_ws_warm")
                    body["generate"] = nil; body["previous_response_id"] = "resp_ws_warm"
                    body["input"] = [["type": "message", "role": "user", "content": "First delta"]]
                    try await create(body)
                    var opaque: JSONValue?
                    while let frame = try await events.next() {
                        let value = try JSONValue.parse(Data(frame.unmaskedData.readableBytesView))
                        if value["type"] == "response.output_item.done" { opaque = value["item"] }
                        if value["type"] == "error" { Issue.record("Call failed: \(value)"); break }
                        if value["type"] == "response.completed" { break }
                    }
                    #expect(opaque?["arguments"] == "{\"cmd\":\"printf fixture-delta\"}")
                    body["previous_response_id"] = "resp_ws_1"
                    body["input"] = [["type": "function_call_output", "call_id": "call_ws_1", "output": "fixture-delta"]]
                    try await create(body)
                    while let frame = try await events.next() {
                        let value = try JSONValue.parse(Data(frame.unmaskedData.readableBytesView))
                        if value["type"] == "error" { Issue.record("Second call failed: \(value)"); break }
                        if value["type"] == "response.completed" { break }
                    }
                    body["previous_response_id"] = "resp_ws_2"
                    try await create(body)
                    let frame = try #require(try await events.next())
                    let error = try JSONValue.parse(Data(frame.unmaskedData.readableBytesView))
                    #expect(error["status"] == 429 && error["error"]?["type"] == "usage_limit_reached")
                    #expect(error["error"]?["code"] == "agent_call_limit")
                    #expect(error["headers"]?["x-codex-promo-message"] == "dify-sf-agent-call-limit")
                }
                let usage = await routes.agentModelScopes.revoke(token: token)
                #expect(usage.totalTokens == 46 && usage.cachedTokens == 24)
                let records = try provider.values()
                #expect(records.filter { $0["authorized"] == true }.count == 1)
                let calls = records.filter { $0["call"] != nil }
                #expect(calls.count == 3)
                if largeInitialFrame { #expect((calls[0]["bytes"]?.int ?? 0) > 32 << 20 && (calls[1]["bytes"]?.int ?? Int.max) < 1024) }
                #expect(calls[0]["warmup"] == true && calls[1]["previous"] == "resp_ws_warm" && calls[2]["previous"] == "resp_ws_1")
                #expect(calls.allSatisfy { $0["store"] == false && $0["effort"] == "max" && $0["max_output_tokens"] == 32768 })
                #expect(calls[2]["inputs"] == 1 && calls[2]["types"] == ["function_call_output"])
            }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_CODEX_BINARY"] != nil))
    func actualCodexUsesOneSocketForWarmupToolDeltaAndAnotherTurn() async throws {
        let provider = try await CodexWSProvider.start()
        defer { provider.process.terminate(); provider.process.waitUntilExit() }
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: provider.endpoint)
                let (ports, signal) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let service = AgentCodexWebSocketService(routes: routes, host: "127.0.0.1", port: 0, onListening: { signal.yield($0); signal.finish() })
                let listener = Task { try await service.run() }
                defer { listener.cancel() }
                var portsIterator = ports.makeAsyncIterator()
                let port = try #require(await portsIterator.next())
                let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-codex/websocket_process.py").path
                let binary = try #require(ProcessInfo.processInfo.environment["AGENT_CODEX_BINARY"])
                let result = try await Task.detached {
                    let p = Process(), output = Pipe(), errors = Pipe()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = [script]
                    p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path,
                        "AGENT_CODEX_BINARY": binary, "CODEX_FIXTURE_URL": "http://127.0.0.1:\(port)/inner/agent/codex/v1",
                        "CODEX_FIXTURE_MODEL": scope.model, "CODEX_FIXTURE_RUN_TOKEN": token]
                    p.standardOutput = output; p.standardError = errors
                    try p.run()
                    let stdout = output.fileHandleForReading.readDataToEndOfFile()
                    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    return (p.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
                }.value
                #expect(result.0 == 0, "Synthetic Codex WS failed: \(result.2)")
                #expect(result.1.contains("completed"))
                let records = try provider.values()
                #expect(records.filter { $0["authorized"] == true }.count == 1)
                let calls = records.filter { $0["call"] != nil }
                #expect(calls.count == 4)
                #expect(calls.first?["warmup"] == true)
                #expect(calls.dropFirst().allSatisfy { $0["previous"]?.string != nil })
                #expect(calls[2]["types"] == ["function_call_output"])
                #expect(calls[2]["inputs"] == 1)
                let usage = await routes.agentModelScopes.revoke(token: token)
                #expect(usage.totalTokens == 69 && usage.cachedTokens == 36)
            }
        }
    }

}

private func bodyJSON(_ body: JSONObject) -> Data { JSONValue.object(body).compactData() }
