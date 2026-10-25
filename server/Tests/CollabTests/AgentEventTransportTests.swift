import CollabRuntime
import Foundation
import HTTPTypes
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Agent event and capability transport")
struct AgentEventTransportTests {
    @Test func shellRequiresExplicitOptInAndAnIsolatedHealthProbe() async throws {
        let health = Mutex("isolated")
        try await withApp(configure: { app in
            app.routes.get("v1", "health") { _ in
                Response(status: .ok, body: .init(string: JSONValue.object(["protocol": .string(AgentServiceClient.protocolName), "sandbox": .string(health.withLock { $0 })]).compactJSON()))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21311)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21311"; config.key = "fixture-only"
                #expect(await AgentServiceClient(config: config).shellAvailable() == false)
                config.shellEnabled = true
                #expect(await AgentServiceClient(config: config).shellAvailable())
                for state in ["disabled", "unavailable"] {
                    health.withLock { $0 = state }
                    #expect(await AgentServiceClient(config: config).shellAvailable() == false)
                }
            }
        }
    }

    @Test func aDroppedEventStreamResumesFromItsCommittedCursorAnd410CannotBecomeSuccess() async throws {
        let requests = Mutex<[String]>([])
        let lost = Mutex(false)
        let delivered = Mutex(false)
        let seen = Mutex<[Int]>([])
        try await withApp(configure: { app in
            app.routes.get("v1", "runs", "remote", "events") { req in
                if lost.withLock({ $0 }) {
                    return Response(status: .gone, body: .init(string: JSONValue.object(["protocol": .string(AgentServiceClient.protocolName), "error": "event_history_gone"]).compactJSON()))
                }
                let after = (try? req.query.get(Int.self, at: "after")) ?? -1
                requests.withLock { $0.append(String(after)) }
                let wire: String
                if after == 0 { wire = "id: 1\r\nevent: thought\r\ndata: {\"text\":\"retained\"}\r\n\r\n" }
                else { delivered.withLock { $0 = true }; wire = "id: 2\nevent: succeeded\ndata: {\"status\":\"succeeded\"}\n\n" }
                return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: wire))
            }
            app.routes.get("v1", "runs", "remote") { _ in
                let done = delivered.withLock { $0 }
                return Response(status: .ok, body: .init(string: JSONValue.object(["protocol": .string(AgentServiceClient.protocolName), "run_id": "remote", "operation_id": "operation", "status": done ? "succeeded" : "running", "last_event_id": done ? 2 : 1, "result": [:]]).compactJSON()))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21312)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21312"; config.key = "fixture-only"
                let client = AgentServiceClient(config: config)
                let result = try await client.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(10), isAborted: { false }) { id, _, _ in seen.withLock { $0.append(id) } }
                #expect(result["status"] == "succeeded")
                #expect(seen.withLock { $0 } == [1, 2])
                #expect(requests.withLock { $0 } == ["0", "1"])
                lost.withLock { $0 = true }
                do {
                    _ = try await client.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(10), isAborted: { false })
                    Issue.record("Purged event history was accepted")
                } catch let error as NodeError { #expect(error.errorTypeName == "AgentEventHistoryLost") }
            }
        }
    }
}
