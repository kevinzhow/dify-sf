import CollabRuntime
import CollabStore
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

    @Test func aDroppedEventStreamResumesFromItsCommittedCursorAnd410RecoversTheFinalResult() async throws {
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
                let recovered = try await client.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(10), isAborted: { false })
                #expect(recovered["status"] == "succeeded")
                lost.withLock { $0 = false }; requests.withLock { $0 = [] }
                do {
                    _ = try await client.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(10), isAborted: { false }) { _, _, _ in
                        throw StoreError.notCommitted("synthetic commit refusal")
                    }
                    Issue.record("A database error was swallowed")
                } catch StoreError.notCommitted { }
                #expect(requests.withLock { $0 }.count == 1, "Database failures must never reconnect the HTTP event stream")
            }
        }
    }
}

@Suite("Agent health and scoped reconciliation")
struct AgentHealthReconciliationTests {
    @Test func concurrentFeatureReadsShareOneShortProbeAndDisabledShellNeverProbes() async throws {
        let probes = Mutex(0)
        try await withApp(configure: { app in
            app.routes.get("v1", "health") { _ in
                probes.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(100))
                return Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1","sandbox":"isolated"}"#))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21313)) { _ in
                var c = ServerConfig.defaults.agentService
                c.url = "http://127.0.0.1:21313"; c.key = "fixture-only"; c.shellEnabled = true
                let enabled = c, cache = AgentShellHealthCache()
                await withTaskGroup(of: Bool.self) { group in
                    for _ in 0..<20 { group.addTask { await cache.available(enabled) } }
                    for await result in group { #expect(result) }
                }
                #expect(await cache.available(enabled))
                c.shellEnabled = false
                #expect(await cache.available(c) == false)
                #expect(probes.withLock { $0 } == 1)
            }
        }
    }

    @Test(.enabled(if: testDbHost != nil))
    func onlyRemoteOrphansWithCompleteIdentityInThisDatabaseCanBeCancelled() async throws {
        let remote = Mutex<JSONValue>([])
        let calls = Mutex<[String]>([])
        try await withApp(configure: { app in
            app.routes.get("v1", "runs") { _ in
                Response(status: .ok, body: .init(string: JSONValue.object(["protocol": "dify-sf-agent/1", "runs": remote.withLock { $0 }]).compactJSON()))
            }
            app.routes.post("v1", "runs", ":id", "cancel") { req in
                calls.withLock { $0.append("cancel:" + (req.parameters.get("id") ?? "")) }
                return Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
            app.routes.delete("v1", "executions", ":id") { req in
                calls.withLock { $0.append("cleanup:" + (req.parameters.get("id") ?? "")) }
                return Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21314)) { _ in
                var config = ServerConfig.defaults
                config.agentService.url = "http://127.0.0.1:21314"; config.agentService.key = "fixture-only"
                let frozen = config
                try await withServerAndRoutes(config: frozen) { api, store, routes in
                    let local = try await AgentExecutionStoreTests.seed(api, store)
                    func record(_ run: String, _ execution: String, tenant: JSONValue, app: String, workflow: String) -> JSONValue {
                        ["run_id": .string(run), "execution_id": .string(execution), "operation_id": .string(execution + ":0:0"), "generation": 1,
                            "tenant_id": tenant, "app_id": .string(app), "workflow_run_id": .string(workflow), "node_id": .string(local.nodeID)]
                    }
                    remote.withLock { $0 = .array([
                        record("owned-orphan", "owned-missing", tenant: .string(frozen.pluginDaemonTenant), app: local.docID, workflow: local.workflowRunID),
                        record("unknown-old", "old-missing", tenant: .null, app: local.docID, workflow: local.workflowRunID),
                        record("other-tenant", "foreign-missing", tenant: "other-tenant", app: local.docID, workflow: local.workflowRunID),
                        record("other-database", "foreign-database", tenant: .string(frozen.pluginDaemonTenant), app: UUID().uuidString, workflow: UUID().uuidString),
                        record("local-live", local.executionID, tenant: .string(frozen.pluginDaemonTenant), app: local.docID, workflow: local.workflowRunID),
                    ]) }
                    await routes.recoverAgentExecutions()
                    #expect(calls.withLock { $0 } == ["cancel:owned-orphan", "cleanup:owned-missing"])
                    #expect(try await store.agentSession(execution: local.executionID)?.status == "prepared")
                }
            }
        }
    }
}
