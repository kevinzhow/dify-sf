import CollabCore
@testable import CollabStore
import Foundation
import Logging
import Testing

// Human-input persistence (protocol 1.16), following Dify 1.17.1:
//   * `services/human_input_service.py` `enqueue_resume` runs on every submission;
//   * `callback.py` pauses again for the forms that still wait, so one answered form resumes the run;
//   * `tasks/human_input_timeout_tasks.py` marks a node deadline TIMEOUT (and resumes) and a global deadline EXPIRED
//     (and stops the run, closing the pause);
//   * `models/workflow.py` `WorkflowPause` is zero-or-one per run.
// Real Postgres (server/run-db-tests.sh).

@Suite("Human input forms (store)", .enabled(if: testDbHost != nil))
struct HumanInputFormStoreTests {
    private func run(_ store: PostgresStore) async throws -> (doc: String, run: String) {
        let docId = "f-\(UUID().uuidString.lowercased().prefix(12))"
        _ = try await store.createDocument(id: docId, initial: Document(nodes: [Node(id: "human", type: "llm", config: [:])]))
        let runId = "run-\(UUID().uuidString.lowercased().prefix(12))"
        try await store.insertWorkflowRun(StoredWorkflowRun(
            id: runId, docId: docId, docSeq: 0, workflowId: docId, type: "workflow", triggeredFrom: "debugging",
            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: "u-1", createdAt: Date()))
        return (docId, runId)
    }

    private func form(_ doc: String, run: String, execution: String, token: String, node: String = "human",
                      expiration: Int? = nil, now: Date = Date()) -> StoredHumanInputForm {
        StoredHumanInputForm(
            id: "form-\(execution)", workflowRunId: run, executionId: execution, docId: doc, nodeId: node,
            nodeTitle: "Approval", token: token, formContent: #"{"a":"b"}"#, inputs: #"[{"type":"paragraph"}]"#,
            userActions: #"[{"id":"approve"}]"#, renderedContent: "Please approve", defaultValues: #"{"x":"1"}"#,
            resolvedDefaultValues: #"{"x":"1"}"#, actions: #"[{"id":"approve"}]"#, displayInUi: true,
            expirationTime: expiration, createdAt: now)
    }

