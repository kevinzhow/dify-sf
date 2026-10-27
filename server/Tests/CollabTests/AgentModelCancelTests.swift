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

private final class AgentTransportProbe: Sendable {
    let started = Mutex(false)
    let disconnected = Mutex(false)
}

/// Deliberately never finishes on its own during the test: only an actual closed TCP stream ends it.
private func withStreamingAgentDaemon(
    commentsOnly: Bool = false, _ body: @Sendable @escaping (String, AgentTransportProbe) async throws -> Void
) async throws {
    let probe = AgentTransportProbe()
    try await withApp(configure: { app in
        // Credential setup now resolves the schema before saving. Keep this transport
        // fixture complete so cancellation still exercises the real streaming socket.
        app.post("plugin", ":tenant", "dispatch", "model", "schema") { _ async -> Response in
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            let schema: JSONValue = ["code": 0, "message": "", "data": ["model_schema": [
                "model": "stub-chat", "label": ["en_US": "stub-chat"], "model_type": "llm",
                "features": [], "fetch_from": "customizable-model",
                "model_properties": ["mode": "chat", "context_size": 4096], "parameter_rules": [],
            ]]]
            return Response(status: .ok, headers: headers,
                body: .init(string: "data: " + schema.compactJSON() + "\n\n"))
        }
        app.post("plugin", ":tenant", "dispatch", "llm", "invoke") { req async throws -> Response in
            _ = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20)))
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            let response = try Response.Body(stream: { writer in
                probe.started.withLock { $0 = true }
                do {
                    for index in 0..<1000 {
                        let data: JSONValue = ["code": 0, "message": "", "data": [
                            "model": "stub-chat", "delta": ["index": 0, "message": ["role": "assistant", "content": .string("piece \(index)")]],
                        ]]
                        try await writer.write(commentsOnly ? "\n" : "data: " + data.compactJSON() + "\n\n")
                        try await Task.sleep(for: .milliseconds(20))
                    }
                } catch {
                    probe.disconnected.withLock { $0 = true }
                    throw error
                }
            }, count: nil)
            return Response(status: .ok, headers: headers, body: response)
        }
    }) { app in
        try await app.testing(.running) { client in
            let port = try #require(client.port)
            try await body("http://127.0.0.1:\(port)", probe)
        }
    }
}

@Suite("Agent model cancellation transport", .enabled(if: testDbHost != nil))
struct AgentModelCancelTests {
    @Test(arguments: [false, true])
    func closingTheCallbackConnectionClosesThePluginConnection(beforeFirstChunk: Bool) async throws {
        try await withStreamingAgentDaemon(commentsOnly: beforeFirstChunk) { daemon, probe in
            try await withStore { store, logger in
                let config = AgentModelGatewayRouteTests.config(daemon)
                let routes = try Routes(registry: DocumentRegistry(store: store, config: config, logger: logger),
                    store: store, config: config, logger: logger)
                try await withApp(configure: { routes.register(on: $0) }) { app in
                    try await app.testing(.running) { testClient in
                        let port = try #require(testClient.port)
                        let (scope, token) = try await AgentModelGatewayRouteTests.fixture(API(client: testClient), store, routes)
                        let firstPiece = Mutex(false)
                        let client = HTTPClient(eventLoopGroupProvider: .singleton)
                        let call = Task<Void, any Error> {
                            var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/inner/agent/llm/invoke")
                            request.method = .POST
                            request.headers.add(name: "Content-Type", value: "application/json")
                            request.headers.add(name: "Authorization", value: "Bearer " + AgentModelGatewayRouteTests.serviceKey)
                            request.headers.add(name: "X-Agent-Run-Token", value: token)
                            request.body = .bytes(ByteBuffer(string: AgentModelGatewayRouteTests.body(scope)))
                            let response = try await client.execute(request, timeout: .seconds(10))
                            for try await chunk in response.body where chunk.readableBytes > 0 {
                                firstPiece.withLock { $0 = true }
                            }
                        }
                        for _ in 0..<200 {
                            if beforeFirstChunk ? probe.started.withLock({ $0 }) : firstPiece.withLock({ $0 }) { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        let received = firstPiece.withLock { $0 }
                        call.cancel()
                        _ = try? await call.value
                        try await client.shutdown()
                        for _ in 0..<200 {
                            if probe.disconnected.withLock({ $0 }) { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        _ = await routes.agentModelScopes.revoke(token: token)
                        #expect(received != beforeFirstChunk, "test both before the first model chunk and after receiving it")
                        #expect(probe.started.withLock { $0 })
                        #expect(probe.disconnected.withLock { $0 }, "the plugin TCP stream must close, not merely the returned state")
                    }
                }
            }
        }
    }
}
