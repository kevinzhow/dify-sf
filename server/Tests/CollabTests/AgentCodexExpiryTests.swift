import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite(.serialized)
struct AgentCodexExpiryTests {
    @Test func onlyMatureConnectionsUseTheNormalRotationBudget() {
        #expect(!AgentCodexRotationPolicy.isNormalExpiry(age: 3299.99))
        #expect(AgentCodexRotationPolicy.isNormalExpiry(age: 3300))
        #expect(AgentCodexRotationPolicy.isNormalExpiry(age: 3600.725))
        #expect(!AgentCodexRotationPolicy.isNormalExpiry(age: -.infinity))
        #expect(!AgentCodexRotationPolicy.isNormalExpiry(age: .infinity))
        #expect(!AgentCodexRotationPolicy.isNormalExpiry(age: .nan))
        #expect(!AgentCodexRecoveryPolicy.isTransient(AgentCodexTransportLoss.connectionExpired))
    }

    @Test func normalRotationsAreBoundedAndDoNotSpendTheFaultAllowance() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(AgentCodexRecoveryTests.scope())
        let task = AgentCodexRecoveryTests.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "0", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        for count in 1...AgentCodexRotationPolicy.maximumRotations {
            #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint,
                normalExpiry: true, socketID: String(count - 1)) == count)
            #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true) == nil)
            let checkpoint = try await scopes.openCodexSocket(token: token, lane: "root", id: String(count), task: task)
            #expect(checkpoint?.rotationCount == count && checkpoint?.recoveryAttempt == 0)
            #expect(checkpoint?.reconnectReason == .connectionExpired)
        }
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true) == nil)
        for attempt in 1...3 {
            #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint) == attempt)
            _ = try await scopes.openCodexSocket(token: token, lane: "root", id: "fault-\(attempt)", task: task)
        }
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint) == nil)
        #expect(try await scopes.claimCodex(token: token).index == 1)
    }

    @Test func rotationsShareTheNodeCounterAcrossChildrenAndCapabilityReplacement() async throws {
        let scopes = AgentModelScopes(), scope = AgentCodexRecoveryTests.scope(), task = AgentCodexRecoveryTests.idle()
        defer { task.cancel() }
        var token = try await scopes.activate(scope)
        for count in 1...3 {
            let lane = "child-\(count)"
            try await scopes.openCodexSocket(token: token, lane: lane, id: lane, task: task)
            try await scopes.startCodexSocket(token: token, lane: lane)
            #expect(try await scopes.offerCodexRecovery(token: token, lane: lane, checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true) == count)
            _ = await scopes.revoke(token: token)
            token = try await scopes.activate(scope)
        }
    }

    @Test func staleSocketsUnsafeResultsAndExhaustedCallsCannotRotate() async throws {
        let scopes = AgentModelScopes(); var scope = AgentCodexRecoveryTests.scope(); scope.maxCalls = 1
        let token = try await scopes.activate(scope), task = AgentCodexRecoveryTests.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "current", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true, socketID: "stale") == nil)
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: .init(unsafe: true), normalExpiry: true) == nil)
        let claim = try await scopes.claimCodex(token: token); await scopes.finish(claim, usage: nil, succeeded: false)
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true) == nil)
    }

    @Test(arguments: ["idle", "warmup", "generating"], [false, true])
    func exactExpiryEventPreservesTheCheckpointWithoutRequiringAnActiveResponse(phase: String, tool: Bool) async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: scope.model,
                    credentials: ["api_type": "responses", "endpoint_url": "http://127.0.0.1:1", "api_key": "fixture-key"])
                let task = AgentCodexRecoveryTests.idle(); defer { task.cancel() }
                try await routes.agentModelScopes.openCodexSocket(token: token, lane: "root", id: "old", task: task)
                let session = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection)
                var body = AgentResponsesTests.body(scope).object!; body["type"] = "response.create"
                if phase == "warmup" { body["generate"] = false }
                if phase != "idle" || tool {
                    _ = try await session.prepare(JSONValue.object(body).compactData())
                    if tool {
                        _ = try await session.observe(JSONValue.object(["type": "response.output_item.done", "item": [
                            "type": "function_call", "call_id": "actual-tool", "name": "exec_command", "arguments": "{}"]]).compactData())
                    }
                    if phase == "idle" { _ = try await session.observe(JSONValue.object(["type": "response.completed", "response": ["id": "resp_done"]]).compactData()) }
                }
                let before = await session.checkpoint()
                do {
                    _ = try await session.observe(JSONValue.object(["type": "error", "status": 400, "error": [
                        "code": "websocket_connection_limit_reached", "message": "private provider text"]]).compactData())
                    Issue.record("Expiry was forwarded as an ordinary response")
                } catch let e as AgentCodexTransportLoss { if case .connectionExpired = e {} else { Issue.record("Wrong loss classification") } }
                let after = await session.checkpoint()
                #expect(after.parameters == before.parameters && after.pendingTools == before.pendingTools && after.unsafe == before.unsafe)
                await session.finish(status: 400)
                // Settlement never refunds a generating request, and idle/warmup do not manufacture a call.
                let next = try await routes.agentModelScopes.claimCodex(token: token)
                #expect(next.index == (phase == "generating" || (tool && phase != "warmup") ? 2 : 1))
            }
        }
    }
    @Test func normalRotationRequiresOptInAndCancellationDoesNotSpendItsAllowance() async throws {
        let scopes = AgentModelScopes(); var scope = AgentCodexRecoveryTests.scope(); scope.codexWebsocketRecoveryEnabled = false
        let task = AgentCodexRecoveryTests.idle(); defer { task.cancel() }
        let disabled = try await scopes.activate(scope)
        try await scopes.openCodexSocket(token: disabled, lane: "root", id: "off", task: task)
        try await scopes.startCodexSocket(token: disabled, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: disabled, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true) == nil)
        _ = await scopes.revoke(token: disabled)
        scope.codexWebsocketRecoveryEnabled = true
        let enabled = try await scopes.activate(scope)
        try await scopes.openCodexSocket(token: enabled, lane: "root", id: "on", task: task)
        try await scopes.startCodexSocket(token: enabled, lane: "root")
        let cancelled = Task { () throws -> Int? in
            try? await Task.sleep(for: .seconds(30))
            return try await scopes.offerCodexRecovery(token: enabled, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled rotation was authorized") } catch is CancellationError {}
        #expect(try await scopes.offerCodexRecovery(token: enabled, lane: "root", checkpoint: AgentCodexRecoveryTests.checkpoint, normalExpiry: true) == 1)
    }

    @Test func normalRotationAuditUsesItsOwnCounter() async throws {
        try await withServerAndRoutes { api, store, routes in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            let operation = "\(session.executionID):0:0"
            try await store.startAgentOperation(session: session, operation: operation, digest: "fixture", tokenHash: "fixture")
            session = try #require(try await store.agentSession(execution: session.executionID))
            var scope = AgentCodexRecoveryTests.scope(); scope.execution["execution_id"] = .string(session.executionID); scope.operationID = operation
            let claim = AgentModelScopes.Claim(digest: "fixture", scope: scope, index: 1, codex: true)
            try await routes.recordCodexModelCall(scope: scope, claim: claim, phase: "started", body: ["reconnect_reason": "connection_expired", "connection_rotation": 2], model: scope.model, usage: nil, status: nil, transport: "websocket")
            let rows = try await store.agentEventRecords(execution: session.executionID)
            let data = try #require(try rows.flatMap { try JSONValue.parse($0.record).array ?? [] }.last?["data"])
            #expect(data["reconnect_reason"] == "connection_expired" && data["connection_rotation"] == 2)
            #expect(data["recovery_attempt"] == nil)
        }
    }

}
