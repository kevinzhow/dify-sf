import CollabRuntime
import Foundation
import NIOCore
import Testing
@testable import CollabServer

@Suite(.serialized)
struct AgentCodexRecoveryTests {
    static func scope() -> AgentModelScope {
        var s = AgentResponsesTests.scope(); s.maxCalls = 20; s.codexWebsocketRecoveryEnabled = true; return s
    }
    static func idle() -> Task<Void, Never> { Task { try? await Task.sleep(for: .seconds(30)) } }
    static let checkpoint = AgentCodexSocketCheckpoint(parameters: "stable")

    @Test(arguments: [false, true]) func deploymentMustOptInAndCounterIsShared(enabled: Bool) async throws {
        let scopes = AgentModelScopes(); var s = Self.scope(); s.codexWebsocketRecoveryEnabled = enabled
        let token = try await scopes.activate(s), task = Self.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "one", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        let first = try await scopes.claimCodex(token: token); await scopes.finish(first, usage: nil, succeeded: false)
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint) == enabled)
        if enabled {
            let c = try await scopes.openCodexSocket(token: token, lane: "root", id: "two", task: task)
            #expect(c?.parameters == "stable")
            let second = try await scopes.claimCodex(token: token); #expect(second.index == 2)
            await scopes.finish(second, usage: nil)
            #expect(!(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint)))
        }
        try await scopes.openCodexSocket(token: token, lane: "child", id: "child", task: task)
        try await scopes.startCodexSocket(token: token, lane: "child")
        #expect(!(try await scopes.offerCodexRecovery(token: token, lane: "child", checkpoint: Self.checkpoint)))
    }

    @Test func cancellationCannotReserveOrConsumeTheRecovery() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(Self.scope()), idle = Self.idle()
        defer { idle.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "one", task: idle)
        try await scopes.startCodexSocket(token: token, lane: "root")
        let cancelled = Task {
            try? await Task.sleep(for: .seconds(30))
            return try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancellation authorized recovery") }
        catch is CancellationError { }
        // The cancelled reservation did not consume the execution's one permitted recovery.
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint))
    }

    @Test func concurrentChildrenCannotReserveTwoRecoveries() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(Self.scope()), task = Self.idle(); defer { task.cancel() }
        for lane in ["root", "child"] {
            try await scopes.openCodexSocket(token: token, lane: lane, id: lane, task: task)
            try await scopes.startCodexSocket(token: token, lane: lane)
        }
        async let root = scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint)
        async let child = scopes.offerCodexRecovery(token: token, lane: "child", checkpoint: Self.checkpoint)
        let (r, c) = try await (root, child); #expect([r, c].filter { $0 }.count == 1)
    }

    @Test func staleCloseCannotReleaseTheReplacementSocket() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(Self.scope()), task = Self.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "old", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint))
        _ = try await scopes.openCodexSocket(token: token, lane: "root", id: "new", task: task)
        await scopes.closeCodexSocket(token: token, lane: "root", id: "old")
        do { try await scopes.openCodexSocket(token: token, lane: "root", id: "third", task: task); Issue.record("Stale close released a new socket") }
        catch let e as AgentCodexSocketError { #expect(e.code == "agent_incremental_context_lost" || e.code == "agent_socket_limit") }
    }

    @Test func tokenReplacementDoesNotResetTheNodeExecutionBudget() async throws {
        let scopes = AgentModelScopes(), s = Self.scope(), task = Self.idle(); defer { task.cancel() }
        let old = try await scopes.activate(s)
        try await scopes.openCodexSocket(token: old, lane: "root", id: "old", task: task)
        try await scopes.startCodexSocket(token: old, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: old, lane: "root", checkpoint: Self.checkpoint))
        _ = await scopes.revoke(token: old)
        let new = try await scopes.activate(s)
        try await scopes.openCodexSocket(token: new, lane: "child", id: "new", task: task)
        try await scopes.startCodexSocket(token: new, lane: "child")
        #expect(!(try await scopes.offerCodexRecovery(token: new, lane: "child", checkpoint: Self.checkpoint)))
        do { _ = try await scopes.offerCodexRecovery(token: old, lane: "root", checkpoint: Self.checkpoint); Issue.record("Revoked capability recovered") } catch {}
    }

    @Test func exhaustedCallsAndUnsafeToolIdentitiesCannotRecover() async throws {
        let scopes = AgentModelScopes(); var s = Self.scope(); s.maxCalls = 1
        let token = try await scopes.activate(s), task = Self.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "one", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        #expect(!(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: .init(parameters: nil, unsafe: true))))
        let last = try await scopes.claimCodex(token: token); await scopes.finish(last, usage: nil, succeeded: false)
        #expect(!(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint)))
    }

    @Test func expiryAndOwnershipChangeStillRejectRecovery() async throws {
        let scopes = AgentModelScopes(); var s = Self.scope(); let task = Self.idle(); defer { task.cancel() }
        let old = try await scopes.activate(s)
        try await scopes.openCodexSocket(token: old, lane: "root", id: "one", task: task)
        try await scopes.startCodexSocket(token: old, lane: "root")
        s.generation += 1; _ = try await scopes.activate(s)
        do { _ = try await scopes.offerCodexRecovery(token: old, lane: "root", checkpoint: Self.checkpoint); Issue.record("Stale generation recovered") } catch {}
        let expiring = AgentModelScopes(); s.expiresAt = Date().addingTimeInterval(0.05)
        let token = try await expiring.activate(s)
        try await expiring.openCodexSocket(token: token, lane: "root", id: "expiry", task: task)
        try await expiring.startCodexSocket(token: token, lane: "root")
        try await Task.sleep(for: .milliseconds(80))
        do { _ = try await expiring.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint); Issue.record("Expired scope recovered") } catch {}
    }

    @Test(arguments: [false, true]) func partialToolCallRequiresItsActualResultBeforeAnotherGeneration(resultKnown: Bool) async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: scope.model,
                    credentials: ["api_type": "responses", "endpoint_url": "http://127.0.0.1:1", "api_key": "fixture-key"])
                let task = Self.idle(); defer { task.cancel() }
                try await routes.agentModelScopes.openCodexSocket(token: token, lane: "root", id: "one", task: task)
                let old = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection)
                var body = AgentResponsesTests.body(scope).object!; body["type"] = "response.create"
                _ = try await old.prepare(JSONValue.object(body).compactData())
                _ = try await old.observe(JSONValue.object(["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "side-effect", "name": "exec_command", "arguments": "{}"]]).compactData())
                await old.finish()
                let checkpoint = await old.checkpoint(); #expect(checkpoint.pendingTools == ["side-effect"])
                let recovered = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection, recovery: checkpoint)
                if resultKnown {
                    body["input"] = .array((body["input"]?.array ?? []) + [["type": "function_call_output", "call_id": "side-effect", "output": "completed"]])
                    _ = try await recovered.prepare(JSONValue.object(body).compactData())
                    await recovered.finish()
                    let next = try await routes.agentModelScopes.claimCodex(token: token); #expect(next.index == 3)
                } else {
                    do { _ = try await recovered.prepare(JSONValue.object(body).compactData()); Issue.record("Unknown side effect replayed") }
                    catch let e as AgentCodexSocketError { #expect(e.code == "agent_recovery_tool_result_unknown") }
                    let next = try await routes.agentModelScopes.claimCodex(token: token); #expect(next.index == 2)
                }
            }
        }
    }
}