    private func pause(_ store: PostgresStore, _ doc: String, _ run: String, forms: [StoredHumanInputForm], at: Date) async throws -> Int {
        try await store.createPause(workflowRunId: run, docId: doc, snapshot: #"{"frames":[]}"#, forms: forms, at: at)
    }

    private func runStatus(_ store: PostgresStore, _ doc: String, _ run: String) async throws -> String? {
        try await store.workflowRun(doc: doc, id: run)?.status
    }

    @Test func pauseAndFormsAreReadBackUnchanged() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            let generation = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            #expect(generation == 1)
            #expect(try await runStatus(store, doc, run) == "paused", "a durable pause is the run's state")

            let read = try await store.humanInputForm(token: "tok-a")
            #expect(read?.generation == 1 && read?.status == .waiting)
            #expect(read?.formContent == #"{"a":"b"}"# && read?.defaultValues == #"{"x":"1"}"#)
            let stored = try await store.pause(workflowRunId: run, generation: 1)
            #expect(stored?.snapshot == #"{"frames":[]}"#)
            #expect(stored?.resumeRequested == false, "a waiting form has not woken the run")
        }
    }

    @Test func oneAnsweredFormResumesTheRunWhileAnotherStillWaits() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                     form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            let answer = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                             )
            guard case .accepted = answer else {
                Issue.record("A's answer must be accepted, got \(answer)")
                return
            }
            // Dify resumes on every submission and pauses again for B: A alone is enough.
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == true)
            #expect(try await store.humanInputForm(token: "tok-b")?.status == .waiting)
            let claim = try await store.claimResume(workflowRunId: run, at: at)
            #expect(claim?.generation == 1)
            #expect(try await runStatus(store, doc, run) == "running")
            // The resume takes A's decision, and only A's: B is still waiting and belongs to no decision yet.
            #expect(claim?.decisions.map(\.executionId) == ["exec-a"])
            #expect(claim?.decisions.first?.submittedInputs == "{}", "the resume can still read what was submitted")
            #expect(try await store.humanInputForm(token: "tok-a")?.consumedAt != nil, "A's answer is consumed by the resume")
            #expect(try await store.humanInputForm(token: "tok-a")?.submittedInputs == "{}", "consuming is not deleting")
            #expect(try await store.humanInputForm(token: "tok-b")?.consumedAt == nil, "B is untouched")
        }
    }

    @Test func anAnswerGivenAfterTheResumeWakesTheNextPause() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                     form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", )
            _ = try await store.claimResume(workflowRunId: run, at: at)

            // Winnie's interleaving: the resume is under way, B answers, and only afterwards the next pause is written.
            _ = try await store.submitHumanInputForm(token: "tok-b", inputs: "{}", action: "approve", userId: "u-1", )
            let generation = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-c", token: "tok-c")], at: at)
            #expect(generation == 2)
            // B was answered before this pause existed and no resume has consumed it, so the new pause starts awake even
            // though B's form stays with generation 1 (it is not `waiting` any more).
            let b = try await store.humanInputForm(token: "tok-b")
            #expect(b?.status == .submitted && b?.generation == 1)
            #expect(try await store.pause(workflowRunId: run, generation: 2)?.resumeRequested == true,
                    "a submission made before the pause is written must not be lost")
        }
    }

    @Test func aConsumedAnswerDoesNotWakeTheNextPause() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", )
            #expect(try await store.claimResume(workflowRunId: run, at: at)?.generation == 1)
            // A was in that resume; the next pause must not wake on it again.
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-c", token: "tok-c")], at: at)
            #expect(try await store.pause(workflowRunId: run, generation: 2)?.resumeRequested == false)
        }
    }

    @Test func aRunHasAtMostOneOpenPause() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            // A second pause while the first is not resumed would be a second pause of the same run (Dify keeps one).
            await #expect(throws: (any Error).self) {
                try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                            forms: [form(doc, run: run, execution: "exec-c", token: "tok-c")], at: at)
            }
            #expect(try await store.openPauses(workflowRunId: run).count == 1)
            // After the resume the run may pause again, as generation 2.
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", )
            #expect(try await store.claimResume(workflowRunId: run, at: at)?.generation == 1)
            #expect(try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-d", token: "tok-d")], at: at) == 2)
        }
    }

    @Test func claimingNeedsAPausedRunAndAnUnconsumedAnswer() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            // Running, no pause at all.
            #expect(try await store.claimResume(workflowRunId: run, at: at) == nil)
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            // Paused, nothing answered: not ready.
            #expect(try await store.claimResume(workflowRunId: run, at: at) == nil)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", )
            #expect(try await store.claimResume(workflowRunId: run, at: at)?.generation == 1)
            // Already resumed: the same answer cannot claim twice.
            #expect(try await store.claimResume(workflowRunId: run, at: at) == nil)
            #expect(try await runStatus(store, doc, run) == "running")
        }
    }

    @Test func aNodeTimeoutResumesTheRunWhileAGlobalTimeoutStopsIt() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            // Node deadline (`expiration_time`): mark TIMEOUT, ask for a resume, the node takes its `__timeout` branch.
            #expect(try await store.endHumanInputForm(token: "tok-a", status: .timedOut, at: at))
            #expect(try await store.humanInputForm(token: "tok-a")?.status == .timedOut)
            #expect(try await runStatus(store, doc, run) == "paused", "a node deadline does not end the run")
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == true)
            #expect(try await store.claimResume(workflowRunId: run, at: at)?.generation == 1)

            // Global deadline: every waiting form expires, the run stops and the pause closes.
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            try await store.expireRunForGlobalTimeout(workflowRunId: run, error: "Human input global timeout at node human", at: at)
            #expect(try await store.humanInputForm(token: "tok-b")?.status == .expired)
            #expect(try await runStatus(store, doc, run) == "stopped")
            #expect(try await store.openPauses(workflowRunId: run).isEmpty)
            #expect(try await store.claimResume(workflowRunId: run, at: at) == nil, "a stopped run cannot resume")
        }
    }

    @Test func theNextPauseCarriesAnUnconsumedAnswerIntoItsSetAndTheClaimTakesIt() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                         form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", )
            #expect(try await store.claimResume(workflowRunId: run, at: at)?.decisions.map(\.executionId) == ["exec-a"])
            // B answers while the resume runs; the next pause is written with C only.
            _ = try await store.submitHumanInputForm(token: "tok-b", inputs: "{}", action: "approve", userId: "u-1", )
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-c", token: "tok-c")], at: at)

            // B is not in the forms this pause wrote, but its answer is a decision the snapshot still carries: the set
            // must include it, or the flag would be true while the claim had nothing to take.
            let second = try await store.pause(workflowRunId: run, generation: 2)
            #expect(second?.executionIds.sorted() == ["exec-b", "exec-c"])
            #expect(second?.resumeRequested == true)
            let claim = try await store.claimResume(workflowRunId: run, at: at)
            #expect(claim?.generation == 2)
            #expect(claim?.decisions.map(\.executionId) == ["exec-b"], "the claim takes the answer the flag woke on")
            // With B taken, nothing is unconsumed in that set: a third pause is not woken by it.
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-d", token: "tok-d")], at: at)
            #expect(try await store.pause(workflowRunId: run, generation: 3)?.resumeRequested == false)
        }
    }

    @Test func aSubmissionPastTheNodeDeadlineIsRefusedAndLeavesTheFormWaiting() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            let past = Int(at.timeIntervalSince1970) - 60
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a", expiration: past)], at: at)
            // `ensure_form_active` checks the node deadline itself: the scanner may not have run yet.
            let outcome = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                               )
            #expect(outcome == .expired)
            #expect(try await store.humanInputForm(token: "tok-a")?.status == .waiting,
                    "the scanner marks TIMEOUT; the submission only refuses")
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == false)
        }
    }

    @Test func aSubmissionPastTheGlobalDeadlineIsRefused() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let old = Date().addingTimeInterval(-8 * 24 * 3600)
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a", now: old)], at: Date())
            let outcome = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                               globalTimeoutSeconds: 7 * 24 * 3600)
            #expect(outcome == .expired, "the global deadline applies even when the node one has not passed")
        }
    }

    @Test func aStoppedRunCannotBePausedAgain() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            _ = try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            try await store.expireRunForGlobalTimeout(workflowRunId: run, error: "global timeout", at: at)
            // A pause that arrives after the stop must not resurrect the run.
            await #expect(throws: (any Error).self) {
                try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                            forms: [form(doc, run: run, execution: "exec-e", token: "tok-e")], at: at)
            }
            #expect(try await runStatus(store, doc, run) == "stopped")
            #expect(try await store.openPauses(workflowRunId: run).isEmpty)
        }
    }

    @Test func submittingTwiceAnswersOnceAndTheFirstPayloadStays() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            let first = try await store.submitHumanInputForm(token: "tok-a", inputs: #"{"approved":true}"#, action: "approve",
                                                             userId: "u-1", )
            guard case .accepted(let accepted) = first else {
                Issue.record("first submission must be accepted, got \(first)")
                return
            }
            #expect(accepted.status == .submitted && accepted.submittedBy == "u-1")
            let second = try await store.submitHumanInputForm(token: "tok-a", inputs: #"{"approved":false}"#, action: "reject",
                                                             userId: "u-2", )
            #expect(second == .alreadySubmitted)
            let stored = try await store.humanInputForm(token: "tok-a")
            #expect(stored?.submittedBy == "u-1" && stored?.submittedInputs == #"{"approved":true}"#)
        }
    }

    @Test func anUnknownTokenIsNotFound() async throws {
        try await withStore { store, _ in
            let missing = try await store.humanInputForm(token: "nope")
            #expect(missing == nil)
            let outcome = try await store.submitHumanInputForm(token: "nope", inputs: "{}", action: "approve", userId: "u-1",
                                                               )
            #expect(outcome == .notFound)
        }
    }

    @Test func aPauseThatCannotBeWrittenFails() async throws {
        try await withStore { store, _ in
            let (doc, _) = try await run(store)
            await #expect(throws: (any Error).self) {
                try await store.createPause(workflowRunId: "no-such-run", docId: doc, snapshot: "{}", forms: [], at: Date())
            }
            #expect(try await store.openPauses(workflowRunId: "no-such-run").isEmpty)
        }
    }

    @Test func anUnknownStatusIsRefusedRatherThanReadAsWaiting() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await pause(store, doc, run, forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            try await store.executeForTest("UPDATE human_input_forms SET status = 'mystery' WHERE token = 'tok-a'")
            await #expect(throws: HumanInputStoreError.unknownStatus("mystery")) {
                _ = try await store.humanInputForm(token: "tok-a")
            }
        }
    }
}
