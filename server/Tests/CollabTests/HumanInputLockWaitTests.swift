import CollabCore
@testable import CollabStore
import Foundation
import Logging
import PostgresNIO
import Testing

// The row-lock interleavings Winnie's review asked for. The writer holds the run's row on its own connection, **writes
// something and commits**; the reader is the real Store API. Each test proves two things: the API call was actually
// waiting on the lock (its backend blocked by the writer's pid, read from `pg_stat_activity`), and afterwards it saw the
// writer's committed change rather than a state read before the wait. Every wait is bounded, so a regression fails the
// test instead of hanging the suite.

/// The holder's backend pid, written after `FOR UPDATE` returns and read by the test.
actor PidBox {
    private var value: Int32 = 0
    func set(_ p: Int32) { value = p }
    func get() -> Int32 { value }
}

/// A one-shot signal: `wait()` returns once `open()` has been called.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    nonisolated func openSoon() { Task { await open() } }
}

private enum Db {
    static func client(schema: String, logger: Logger) -> PostgresClient {
        let port = Int(ProcessInfo.processInfo.environment["TEST_DB_PORT"] ?? "5432") ?? 5432
        var cfg = PostgresClient.Configuration(host: testDbHost!, port: port, username: "collab", password: "collab",
                                               database: "collab", tls: .disable)
        cfg.options.additionalStartupParameters = [("search_path", schema)]
        return PostgresClient(configuration: cfg, backgroundLogger: logger)
    }

    static func blockedBy(_ holder: Int32, _ client: PostgresClient, _ logger: Logger) async throws -> Int {
        try await client.withConnection { conn in
            var n = 0
            let rows = try await conn.query(
                "SELECT count(*) FROM pg_stat_activity WHERE \(holder) = ANY(pg_blocking_pids(pid))", logger: logger)
            for try await (c,) in rows { n = Int(try c.decode(Int64.self)) }
            return n
        }
    }
}

/// Starts a writer on its own connection: it locks the run's row, runs `write`, reports its pid, and holds the
/// transaction open until `gate` opens; `release` opens the gate and waits for the commit. Deliberately *not* a child of
/// the test's task group: a sibling that waits for the gate would keep the group from ever finishing.
func startWriter(schema: String, run: String, logger: Logger, gate: Gate, pid: PidBox,
                 _ write: @escaping @Sendable (PostgresConnection) async throws -> Void) async throws -> Task<Void, any Error> {
    let client = Db.client(schema: schema, logger: logger)
    let locked = Gate()
    let task = Task {
        // `PostgresClient.run()` suspends for the client's lifetime, so it needs its own task; awaited inline it would
        // never return and the whole test would wait for a lock that is never taken.
        let runner = Task { await client.run() }
        defer { runner.cancel() }
        try await client.withConnection { conn in
            _ = try await conn.query("BEGIN", logger: logger)
            let pidRows = try await conn.query("SELECT pg_backend_pid()", logger: logger)
            var backendPid: Int32 = 0
            for try await (p,) in pidRows { backendPid = try p.decode(Int32.self) }
            _ = try await conn.query("SELECT id FROM workflow_runs WHERE id = \(run) FOR UPDATE", logger: logger)
            try await write(conn)
            await pid.set(backendPid)
            await locked.open()
            await gate.wait()
            _ = try await conn.query("COMMIT", logger: logger)
        }
    }
    await locked.wait()
    return task
}

/// Runs `op`, giving up after `seconds` so a stuck lock fails the test instead of the suite timing out.
private func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await op() }
        group.addTask { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))); return nil }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Waits until the writer's pid is reported, then until some backend is blocked by it (the test's own explicit signal).
private func waitUntilBlocked(_ pid: PidBox, _ observer: PostgresClient, _ logger: Logger) async throws -> Int32 {
    var waited = 0
    while await pid.get() == 0 && waited < 500 {
        try await Task.sleep(for: .milliseconds(10))
        waited += 1
    }
    let holder = await pid.get()
    guard holder != 0 else { return 0 }
    for _ in 0..<500 {
        if try await Db.blockedBy(holder, observer, logger) > 0 { return holder }
        try await Task.sleep(for: .milliseconds(10))
    }
    return 0
}

@Suite("Human input lock waits", .enabled(if: testDbHost != nil))
struct HumanInputLockWaitTests {
    private static let inputs = #"[{"output_variable_name":"content","type":"paragraph"}]"#
    private static let actions = #"[{"id":"approve","title":"Approve"}]"#

