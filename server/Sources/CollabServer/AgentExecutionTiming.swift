import CollabRuntime
import Foundation

/// Version one remains attached to old paused executions. New executions start
/// their execution budget only after durable capacity admission, before dispatch.
struct AgentExecutionTiming {
    let version: Int
    let queuedAt: Date
    let timeout: Int
    let previousActive: Double
    let previousQueue: Double
    private let queueDeadline: Date
    private var started: ContinuousClock.Instant?
    private(set) var admittedAt: Date?
    private var runningDeadline: Date?

    init(timeout: Int, admissionTimeout: Int, usage: JSONValue?, queuedAt: Date = Date(), entered: ContinuousClock.Instant = .now) throws {
        version = usage == nil || usage?["timing_version"] == 2 ? 2 : 1
        self.queuedAt = queuedAt; self.timeout = timeout
        previousActive = usage?["active_elapsed_time"]?.double ?? 0
        previousQueue = usage?["queued_elapsed_time"]?.double ?? 0
        guard previousActive.isFinite, previousActive >= 0, previousQueue.isFinite, previousQueue >= 0 else {
            throw NodeError("AgentResumeInvalid", "Invalid recorded agent time budget")
        }
        queueDeadline = queuedAt.addingTimeInterval(Double(admissionTimeout))
        if version == 1 {
            started = entered
            runningDeadline = queuedAt.addingTimeInterval(Double(timeout) - previousActive)
        }
    }

    var waitingDeadline: Date { runningDeadline ?? queueDeadline }
    var isWaitingForAdmission: Bool { version == 2 && admittedAt == nil }
    var deadline: Date { runningDeadline ?? queueDeadline }
    var remainingExecutionSeconds: Int { remainingExecutionSeconds(at: Date()) }
    func remainingExecutionSeconds(at now: Date) -> Int {
        let remaining = runningDeadline?.timeIntervalSince(now) ?? (Double(timeout) - previousActive)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(min(Double(timeout), floor(remaining)))
    }

    mutating func admitted(at wall: Date = Date(), monotonic: ContinuousClock.Instant = .now) {
        guard admittedAt == nil else { return }
        admittedAt = wall
        if version == 2 {
            let remaining = Int(min(Double(timeout), floor(max(0, Double(timeout) - previousActive))))
            started = monotonic
            runningDeadline = wall.addingTimeInterval(Double(remaining))
        }
    }

    func activeElapsed(at now: ContinuousClock.Instant = .now) -> Double {
        guard let started else { return previousActive }
        let elapsed = started.duration(to: now).components
        return previousActive + max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    var queuedElapsed: Double { previousQueue + max(0, (admittedAt ?? Date()).timeIntervalSince(queuedAt)) }
    var usage: JSONObject {
        guard version == 2 else { return [:] }
        return ["timing_version": 2, "queued_elapsed_time": .double(queuedElapsed),
                "execution_started_at": admittedAt.map { .double($0.timeIntervalSince1970) } ?? .null]
    }
    var metadata: JSONObject {
        guard version == 2 else { return [:] }
        return ["agent_timing_version": 2, "agent_queue_elapsed_time": .double(queuedElapsed),
                "agent_execution_started_at": admittedAt.map { .double($0.timeIntervalSince1970) } ?? .null]
    }
}
