import AsyncHTTPClient
import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import NIOCore
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Agent native Responses wire")
struct AgentResponsesTests {
    static func scope() -> AgentModelScope {
        var scope = AgentModelScopeTests.scope()
        scope.provider = AgentModelWire.compatible
        scope.harnessStyle = "codex"; scope.modelWire = "responses"
        scope.modelParameters = ["reasoning_effort": "max", "max_tokens": 32768]
        return scope
    }
    static func body(_ scope: AgentModelScope) -> JSONValue {
        ["model": .string(scope.model), "input": [["role": "user", "content": "Synthetic fixture"]],
         "tools": [["type": "custom", "name": "apply_patch", "format": ["type": "text"]]],
         "reasoning": ["effort": "max", "summary": "auto"], "stream": true, "store": false,
         "include": ["reasoning.encrypted_content"], "prompt_cache_key": .string(scope.executionID)]
    }
    static let stream = ": heartbeat\r\nevent: response.output_item.done\r\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"opaque-fixture-ONLY\",\"future_field\":17}}\r\n\r\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":20,\"output_tokens\":30,\"total_tokens\":50,\"input_tokens_details\":{\"cached_tokens\":12},\"output_tokens_details\":{\"reasoning_tokens\":19}}}}\n\n"

    @Test func onlyScopedModelEffortAndBudgetsAreForwarded() throws {
        let scope = Self.scope()
        let request = try AgentResponsesRequest(body: Self.body(scope), index: "1", invocation: "run:1", attempt: nil, scope: scope)
        #expect(request.body["max_output_tokens"] == 32768)
        #expect(request.body["reasoning"]?["effort"] == "max")
        for index in [nil, "0", "01", "1.5"] as [String?] {
            #expect(throws: CollabServer.ServerError.self) { try AgentResponsesRequest(body: Self.body(scope), index: index, invocation: "run:1", attempt: nil, scope: scope) }
        }
        for changes in [["model": "other"], ["reasoning": ["effort": "high"]], ["max_output_tokens": 999999],
                                   ["previous_response_id": "other-run"], ["tools": [["type": "web_search"]]], ["store": true]] as [JSONObject] {
            #expect(throws: CollabServer.ServerError.self) {
                try AgentResponsesRequest(body: .object(Self.body(scope).object!.merging(changes)), index: "1", invocation: "run:1", attempt: nil, scope: scope)
            }
        }
        var plugin = scope; plugin.modelWire = "plugin"
        #expect(throws: CollabServer.ServerError.self) { try AgentResponsesRequest(body: Self.body(scope), index: "1", invocation: "run:1", attempt: nil, scope: plugin) }
    }

    @Test func credentialsOwnTheDestinationHeadersAndVendorAlias() throws {
        for base in ["http://localhost:9000", "http://localhost:9000/", "http://localhost:9000/v1/"] {
            let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: "alias", credentials: [
                "api_type": "responses", "endpoint_url": .string(base), "api_key": "fixture-secret", "endpoint_model_name": "vendor-name",
                "extra_headers": "{\"X-Fixture\":\"fixture-header\",\"Authorization\":\"ignored\"}"])
            #expect(connection.url == "http://localhost:9000/v1/responses")
            #expect(connection.model == "vendor-name")
            #expect(connection.headers["Authorization"] == "Bearer fixture-secret")
            #expect(connection.headers["X-Fixture"] == "fixture-header")
        }
        #expect(AgentModelWire.select(style: "dify", provider: AgentModelWire.openAI, credentials: [:]) == "plugin")
        #expect(AgentModelWire.select(style: "codex", provider: AgentModelWire.compatible, credentials: ["api_type": "chat_completions"]) == "plugin")
        #expect(AgentModelWire.select(style: "codex", provider: AgentModelWire.openAI, credentials: [:]) == "responses")
        for url in ["file:///private", "https://user:password@example.test", "https://example.test?key=secret", "https://example.test/#fragment"] {
            #expect(throws: CollabServer.ServerError.self) { try AgentResponsesConnection(provider: AgentModelWire.compatible, model: "fixture", credentials: ["api_type": "responses", "endpoint_url": .string(url)]) }
        }
    }

    @Test func usageObserverAndCredentialGuardWorkAcrossEveryChunkBoundary() throws {
        let bytes = Array(Self.stream.utf8)
        for split in 0...bytes.count {
            var parser = AgentResponsesSSE(), guarder = AgentResponsesSecretGuard(["fixture-secret-DO-NOT-REFLECT"])
            let a = Array(bytes[..<split]), b = Array(bytes[split...])
            try parser.consume(a); try parser.consume(b)
            let forwarded = try guarder.consume(a) + guarder.consume(b) + guarder.consume([], final: true)
            #expect(forwarded == Data(bytes))
            #expect(parser.terminal && !parser.failed)
            #expect(parser.usage?.totalTokens == 50 && parser.usage?.promptTokens == 20)
            #expect(parser.usage?.reasoningTokens == 19 && parser.usage?.cachedTokens == 12)
        }
        let secret = Array("fixture-secret-DO-NOT-REFLECT".utf8)
        for split in 1..<secret.count {
            var guarder = AgentResponsesSecretGuard([String(decoding: secret, as: UTF8.self)])
            #expect(try guarder.consume(Array(secret[..<split])).isEmpty)
            #expect(throws: CollabServer.ServerError.self) { try guarder.consume(Array(secret[split...])) }
        }
        #expect(LLMUsage(json: ["input_tokens": 2, "output_tokens": 3, "total_tokens": 5]).cachedTokens == nil)
    }

    @Test func retriesConsumeOneCallSlotAndAllKnownPhysicalUsage() async throws {
        let scopes = AgentModelScopes(), scope = Self.scope()
        let token = try await scopes.activate(scope)
        let first = try await scopes.claim(token: token, request: AgentModelScopeTests.request(scope, parameters: scope.modelParameters!))
        do {
            _ = try await scopes.claim(token: token, request: AgentModelScopeTests.request(scope, override: ["attempt": 2], parameters: scope.modelParameters!))
            Issue.record("Overlapping attempt accepted")
        } catch { }
        await scopes.finish(first, usage: LLMUsage(json: ["input_tokens": 2, "output_tokens": 3, "total_tokens": 5]), succeeded: false)
        let retry = try await scopes.claim(token: token, request: AgentModelScopeTests.request(scope, override: ["attempt": 3], parameters: scope.modelParameters!))
        // A stale completion cannot release or overwrite the new attempt.
        await scopes.finish(first, usage: .empty)
        await scopes.finish(retry, usage: LLMUsage(json: ["input_tokens": 4, "output_tokens": 6, "total_tokens": 10]))
        do {
            _ = try await scopes.claim(token: token, request: AgentModelScopeTests.request(scope, override: ["attempt": 4], parameters: scope.modelParameters!))
            Issue.record("Successful invocation replayed")
        } catch { }
        #expect(await scopes.revoke(token: token).totalTokens == 15)
    }
}

