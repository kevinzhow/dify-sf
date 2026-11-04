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
        for (offset, lane) in ["root", "child", "other-child", "fourth"].enumerated() {
            try await scopes.openCodexSocket(token: token, lane: lane, id: lane, task: task)
            try await scopes.startCodexSocket(token: token, lane: lane)
            let claim = try await scopes.claimCodex(token: token); #expect(claim.index == offset + 1)
            await scopes.finish(claim, usage: nil, succeeded: false)
            let attempt = try await scopes.offerCodexRecovery(token: token, lane: lane, checkpoint: Self.checkpoint)
            #expect(attempt == (enabled && offset < 3 ? offset + 1 : nil))
            if attempt != nil {
                let c = try await scopes.openCodexSocket(token: token, lane: lane, id: "replacement-\(lane)", task: task)
                #expect(c?.parameters == "stable" && c?.recoveryAttempt == attempt)
            }
        }
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
        // The cancelled reservation did not consume the execution's recovery quota.
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint) != nil)
    }

    @Test func concurrentChildrenCannotExceedThreeRecoveries() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(Self.scope()), task = Self.idle(); defer { task.cancel() }
        for lane in ["root", "a", "b", "c", "d", "e", "f", "g"] {
            try await scopes.openCodexSocket(token: token, lane: lane, id: lane, task: task)
            try await scopes.startCodexSocket(token: token, lane: lane)
        }
        let results = try await withThrowingTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for lane in ["root", "a", "b", "c", "d", "e", "f", "g"] {
                group.addTask { try await scopes.offerCodexRecovery(token: token, lane: lane, checkpoint: Self.checkpoint) }
            }
            var results: [Int] = []; for try await value in group { if let value { results.append(value) } }; return results
        }
        #expect(results.sorted() == [1, 2, 3])
    }

    @Test func staleCloseCannotReleaseTheReplacementSocket() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(Self.scope()), task = Self.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "old", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint) != nil)
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
        #expect(try await scopes.offerCodexRecovery(token: old, lane: "root", checkpoint: Self.checkpoint) != nil)
        _ = await scopes.revoke(token: old)
        let new = try await scopes.activate(s)
        try await scopes.openCodexSocket(token: new, lane: "child", id: "new", task: task)
        try await scopes.startCodexSocket(token: new, lane: "child")
        #expect(try await scopes.offerCodexRecovery(token: new, lane: "child", checkpoint: Self.checkpoint) == 2)
        _ = try await scopes.openCodexSocket(token: new, lane: "child", id: "replacement", task: task)
        #expect(try await scopes.offerCodexRecovery(token: new, lane: "child", checkpoint: Self.checkpoint) == 3)
        _ = try await scopes.openCodexSocket(token: new, lane: "child", id: "last", task: task)
        #expect(try await scopes.offerCodexRecovery(token: new, lane: "child", checkpoint: Self.checkpoint) == nil)
        do { _ = try await scopes.offerCodexRecovery(token: old, lane: "root", checkpoint: Self.checkpoint); Issue.record("Revoked capability recovered") } catch {}
    }

    @Test func exhaustedCallsAndUnsafeToolIdentitiesCannotRecover() async throws {
        let scopes = AgentModelScopes(); var s = Self.scope(); s.maxCalls = 1
        let token = try await scopes.activate(s), task = Self.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "one", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: .init(parameters: nil, unsafe: true)) == nil)
        let last = try await scopes.claimCodex(token: token); await scopes.finish(last, usage: nil, succeeded: false)
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint) == nil)
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

    @Test func reservationCannotBeRepeatedBeforeReconnect() async throws {
        let scopes = AgentModelScopes(), token = try await scopes.activate(Self.scope()), task = Self.idle(); defer { task.cancel() }
        try await scopes.openCodexSocket(token: token, lane: "root", id: "old", task: task)
        try await scopes.startCodexSocket(token: token, lane: "root")
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint) == 1)
        #expect(try await scopes.offerCodexRecovery(token: token, lane: "root", checkpoint: Self.checkpoint) == nil)
        let checkpoint = try await scopes.openCodexSocket(token: token, lane: "root", id: "new", task: task)
        #expect(checkpoint?.recoveryAttempt == 1)
    }

    @Test func replacementFailureKeepsTheOriginalToolAndParameterCheckpoint() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServerAndRoutes(config: AgentModelGatewayRouteTests.config(daemon)) { api, store, routes in
                let (scope, token) = try await AgentResponsesRouteTests.fixture(api, store, routes, endpoint: "http://127.0.0.1:1")
                let connection = try AgentResponsesConnection(provider: AgentModelWire.compatible, model: scope.model,
                    credentials: ["api_type": "responses", "endpoint_url": "http://127.0.0.1:1", "api_key": "fixture-key"])
                let original = AgentCodexSocketCheckpoint(parameters: "original-parameters", recoveryAttempt: 2,
                    pendingTools: ["dispatched-effect"], announcedTools: 1)
                let replacement = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection, recovery: original)
                let retained = await replacement.checkpoint()
                #expect(retained.parameters == "original-parameters" && retained.pendingTools == ["dispatched-effect"])
                #expect(retained.recoveryAttempt == 2 && retained.announcedTools == 1)
            }
        }
    }

    @Test func eachRecoveryAttemptIsPersistedWithItsActualNumber() async throws {
        try await withServerAndRoutes { api, store, routes in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            let operation = "\(session.executionID):0:0"
            try await store.startAgentOperation(session: session, operation: operation, digest: "fixture", tokenHash: "fixture")
            session = try #require(try await store.agentSession(execution: session.executionID))
            var scope = Self.scope(); scope.execution["execution_id"] = .string(session.executionID); scope.operationID = operation
            for attempt in 1...3 {
                let claim = AgentModelScopes.Claim(digest: "fixture", scope: scope, index: attempt, codex: true)
                try await routes.recordCodexModelCall(scope: scope, claim: claim, phase: "started",
                    body: ["recovery_attempt": .int(attempt)], model: scope.model, usage: nil, status: nil, transport: "websocket")
            }
            let events = try await store.agentEventRecords(execution: session.executionID)
            let attempts = try events.flatMap { try JSONValue.parse($0.record).array ?? [] }.compactMap { $0["data"]?["recovery_attempt"]?.int }
            #expect(attempts == [1, 2, 3])
        }
    }

    @Test func backoffHonorsDeadlineAndCancellation() async throws {
        #expect((1...3).map(AgentCodexRecoveryPolicy.delayMilliseconds) == [1000, 2000, 4000])
        do { try await AgentCodexRecoveryPolicy.wait(attempt: 3, expiresAt: Date().addingTimeInterval(0.1)); Issue.record("Backoff extended deadline") }
        catch let e as AgentCodexSocketError { #expect(e.code == "agent_run_forbidden") }
        let task = Task { try await AgentCodexRecoveryPolicy.wait(attempt: 3, expiresAt: Date().addingTimeInterval(30)) }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled backoff continued") } catch is CancellationError {}
    }

    @Test func onlyTransientTransportLossesAreEligible() {
        for code: UInt16 in [1000, 1002, 1003, 1007, 1008, 1009, 1010, 4001] {
            #expect(!AgentCodexRecoveryPolicy.isTransient(AgentCodexTransportLoss.closeFrame(code)))
        }
        for code: UInt16 in [1001, 1011, 1012, 1013] {
            #expect(AgentCodexRecoveryPolicy.isTransient(AgentCodexTransportLoss.closeFrame(code)))
        }
        #expect(AgentCodexRecoveryPolicy.isTransient(AgentCodexTransportLoss.eof))
        #expect(AgentCodexRecoveryPolicy.isTransient(IOError(errnoCode: 104, reason: "reset")))
        #expect(!AgentCodexRecoveryPolicy.isTransient(CancellationError()))
        #expect(!AgentCodexRecoveryPolicy.isTransient(AgentCodexSocketError(status: 401, code: "unauthorized")))
        #expect(!AgentCodexRecoveryPolicy.isTransient(AgentCodexSocketError(status: 502, code: "agent_model_protocol")))
    }

    @Test(arguments: [false, true], ["function_call", "custom_tool_call"]) func dispatchedToolRequiresItsActualResultBeforeAnotherGeneration(resultKnown: Bool, kind: String) async throws {
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
                _ = try await old.observe(JSONValue.object(["type": "response.output_item.done", "item": ["type": .string(kind), "call_id": "side-effect", "name": "exec_command", "arguments": "{}"]]).compactData())
                await old.finish()
                let checkpoint = await old.checkpoint(); #expect(checkpoint.pendingTools == ["side-effect"])
                let recovered = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection, recovery: checkpoint)
                if resultKnown {
                    body["input"] = .array((body["input"]?.array ?? []) + [["type": .string(kind == "function_call" ? "function_call_output" : "custom_tool_call_output"), "call_id": "side-effect", "output": "Process running with session ID 123"]])
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
    @Test(arguments: ["function_call", "custom_tool_call"])
    func announcedToolWithOnlyArgumentsDoneCanRecoverWithoutAnExecutionResult(kind: String) async throws {
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
                let item: JSONValue = ["type": .string(kind), "id": "item-partial", "call_id": "not-dispatched",
                    "name": "exec_command", "arguments": "", "input": ""]
                _ = try await old.observe(JSONValue.object(["type": "response.output_item.added", "item": item]).compactData())
                _ = try await old.observe(JSONValue.object(["type": .string(kind == "function_call" ? "response.function_call_arguments.done" : "response.custom_tool_call_input.done"),
                    "item_id": "item-partial", "arguments": "{}", "input": "partial command"]).compactData())
                await old.finish()
                let checkpoint = await old.checkpoint()
                #expect(checkpoint.pendingTools.isEmpty)
                #expect(!checkpoint.unsafe)
                let recovered = AgentCodexSocketSession(routes: routes, token: token, lane: "root", connection: connection, recovery: checkpoint)
                _ = try await recovered.prepare(JSONValue.object(body).compactData())
                await recovered.finish()
                let next = try await routes.agentModelScopes.claimCodex(token: token); #expect(next.index == 3)
            }
        }
    }

}
