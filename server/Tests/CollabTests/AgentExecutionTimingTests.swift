import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent admission and execution clocks")
struct AgentExecutionTimingTests {
    @Test func aLongQueueDoesNotConsumeANewExecutionBudget() throws {
        let wall = Date(), clock = ContinuousClock.now
        var timing = try AgentExecutionTiming(timeout: 1800, admissionTimeout: 10800, usage: nil, queuedAt: wall, entered: clock)
        #expect(timing.version == 2 && timing.isWaitingForAdmission)
        #expect(timing.remainingExecutionSeconds(at: wall.addingTimeInterval(1900)) == 1800)
        #expect(timing.activeElapsed(at: clock.advanced(by: .seconds(1900))) == 0)
        timing.admitted(at: wall.addingTimeInterval(1900), monotonic: clock.advanced(by: .seconds(1900)))
        #expect(timing.remainingExecutionSeconds(at: wall.addingTimeInterval(1900)) == 1800)
        #expect(timing.activeElapsed(at: clock.advanced(by: .seconds(1910))) == 10)
        #expect(timing.queuedElapsed == 1900)
        #expect(timing.usage["timing_version"] == 2)
        #expect(timing.metadata["agent_queue_elapsed_time"]?.double == 1900)
        #expect(timing.remainingExecutionSeconds(at: wall.addingTimeInterval(3700)) == 0)
    }
    @Test func resumeDeductsPriorExecutionAndOutputRetriesNeverResetTheClock() throws {
        let wall = Date(), clock = ContinuousClock.now
        var timing = try AgentExecutionTiming(timeout: 1800, admissionTimeout: 600,
            usage: ["timing_version": 2, "active_elapsed_time": 121, "queued_elapsed_time": 18], queuedAt: wall, entered: clock)
        #expect(timing.remainingExecutionSeconds(at: wall) == 1679)
        timing.admitted(at: wall.addingTimeInterval(30), monotonic: clock.advanced(by: .seconds(30)))
        let deadline = timing.deadline
        timing.admitted(at: wall.addingTimeInterval(120), monotonic: clock.advanced(by: .seconds(120)))
        #expect(timing.deadline == deadline)
        #expect(timing.queuedElapsed == 48)
        #expect(timing.activeElapsed(at: clock.advanced(by: .seconds(130))) == 221)
        #expect(timing.remainingExecutionSeconds(at: wall.addingTimeInterval(130)) == 1579)
    }
    @Test func oldPausedSessionsRetainTheirExistingQueueAndExecutionClock() throws {
        let wall = Date(), clock = ContinuousClock.now
        var legacy = try AgentExecutionTiming(timeout: 1800, admissionTimeout: 600,
            usage: ["active_elapsed_time": 100], queuedAt: wall, entered: clock)
        #expect(legacy.version == 1 && !legacy.isWaitingForAdmission)
        #expect(legacy.remainingExecutionSeconds(at: wall.addingTimeInterval(1600)) == 100)
        legacy.admitted(at: wall.addingTimeInterval(1600), monotonic: clock.advanced(by: .seconds(1600)))
        #expect(legacy.remainingExecutionSeconds(at: wall.addingTimeInterval(1700)) == 0)
        #expect(legacy.activeElapsed(at: clock.advanced(by: .seconds(1600))) == 1700)
        #expect(legacy.metadata.isEmpty && legacy.usage.isEmpty)
    }
    @Test func waitingHasItsOwnDeadlineAndCorruptBudgetsAreRejected() throws {
        let wall = Date()
        let waiting = try AgentExecutionTiming(timeout: 1800, admissionTimeout: 60, usage: nil, queuedAt: wall)
        #expect(waiting.waitingDeadline == wall.addingTimeInterval(60))
        for value in [-1, Double.infinity, Double.nan] {
            #expect(throws: NodeError.self) {
                _ = try AgentExecutionTiming(timeout: 1800, admissionTimeout: 60, usage: ["timing_version": 2, "active_elapsed_time": .double(value)])
            }
        }
        let exhausted = try AgentExecutionTiming(timeout: 1800, admissionTimeout: 60, usage: ["timing_version": 2, "active_elapsed_time": 1800])
        #expect(exhausted.remainingExecutionSeconds == 0)
    }
    @Test func aPremintedCapabilityHasNoAuthorityUntilActivatedAndCannotBeReused() async throws {
        let scopes = AgentModelScopes(), scope = AgentModelScopeTests.scope(), token = Tokens.random()
        let request = try AgentModelScopeTests.request(scope)
        await #expect(throws: (any Error).self) { _ = try await scopes.claim(token: token, request: request) }
        #expect(try await scopes.activate(scope, token: token) == token)
        await #expect(throws: (any Error).self) { _ = try await scopes.activate(scope, token: token) }
        _ = await scopes.revoke(token: token)
    }
    @Test func admissionLogsKeepStableIdentityAndExplicitQueueStatus() throws {
        let queued = AgentTrace.project(run: "admission:execution:0", node: "node", event: 0, name: "admission", data: ["phase": "queued"], secrets: [])
        #expect(queued.log?["message_id"] == "admission:execution:0:0")
        #expect(queued.log?["metadata"]?["event"] == "admission" && queued.log?["status"] == "start")
        let expired = AgentTrace.project(run: "admission:execution:0", node: "node", event: 1, name: "admission", data: ["phase": "expired"], secrets: [])
        #expect(expired.log?["status"] == "failed")
    }
}