private func withResponsesProvider(_ handler: @Sendable @escaping (Request) async throws -> Response,
                                   body: @Sendable @escaping (String) async throws -> Void) async throws {
    try await withApp(configure: { app in app.routes.post("v1", "responses", use: handler) }) { app in
        try await app.testing(.running) { client in try await body("http://127.0.0.1:\(try #require(client.port))/v1") }
    }
}

@Suite("Agent native Responses routes", .enabled(if: testDbHost != nil))
struct AgentResponsesRouteTests {
    static let path = "/inner/agent/responses"
    static func fixture(_ api: API, _ store: PostgresStore, _ routes: CollabServer.Routes, endpoint: String) async throws -> (AgentModelScope, String) {
        let (owner, user, app) = try await runtimeFixture(api, endpoint: endpoint)
        let saved = try await api.post("/v1/workspace/model-providers/\(AgentModelWire.compatible)/models/credentials", JSONValue.object([
            "model": "stub-chat", "model_type": "llm", "credentials": ["api_type": "responses", "api_key": "sk-native-fixture-only",
                "endpoint_url": .string(endpoint), "endpoint_model_name": "vendor-stub", "mode": "chat", "context_size": "4096",
                "extra_headers": "{\"X-Fixture\":\"native-extra\"}", "max_tokens_to_sample": "4096"]]).compactJSON(), token: owner)
        #expect(saved.status == 201, "\(saved.text)")
        let key = ModelKey(provider: AgentModelWire.compatible, model: "stub-chat", modelType: "llm")
        let state = try await store.modelProviderState()
        let selected = try #require(state.modelCredentials[key]?.first { $0.config?.contains("sk-native-fixture-only") == true })
        // Extra provider headers may come from an existing server-side credential;
        // the current public credential form intentionally drops unknown fields.
        var stored = try JSONValue.parse(try #require(selected.config)).object!
        stored["extra_headers"] = "{\"X-Fixture\":\"native-extra\"}"
        try await store.updateModelCredential(key, id: selected.id, name: nil, config: JSONValue.object(stored).compactJSON())
        try await store.switchCustomModelCredential(key, id: selected.id)
        let run = UUID().uuidString.lowercased()
        try await store.insertWorkflowRun(.init(id: run, docId: app, docSeq: 0, workflowId: "draft", type: "workflow", triggeredFrom: "debugging",
            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: user, createdAt: Date()))
        var scope = AgentResponsesTests.scope(); scope.model = "stub-chat"
        scope.execution["app_id"] = .string(app); scope.execution["user_id"] = .string(user); scope.execution["workflow_run_id"] = .string(run)
        return (scope, try await routes.agentModelScopes.activate(scope))
    }
    static func headers(_ token: String, call: Int = 1, attempt: Int = 1) -> [(String, String)] {
        [("X-Agent-Run-Token", token), ("X-Agent-Call-Index", String(call)), ("X-Agent-Invocation-ID", "fixture-run:\(call)"), ("X-Agent-Attempt", String(attempt))]
    }

    @Test func originalSSEAndOpaqueItemsSurviveWithCredentialsOnlyAtTheProvider() async throws {
        let seen = Mutex<[JSONValue]>([])
        try await withResponsesProvider({ req in
            #expect(req.headers[.authorization] == "Bearer sk-native-fixture-only")
            #expect(req.headers[HTTPField.Name("X-Fixture")!] == "native-extra")
            #expect(req.headers[HTTPField.Name("X-Agent-Run-Token")!] == nil)
            let raw = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20))) ?? Data()
            let payload = try JSONValue.parse(raw); seen.withLock { $0.append(payload) }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: AgentResponsesTests.stream))
        }) { endpoint in
            try await withFakeDaemon { daemon, log in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    let (scope, token) = try await Self.fixture(api, store, routes, endpoint: endpoint)
                    var payload = AgentResponsesTests.body(scope).object!
                    let opaque: JSONValue = ["type": "reasoning", "encrypted_content": "opaque-input-fixture-ONLY", "future": ["preserve": true]]
                    payload["input"] = .array([opaque] + payload["input"]!.array!)
                    let answer = try await api.send(.post, Self.path, JSONValue.object(payload).compactJSON(), token: AgentModelGatewayRouteTests.serviceKey, headers: Self.headers(token))
                    #expect(answer.status == 200 && answer.text == AgentResponsesTests.stream, "\(answer.status): \(answer.text)")
                    let sent = try #require(seen.withLock { $0.first })
                    #expect(sent["model"] == "vendor-stub" && sent["input"]?.array?.first == opaque)
                    #expect(sent["reasoning"]?["effort"] == "max" && sent["max_output_tokens"] == 32768)
                    let duplicate = try await api.send(.post, Self.path, JSONValue.object(payload).compactJSON(), token: AgentModelGatewayRouteTests.serviceKey, headers: Self.headers(token, attempt: 2))
                    #expect(duplicate.status == 409)
                    #expect(!log.requests.contains { $0.path.hasSuffix("/dispatch/llm/invoke") })
                    let usage = await routes.agentModelScopes.revoke(token: token)
                    #expect(usage.totalTokens == 50 && usage.cachedTokens == 12 && usage.reasoningTokens == 19)
                }
            }
        }
    }

    @Test(arguments: [429, 503])
    func providerStatusRetryAfterAndFailedAttemptArePreservedWithoutReflectedSecrets(status: Int) async throws {
        let calls = Mutex(0)
        try await withResponsesProvider({ _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 {
                let code = status == 429 ? "rate_limit_exceeded" : "server_is_overloaded"
                return Response(status: .init(code: status), headers: [HTTPField.Name("Retry-After")!: "2"],
                    body: .init(string: JSONValue.object(["error": ["code": .string(code), "message": "sk-native-fixture-only"]]).compactJSON()))
            }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: AgentResponsesTests.stream))
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    let (scope, token) = try await Self.fixture(api, store, routes, endpoint: endpoint)
                    let body = AgentResponsesTests.body(scope).compactJSON()
                    var headers: HTTPFields = [.authorization: "Bearer " + AgentModelGatewayRouteTests.serviceKey]
                    for (key, value) in Self.headers(token) { headers[HTTPField.Name(key)!] = value }
                    let failed = try await api.client.send(.post, headers: headers, to: "/inner/agent/responses") { $0.body = .init(string: body) }
                    let message = try await failed.body.requireString()
                    #expect(failed.status.code == status, "\(failed.status.code): \(message)")
                    #expect(message.contains(status == 429 ? "rate_limit_exceeded" : "server_is_overloaded"))
                    #expect(failed.headers[HTTPField.Name("Retry-After")!] == "2")
                    #expect(!message.contains("sk-native-fixture-only"))
                    let retried = try await api.send(.post, Self.path, body, token: AgentModelGatewayRouteTests.serviceKey, headers: Self.headers(token, attempt: 2))
                    #expect(retried.status == 200 && retried.text == AgentResponsesTests.stream)
                    #expect(calls.withLock { $0 } == 2)
                    _ = await routes.agentModelScopes.revoke(token: token)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func closingTheCallerClosesTheProviderEvenBeforeHeadersArrive(beforeHeaders: Bool) async throws {
        let started = Mutex(false), disconnected = Mutex(false)
        try await withResponsesProvider({ _ in
            if beforeHeaders {
                started.withLock { $0 = true }
                do { try await Task.sleep(for: .seconds(8)) }
                catch { disconnected.withLock { $0 = true }; throw error }
            }
            let body = try Response.Body(stream: { writer in
                started.withLock { $0 = true }
                do {
                    for _ in 0..<400 {
                        try await writer.write(": heartbeat\n\n")
                        try await Task.sleep(for: .milliseconds(20))
                    }
                } catch { disconnected.withLock { $0 = true }; throw error }
            }, count: nil)
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: body)
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withStore { store, logger in
                    let config = AgentModelGatewayRouteTests.config(daemon)
                    let routes = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: config, logger: logger), store: store, config: config, logger: logger)
                    try await withApp(configure: { routes.register(on: $0) }) { app in
                        try await app.testing(.running) { testClient in
                            let (scope, token) = try await Self.fixture(API(client: testClient), store, routes, endpoint: endpoint)
                            let client = HTTPClient(eventLoopGroupProvider: .singleton)
                            let call = Task {
                                var request = HTTPClientRequest(url: "http://127.0.0.1:\(try #require(testClient.port))" + Self.path)
                                request.method = .POST
                                request.headers.add(name: "Authorization", value: "Bearer " + AgentModelGatewayRouteTests.serviceKey)
                                for (name, value) in Self.headers(token) { request.headers.add(name: name, value: value) }
                                request.body = .bytes(ByteBuffer(string: AgentResponsesTests.body(scope).compactJSON()))
                                let response = try await client.execute(request, timeout: .seconds(10))
                                for try await _ in response.body { }
                            }
                            for _ in 0..<200 {
                                if started.withLock({ $0 }) { break }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            #expect(started.withLock { $0 })
                            call.cancel(); _ = try? await call.value
                            for _ in 0..<200 {
                                if disconnected.withLock({ $0 }) { break }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            #expect(disconnected.withLock { $0 }, "Provider connection survived caller cancellation")
                            _ = await routes.agentModelScopes.revoke(token: token)
                            try await client.shutdown()
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func revocationAndTheAbsoluteDeadlineCloseAStalledUpstream(deadline: Bool) async throws {
        let started = Mutex(false), disconnected = Mutex(false)
        try await withResponsesProvider({ _ in
            let body = try Response.Body(stream: { writer in
                started.withLock { $0 = true }
                do {
                    for _ in 0..<500 {
                        try await writer.write(": heartbeat\n\n")
                        try await Task.sleep(for: .milliseconds(20))
                    }
                } catch { disconnected.withLock { $0 = true }; throw error }
            }, count: nil)
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: body)
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    let (initial, initialToken) = try await Self.fixture(api, store, routes, endpoint: endpoint)
                    _ = await routes.agentModelScopes.revoke(token: initialToken)
                    var scope = initial
                    if deadline { scope.expiresAt = Date().addingTimeInterval(0.5) }
                    let token = try await routes.agentModelScopes.activate(scope)
                    let body = AgentResponsesTests.body(scope).compactJSON()
                    let call = Task { try await api.send(.post, Self.path, body, token: AgentModelGatewayRouteTests.serviceKey, headers: Self.headers(token)) }
                    for _ in 0..<200 {
                        if started.withLock({ $0 }) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(started.withLock { $0 })
                    if !deadline { _ = await routes.agentModelScopes.revoke(token: token) }
                    _ = try? await call.value
                    for _ in 0..<200 {
                        if disconnected.withLock({ $0 }) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(disconnected.withLock { $0 }, "Upstream socket remained open")
                    _ = await routes.agentModelScopes.revoke(token: token)
                }
            }
        }
    }

    @Test func theServiceAndActiveScopeAreRequiredAndRedirectsAreNotFollowed() async throws {
        try await withResponsesProvider({ _ in
            Response(status: .temporaryRedirect, headers: [.location: "http://127.0.0.1:1/credential-theft"], body: .init(string: "sk-native-fixture-only"))
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    let (scope, token) = try await Self.fixture(api, store, routes, endpoint: endpoint)
                    let body = AgentResponsesTests.body(scope).compactJSON()
                    #expect(try await api.post(Self.path, body).status == 401)
                    #expect(try await api.post(Self.path, body, token: AgentModelGatewayRouteTests.serviceKey).status == 401)
                    let redirect = try await api.send(.post, Self.path, body, token: AgentModelGatewayRouteTests.serviceKey, headers: Self.headers(token))
                    #expect(redirect.status == 307 && !redirect.text.contains("sk-native-fixture-only"), "\(redirect.status): \(redirect.text)")
                    try await store.finishWorkflowRun(id: scope.workflowRunID, status: "stopped", outputs: nil, error: nil,
                        elapsedTime: 0, totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
                    #expect(try await api.send(.post, Self.path, body, token: AgentModelGatewayRouteTests.serviceKey, headers: Self.headers(token, call: 2)).status == 403)
                    _ = await routes.agentModelScopes.revoke(token: token)
                }
            }
        }
    }

    @Test func scopedFilesInToolOutputsAreExpandedAndExternalMediaAndExcessBytesAreRefused() async throws {
        try await withFakeDaemon { daemon, _ in
            var config = AgentModelGatewayRouteTests.config(daemon)
            config.files.directory = FileManager.default.temporaryDirectory.appendingPathComponent("responses-files-" + UUID().uuidString).path
            config.files.signingKey = String(repeating: "fixture-only-", count: 4); config.files.externalURL = "http://files.example.test"
            let frozen = config
            defer { try? FileManager.default.removeItem(atPath: frozen.files.directory) }
            try await withServerAndRoutes(config: frozen) { api, store, routes in
                let (initial, initialToken) = try await AgentModelGatewayRouteTests.fixture(api, store, routes)
                _ = await routes.agentModelScopes.revoke(token: initialToken)
                let files = ServerWorkflowFiles(routes: routes, userId: initial.userID)
                let file = try await files.save(bytes: [UInt8](repeating: 42, count: 7 << 20), filename: "fixture.png", mimeType: "image/png", sourceURL: nil)
                var scope = initial; scope.inputFileIDs = [file.recordId]
                let image: JSONValue = ["type": "input_image", "image_url": .string("dify-sf-file:" + file.recordId)]
                let document: JSONValue = ["type": "input_file", "file_id": .string("dify-sf-file:" + file.recordId)]
                let normalized = try await routes.normalizeAgentResponsesFiles([["type": "function_call_output", "call_id": "c", "output": .array([image, document])]], scope: scope)
                let parts = try #require(normalized.array?.first?["output"]?.array)
                #expect(parts[0]["image_url"]?.string?.hasPrefix("data:image/png;base64,") == true)
                #expect(parts[1]["file_id"] == nil && parts[1]["filename"] == "fixture.png")
                for invalid in [["type": "input_image", "image_url": "https://external.invalid/a.png"],
                                           ["type": "input_file", "file_data": "data:application/pdf;base64,AA=="],
                                           ["type": "input_image", "image_url": .string("dify-sf-file:" + UUID().uuidString.lowercased())]] as [JSONValue] {
                    do { _ = try await routes.normalizeAgentResponsesFiles([invalid], scope: scope); Issue.record("Unauthorized media accepted") }
                    catch is AgentModelFileError { }
                }
                do { _ = try await routes.normalizeAgentResponsesFiles(.array([image, image, image]), scope: scope); Issue.record("Aggregate file budget bypassed") }
                catch CollabServer.ServerError.payloadTooLarge { }
            }
        }
    }
}

@Suite("Agent harness acknowledgement")
struct AgentHarnessEchoTests {
    @Test func matchingStyleAndWireAreRequiredBeforeAcceptingTheResult() async throws {
        let echo = Mutex<JSONValue>(["harness_style": "codex", "model_wire": ["wire": "responses"]])
        let cancelled = Mutex(0)
        try await withApp(configure: { app in
            app.routes.get("v1", "runs", "remote", "events") { _ in
                Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string:
                    "id: 1\nevent: run_started\ndata: \(echo.withLock { $0 }.compactJSON())\n\nid: 2\nevent: succeeded\ndata: {}\n\n"))
            }
            app.routes.get("v1", "runs", "remote") { _ in
                Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1","run_id":"remote","operation_id":"operation","status":"succeeded","last_event_id":2,"result":{}}"#))
            }
            app.routes.post("v1", "runs", "remote", "cancel") { _ in
                cancelled.withLock { $0 += 1 }
                return Response(status: .accepted, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
        }) { app in
            try await app.testing(.running) { client in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:\(try #require(client.port))"; config.key = "fixture-only"
                let service = AgentServiceClient(config: config)
                #expect(try await service.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(5),
                    expectedHarness: "codex", expectedWire: "responses", isAborted: { false })["status"] == "succeeded")
                for bad in [[:], ["harness_style": "dify", "model_wire": ["wire": "responses"]],
                            ["harness_style": "codex", "model_wire": ["wire": "plugin"]]] as [JSONValue] {
                    echo.withLock { $0 = bad }
                    do {
                        _ = try await service.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(5),
                            expectedHarness: "codex", expectedWire: "responses", isAborted: { false })
                        Issue.record("Unconfirmed harness accepted")
                    } catch let error as NodeError { #expect(error.errorTypeName == "AgentHarnessMismatch") }
                }
                #expect(cancelled.withLock { $0 } == 3)
            }
        }
    }
}

@Suite("Official Codex Responses admission")
struct AgentCodexResponsesTests {
    @Test func officialFieldsAndNamespacesSurviveWhileTheWorkflowBudgetIsEnforced() throws {
        var scope = AgentResponsesTests.scope(); scope.outputTokenLimit = 4096
        var body = AgentResponsesTests.body(scope).object!
        body["instructions"] = "Synthetic instructions"
        body["client_metadata"] = ["thread_id": "fixture-thread"]
        body["tools"] = [["type": "namespace", "name": "multi_agent_v1", "tools": [
            ["type": "function", "name": "spawn_agent", "parameters": ["type": "object"]]]]]
        let request = try AgentResponsesRequest(codexBody: .object(body), scope: scope)
        #expect(request.body["tools"] == body["tools"] && request.body["client_metadata"] == body["client_metadata"])
        #expect(request.body["instructions"] == body["instructions"] && request.body["max_output_tokens"] == 4096)
        for changes in [["max_output_tokens": 4097], ["model": "other"], ["store": true],
            ["previous_response_id": "unscoped"], ["tools": [["type": "mcp", "server_url": "http://outside.invalid"]]],
            ["reasoning": ["effort": "high"]]] as [JSONObject] {
            #expect(throws: CollabServer.ServerError.self) {
                try AgentResponsesRequest(codexBody: .object(body.merging(changes)), scope: scope)
            }
        }
        #expect(AgentModelWire.select(style: "codex", provider: AgentModelWire.deepSeek, credentials: [:]) == "responses")
        #expect(AgentModelWire.select(style: "dify", provider: AgentModelWire.deepSeek, credentials: [:]) == "plugin")
        #expect(try AgentResponsesConnection(provider: AgentModelWire.deepSeek, model: "deepseek-flash",
            credentials: ["api_key": "fixture-only"]).url == "https://api.deepseek.com/responses")
    }

    @Test func eachPostIncludingRetriesAndChildAgentsConsumesItsOwnSlot() async throws {
        let scopes = AgentModelScopes(); var scope = AgentResponsesTests.scope(); scope.maxCalls = 2
        let token = try await scopes.activate(scope)
        let first = try await scopes.claimCodex(token: token)
        let child = try await scopes.claimCodex(token: token)
        #expect(first.index == 1 && child.index == 2)
        do { _ = try await scopes.claimCodex(token: token); Issue.record("Call budget bypassed") }
        catch is AgentCodexCallLimit { }
        await scopes.finish(first, usage: LLMUsage(json: ["input_tokens": 3, "output_tokens": 2, "total_tokens": 5]), succeeded: false)
        await scopes.finish(child, usage: LLMUsage(json: ["input_tokens": 5, "output_tokens": 3, "total_tokens": 8]))
        #expect(await scopes.revoke(token: token).totalTokens == 13)
        do { _ = try await scopes.claimCodex(token: token); Issue.record("Revoked token accepted") } catch { }
    }

    @Test func busyAdmissionsDoNotConsumeTheRemainingCallBudget() async throws {
        let scopes = AgentModelScopes(); var scope = AgentResponsesTests.scope(); scope.maxCalls = 9
        let token = try await scopes.activate(scope)
        var admitted: [AgentModelScopes.Claim] = []
        for _ in 0..<8 { admitted.append(try await scopes.claimCodex(token: token)) }
        for _ in 0..<3 {
            do { _ = try await scopes.claimCodex(token: token); Issue.record("Busy request accepted") }
            catch CollabServer.ServerError.http(let status, let code, _) {
                #expect(status == 503 && code == "agent_model_busy")
            }
        }
        await scopes.finish(admitted[0], usage: nil)
        let last = try await scopes.claimCodex(token: token)
        #expect(last.index == 9)
        do { _ = try await scopes.claimCodex(token: token); Issue.record("Call budget bypassed") }
        catch is AgentCodexCallLimit { }
        _ = await scopes.revoke(token: token)
    }

    @Test func temporaryModelTokensDoNotChangeThePublicOperationDigest() {
        let a: JSONObject = ["model": ["name": "fixture", "run_token": "fixture-temporary-one"], "env": [:]]
        let b: JSONObject = ["model": ["name": "fixture", "run_token": "fixture-temporary-two"], "env": [:]]
        #expect(ServerAgentRuntime.operationDigest(a) == ServerAgentRuntime.operationDigest(b))
    }

    @Test func turnCompletionKeepsKnownUsageBeforeHTTPClosureWithoutCountingItTwice() async throws {
        let scopes = AgentModelScopes(); var scope = AgentResponsesTests.scope(); scope.maxCalls = 2
        let token = try await scopes.activate(scope)
        let first = try await scopes.claimCodex(token: token)
        let child = try await scopes.claimCodex(token: token)
        let usage = LLMUsage(json: ["input_tokens": 20, "output_tokens": 3, "total_tokens": 23,
            "input_tokens_details": ["cached_tokens": 12]])
        await scopes.observeCodexUsage(usage, for: first)
        await scopes.finish(first, usage: usage)
        await scopes.observeCodexUsage(usage, for: child)
        let total = await scopes.revoke(token: token) // Child HTTP body is still open.
        #expect(total.totalTokens == 46 && total.cachedTokens == 24)
        await scopes.finish(child, usage: usage)
        #expect(await scopes.revoke(token: token).totalTokens == 0)
    }
}

@Suite("Official Codex Responses route", .enabled(if: testDbHost != nil))
struct AgentCodexResponsesRouteTests {
    static let path = "/inner/agent/codex/v1/responses"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_CODEX_BINARY"] != nil))
    func actualOfficialCodexCallsTheSwiftGatewayWithNoInternalHeaders() async throws {
        let seen = Mutex<[JSONValue]>([])
        let message: JSONValue = ["type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": "Fixture complete."]]]
        let events: [JSONValue] = [
            ["type": "response.created", "response": ["id": "resp_fixture"]],
            ["type": "response.output_item.added", "output_index": 0, "item": message],
            ["type": "response.output_text.delta", "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "delta": "Fixture complete."],
            ["type": "response.output_item.done", "output_index": 0, "item": message],
            ["type": "response.completed", "response": ["id": "resp_fixture", "status": "completed", "output": .array([message]),
                "usage": ["input_tokens": 20, "output_tokens": 3, "total_tokens": 23, "input_tokens_details": ["cached_tokens": 12], "output_tokens_details": ["reasoning_tokens": 0]]]]]
        let stream = events.map { "event: \($0["type"]!.string!)\ndata: \($0.compactJSON())\n\n" }.joined()
        try await withResponsesProvider({ req in
            #expect(req.headers[.authorization] == "Bearer sk-native-fixture-only")
            #expect(req.headers[HTTPField.Name("X-Agent-Run-Token")!] == nil)
            let bytes = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20))) ?? Data()
            seen.withLock { $0.append(try! JSONValue.parse(bytes)) }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: stream))
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withStore { store, logger in
                    let config = AgentModelGatewayRouteTests.config(daemon)
                    let routes = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: config, logger: logger), store: store, config: config, logger: logger)
                    try await withApp(configure: { routes.register(on: $0) }) { app in
                        try await app.testing(.running) { client in
                            let (scope, token) = try await AgentResponsesRouteTests.fixture(API(client: client), store, routes, endpoint: endpoint)
                            let base = "http://127.0.0.1:\(try #require(client.port))/inner/agent/codex/v1"
                            let binary = try #require(ProcessInfo.processInfo.environment["AGENT_CODEX_BINARY"])
                            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-codex/process.py").path
                            let result = try await Task.detached {
                                let process = Process(), output = Pipe(), errors = Pipe()
                                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                                process.arguments = [script]
                                process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path,
                                    "AGENT_CODEX_BINARY": binary, "CODEX_FIXTURE_URL": base,
                                    "CODEX_FIXTURE_MODEL": scope.model, "CODEX_FIXTURE_RUN_TOKEN": token]
                                process.standardOutput = output; process.standardError = errors
                                try process.run()
                                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                                let error = errors.fileHandleForReading.readDataToEndOfFile()
                                process.waitUntilExit()
                                return (process.terminationStatus, String(decoding: bytes, as: UTF8.self), String(decoding: error, as: UTF8.self))
                            }.value
                            #expect(result.0 == 0, "Official client failed: \(result.2)")
                            #expect(result.1.contains("completed"))
                            let body = try #require(seen.withLock { $0.first })
                            #expect(seen.withLock { $0.count } == 1)
                            #expect(body["model"] == "vendor-stub" && body["reasoning"]?["effort"] == "max")
                            #expect(body["max_output_tokens"] == 32768 && body["client_metadata"]?.object != nil)
                            let usage = await routes.agentModelScopes.revoke(token: token)
                            #expect(usage.totalTokens == 23 && usage.cachedTokens == 12)
                        }
                    }
                }
            }
        }
    }

    @Test func bearerOnlyCallsKeepProviderErrorsAndStopWithTheCodexQuotaShape() async throws {
        let calls = Mutex(0)
        try await withResponsesProvider({ req in
            let n = calls.withLock { $0 += 1; return $0 }
            #expect(req.headers[.authorization] == "Bearer sk-native-fixture-only")
            #expect(req.headers[HTTPField.Name("X-Agent-Call-Index")!] == nil)
            if n < 3 {
                return Response(status: .init(code: n == 1 ? 503 : 429), headers: [HTTPField.Name("Retry-After")!: "2"],
                    body: .init(string: #"{"error":{"code":"fixture_provider_code","type":"rate_limit_exceeded","message":"sk-native-fixture-only"}}"#))
            }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: AgentResponsesTests.stream))
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    var (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: endpoint)
                    _ = await routes.agentModelScopes.revoke(token: token)
                    scope.maxCalls = 3; token = try await routes.agentModelScopes.activate(scope)
                    let body = AgentResponsesTests.body(scope).compactJSON()
                    #expect(try await api.post(Self.path, body).status == 401)
                    #expect(try await api.post(Self.path, body, token: AgentModelGatewayRouteTests.serviceKey).status == 403)
                    for expected in [503, 429, 200] {
                        let answer = try await api.post(Self.path, body, token: token)
                        #expect(answer.status == expected, "\(answer.status): \(answer.text)")
                        #expect(answer.headers[HTTPField.Name("x-codex-promo-message")!] == nil)
                        if expected == 200 { #expect(answer.text == AgentResponsesTests.stream) }
                        else {
                            let value = try JSONValue.parse(Data(answer.text.utf8))
                            #expect(value["error"]?["type"] == "rate_limit_exceeded" && value["error"]?["code"] == "fixture_provider_code")
                            #expect(!answer.text.contains("sk-native-fixture-only"))
                        }
                    }
                    #expect(calls.withLock { $0 } == 3, "Gateway performed its own retry")
                    let exhausted = try await api.post(Self.path, body, token: token)
                    let error = try JSONValue.parse(Data(exhausted.text.utf8))
                    #expect(exhausted.status == 429 && error["error"]?["type"] == "usage_limit_reached")
                    #expect(exhausted.headers[HTTPField.Name("x-codex-promo-message")!] == "dify-sf-agent-call-limit")
                    #expect(calls.withLock { $0 } == 3)
                    let usage = await routes.agentModelScopes.revoke(token: token)
                    #expect(usage.totalTokens == 50 && usage.cachedTokens == 12 && usage.reasoningTokens == 19)
                    #expect(try await api.post(Self.path, body, token: token).status == 403)
                }
            }
        }
    }

    @Test func providerUsageLimitIsQuotaEvenAtTheCallCapAndCannotSpoofOurMarker() async throws {
        let marker = HTTPField.Name("x-codex-promo-message")!
        try await withResponsesProvider({ _ in
            Response(status: .init(code: 429), headers: [marker: "dify-sf-agent-call-limit"],
                body: .init(string: #"{"error":{"type":"usage_limit_reached","code":"provider_quota","message":"sk-native-fixture-only"}}"#))
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    var (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: endpoint)
                    _ = await routes.agentModelScopes.revoke(token: token)
                    scope.maxCalls = 1; token = try await routes.agentModelScopes.activate(scope)
                    let response = try await api.post(Self.path, AgentResponsesTests.body(scope).compactJSON(), token: token)
                    let error = try JSONValue.parse(Data(response.text.utf8))
                    #expect(response.status == 429 && error["error"]?["type"] == "insufficient_quota")
                    #expect(error["error"]?["code"] == "provider_quota")
                    #expect(response.headers[marker] == nil && !response.text.contains("sk-native-fixture-only"))
                    let exhausted = try await api.post(Self.path, AgentResponsesTests.body(scope).compactJSON(), token: token)
                    #expect(exhausted.status == 429 && exhausted.headers[marker] == "dify-sf-agent-call-limit")
                    _ = await routes.agentModelScopes.revoke(token: token)
                }
            }
        }
    }

    @Test func nativeImageHistoryBeyondTheOldRequestAndFileLimitsIsForwardedUnchanged() async throws {
        let imageURL = "data:image/png;base64," + Data(repeating: 42, count: 11 << 20).base64EncodedString()
        let seen = Mutex(0)
        try await withResponsesProvider({ req in
            let wire = try await req.body.collect(max: .specified(ByteCount(value: AgentCodexGatewayLimits.requestBytes))) ?? Data()
            #expect(wire.count > AgentModelGatewayLimits.requestBytes)
            let value = try JSONValue.parse(wire)
            let parts = try #require(value["input"]?.array?.first?["content"]?.array)
            #expect(parts.count == 3 && parts.allSatisfy { $0["image_url"] == .string(imageURL) })
            #expect(value["reasoning"]?["effort"] == "max" && value["store"] == false)
            seen.withLock { $0 += 1 }
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: AgentResponsesTests.stream))
        }) { endpoint in
            try await withFakeDaemon { daemon, _ in
                try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                    let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: endpoint)
                    var body = try #require(AgentResponsesTests.body(scope).object)
                    body["input"] = [["role": "user", "content": .array(Array(repeating:
                        ["type": "input_image", "image_url": .string(imageURL)], count: 3))]]
                    let response = try await api.post(Self.path, JSONValue.object(body).compactJSON(), token: token)
                    #expect(response.status == 200 && response.text == AgentResponsesTests.stream)
                    #expect(seen.withLock { $0 } == 1)
                    _ = await routes.agentModelScopes.revoke(token: token)
                }
            }
        }
    }

    @Test func localCodexImagesAreBoundedAndExternalOrUnscopedFilesAreRefused() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let image: JSONValue = ["type": "input_image", "image_url": "data:image/png;base64,AQID"]
                let input: JSONValue = [["type": "function_call_output", "call_id": "fixture", "output": [image]]]
                #expect(try await routes.normalizeAgentResponsesFiles(input, scope: scope, allowInline: true) == input)
                for invalid in [["type": "input_image", "image_url": "https://outside.invalid/image.png"],
                    ["type": "input_image", "image_url": "data:image/png;base64,not-base64"],
                    ["type": "input_file", "file_id": "file-outside-the-run"]] as [JSONValue] {
                    do { _ = try await routes.normalizeAgentResponsesFiles([invalid], scope: scope, allowInline: true); Issue.record("Unscoped media accepted") }
                    catch is AgentModelFileError { }
                }
                let huge = Data(repeating: 42, count: 11 << 20).base64EncodedString()
                let repeated: JSONValue = ["type": "input_image", "image_url": .string("data:image/png;base64," + huge)]
                let history: JSONValue = .array(Array(repeating: repeated, count: 3))
                #expect(try await routes.normalizeAgentResponsesFiles(history, scope: scope, allowInline: true) == history)
                do { _ = try await routes.normalizeAgentResponsesFiles(.array(Array(repeating: repeated, count: 9)), scope: scope, allowInline: true); Issue.record("File budget bypassed") }
                catch CollabServer.ServerError.payloadTooLarge { }
                _ = await routes.agentModelScopes.revoke(token: token)
            }
        }
    }
}