    private func seed(_ store: PostgresStore, tokens: [String]) async throws -> String {
        let docId = "f-\(UUID().uuidString.lowercased().prefix(12))"
        _ = try await store.createDocument(id: docId, initial: Document(nodes: [Node(id: "human", type: "llm", config: [:])]))
        let runId = "run-\(UUID().uuidString.lowercased().prefix(12))"
        try await store.insertWorkflowRun(StoredWorkflowRun(
            id: runId, docId: docId, docSeq: 0, workflowId: docId, type: "workflow", triggeredFrom: "debugging",
            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: "u-1", createdAt: Date()))
        let at = Date()
        _ = try await store.createPause(
            workflowRunId: runId, docId: docId, snapshot: "{}",
            forms: tokens.enumerated().map { index, token in
                StoredHumanInputForm(
                    id: "form-\(index)", workflowRunId: runId, executionId: "exec-\(token)", docId: docId, nodeId: "human",
                    nodeTitle: "Approval", token: token, formContent: "c", inputs: Self.inputs, userActions: Self.actions,
                    renderedContent: "r", actions: Self.actions, displayInUi: true, createdAt: at)
            }, at: at)
        return runId
    }

    @Test func aSubmissionWaitsAndThenSeesTheExpiryTheWriterCommitted() async throws {
        try await withStoreAndSchema { store, logger, schema in
            let run = try await seed(store, tokens: ["tok-1"])
            let gate = Gate()
            let pid = PidBox()
            let observer = Db.client(schema: schema, logger: logger)
            defer { gate.openSoon() }
            let observe = Task { await observer.run() }
            defer { observe.cancel() }

            // The writer is the timeout scanner: it locks the run, marks the form `timed_out`, and commits only when the
            // test lets go — so a submission that read before the lock would accept a form that is already closed.
            let writer = try await startWriter(schema: schema, run: run, logger: logger, gate: gate, pid: pid) { conn in
                _ = try await conn.query("UPDATE human_input_forms SET status = 'timed_out' WHERE token = 'tok-1'",
                                         logger: logger)
            }
            let submit = Task {
                try await store.submitHumanInputForm(token: "tok-1", inputs: #"{"content":"x"}"#, action: "approve",
                                                     userId: "u-1")
            }
            let holder = try await waitUntilBlocked(pid, observer, logger)
            #expect(holder != 0, "the submission must wait on the run's row lock")
            await gate.open()
            _ = try? await withTimeout(20) { try await writer.value }
            let outcome = try await withTimeout(20) { try await submit.value }
            #expect(outcome == .expired, "after the wait it must see the committed timeout, got \(String(describing: outcome))")
        }
    }

    @Test func aClaimWaitsAndThenTakesTheAnswerTheWriterCommitted() async throws {
        try await withStoreAndSchema { store, logger, schema in
            let run = try await seed(store, tokens: ["tok-1", "tok-2"])
            let gate = Gate()
            let pid = PidBox()
            let observer = Db.client(schema: schema, logger: logger)
            defer { gate.openSoon() }
            let observe = Task { await observer.run() }
            defer { observe.cancel() }

            // The writer commits tok-2's answer while holding the run: a claim that read before the lock would find
            // nothing to resume on, and one that waits must take exactly that answer.
            let writer = try await startWriter(schema: schema, run: run, logger: logger, gate: gate, pid: pid) { conn in
                _ = try await conn.query("""
                    UPDATE human_input_forms SET status = 'submitted', submitted_inputs = '{}', submitted_action = 'approve',
                        submitted_by = 'u-1', submitted_at = now() WHERE token = 'tok-2'
                    """, logger: logger)
                _ = try await conn.query("""
                    UPDATE workflow_pauses SET resume_requested = true
                    WHERE workflow_run_id = \(run) AND resumed_at IS NULL
                    """, logger: logger)
            }
            let claim = Task { try await store.claimResume(workflowRunId: run, at: Date()) }
            let holder = try await waitUntilBlocked(pid, observer, logger)
            #expect(holder != 0, "the claim must wait on the run's row lock")
            await gate.open()
            _ = try? await withTimeout(20) { try await writer.value }
            let claimed = try await withTimeout(20) { try await claim.value }
            #expect(claimed != nil, "the claim must finish once the lock is free")
            #expect(claimed!?.decisions.map(\.executionId) == ["exec-tok-2"],
                    "it takes the answer the writer committed while it waited")
        }
    }
}
