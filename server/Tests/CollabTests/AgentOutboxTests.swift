import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import PostgresNIO
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Agent cleanup HTTP retries", .enabled(if: testDbHost != nil))
struct AgentOutboxTests {
    @Test func cleanup503IsRetriedOnlyAfterTheCommittedAck() async throws {
        let calls = Mutex<[String]>([])
        try await withApp(configure: { app in
            @Sendable func reply(_ status: HTTPResponse.Status) -> Response {
                Response(status: status, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
            app.routes.post("v1", "runs", ":run", "ack") { _ in calls.withLock { $0.append("ack") }; return reply(.ok) }
            app.routes.post("v1", "runs", ":run", "cancel") { _ in calls.withLock { $0.append("cancel") }; return reply(.conflict) }
            app.routes.delete("v1", "executions", ":execution") { _ in
                let count = calls.withLock { list -> Int in list.append("cleanup"); return list.filter { $0 == "cleanup" }.count }
                return reply(count == 1 ? .serviceUnavailable : .ok)
            }
        }) { service in
            try await service.testing(.running, options: .live(port: 21309)) { _ in
                var config = ServerConfig.defaults
                config.agentService.url = "http://127.0.0.1:21309"; config.agentService.key = "fake-agent-key"
                try await withServerAndRoutes(config: config) { api, store, routes in
                    let session = try await AgentExecutionStoreTests.result(try await AgentExecutionStoreTests.seed(api, store), store)
                    try await store.commitAgentRetry(.init(session: session, status: "retry", outputAttempt: 1))
                    _ = try await AgentExecutionStoreTests.finish(store, session.workflowRunID, status: "stopped")
                    await routes.deliverAgentOutbox()
                    #expect(calls.withLock { $0 }.contains("ack"))
                    #expect(!calls.withLock { $0 }.contains("cleanup"))
                    await routes.deliverAgentOutbox()
                    #expect(calls.withLock { $0.filter { $0 == "cleanup" }.count } == 1)
                    var attempts = 0
                    for try await n in try await store.client.query("SELECT attempts FROM agent_runtime_outbox WHERE kind = 'cleanup'", logger: store.logger).decode(Int.self) { attempts = n }
                    #expect(attempts == 1)
                    _ = try await store.client.query("UPDATE agent_runtime_outbox SET next_at = now() WHERE kind = 'cleanup'", logger: store.logger)
                    await routes.deliverAgentOutbox()
                    #expect(calls.withLock { $0.filter { $0 == "cleanup" }.count } == 2)
                    #expect(try await store.pendingAgentJobs().isEmpty)
                }
            }
        }
    }
}
