import CollabCore
@testable import CollabStore
import Foundation
import Logging
import Testing

// Human-input persistence (protocol 1.16): the pause is the run's, claimed once per generation; a form is answered once;
// and the run wakes when no form of that generation is still waiting. Real Postgres (server/run-db-tests.sh).

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
                      status: HumanInputFormStatus = .waiting, expiration: Int? = nil, now: Date = Date()) -> StoredHumanInputForm {
        StoredHumanInputForm(
            id: "form-\(execution)", workflowRunId: run, executionId: execution, docId: doc, nodeId: node,
            nodeTitle: "Approval", token: token, formContent: #"{"a":"b"}"#, inputs: #"[{"type":"paragraph"}]"#,
            userActions: #"[{"id":"approve"}]"#, renderedContent: "Please approve", defaultValues: #"{"x":"1"}"#,
            resolvedDefaultValues: #"{"x":"1"}"#, actions: #"[{"id":"approve"}]"#, displayInUi: true,
            expirationTime: expiration, status: status, createdAt: now)
    }

    private func now() -> Int { Int(Date().timeIntervalSince1970) }

    @Test func pauseAndFormsAreReadBackUnchanged() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            let generation = try await store.createPause(
                workflowRunId: run, docId: doc, nodeId: "human", snapshot: #"{"frames":[],"executionId":"exec-a"}"#,
                totalTokens: 12, totalSteps: 3, elapsedTime: 1.5,
                forms: [form(doc, run: run, execution: "exec-a", token: "tok-a", now: at)], at: at)
            #expect(generation == 1)

            let read = try await store.humanInputForm(token: "tok-a")
            #expect(read?.generation == 1 && read?.status == .waiting)
            #expect(read?.formContent == #"{"a":"b"}"# && read?.defaultValues == #"{"x":"1"}"#)
            let pause = try await store.pause(workflowRunId: run, generation: 1)
            #expect(pause?.snapshot == #"{"frames":[],"executionId":"exec-a"}"#)
            #expect(pause?.totalTokens == 12 && pause?.elapsedTime == 1.5)
            #expect(pause?.resumeRequested == false, "a waiting form has not woken the run")
            #expect(try await store.openPauses(workflowRunId: run).count == 1)
        }
    }

    @Test func theRunWakesOnlyWhenEveryFormOfTheGenerationIsTerminal() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)

            let first = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                             at: at, now: now())
            #expect(first != .notFound)
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == false,
                    "B still waits, so A's answer does not wake the run")

            _ = try await store.submitHumanInputForm(token: "tok-b", inputs: "{}", action: "approve", userId: "u-1",
                                                    at: at, now: now())
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == true,
                    "B's answer wakes the run even though A was the first form")
        }
    }

    @Test func oneGenerationIsClaimedByExactlyOneResumption() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", at: at, now: now())
            _ = try await store.submitHumanInputForm(token: "tok-b", inputs: "{}", action: "approve", userId: "u-1", at: at, now: now())

            // Two nodes' forms answered, two resumptions arriving together: one engine starts, not one per execution.
            async let first = store.claimResume(workflowRunId: run, generation: 1, at: at)
            async let second = store.claimResume(workflowRunId: run, generation: 1, at: at)
            let (a, b) = try await (first, second)
            #expect([a, b].filter { $0 }.count == 1)
            #expect(try await store.claimResume(workflowRunId: run, generation: 1, at: at) == false)
            #expect(try await store.openPauses(workflowRunId: run).isEmpty)
        }
    }

    @Test func aNodeThatPausesAgainKeepsItsWaitingFormAndTheRunGetsANewGeneration() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1", at: at, now: now())
            _ = try await store.submitHumanInputForm(token: "tok-b", inputs: "{}", action: "approve", userId: "u-1", at: at, now: now())
            #expect(try await store.claimResume(workflowRunId: run, generation: 1, at: at))

            // Generation 2: the same node pauses again while another form of it is still waiting (a fresh execution).
            let generation = try await store.createPause(
                workflowRunId: run, docId: doc, snapshot: "{}",
                forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                        form(doc, run: run, execution: "exec-c", token: "tok-c")], at: at)
            #expect(generation == 2, "a later pause of the same run is a new generation, not a duplicate key")
            // A's form is terminal, so its row is left where it was; C is new and waits.
            let a = try await store.humanInputForm(token: "tok-a")
            #expect(a?.status == .submitted && a?.generation == 1)
            #expect(try await store.humanInputForm(token: "tok-c")?.generation == 2)
            #expect(try await store.pause(workflowRunId: run, generation: 2)?.resumeRequested == false)
        }
    }

    @Test func aStillWaitingFormIsAdoptedWithTheSameIdAndToken() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            // A is answered, B still waits, and the run pauses again (a new execution of another node).
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                    at: at, now: now())
            let generation = try await store.createPause(
                workflowRunId: run, docId: doc, snapshot: "{}",
                forms: [form(doc, run: run, execution: "exec-b", token: "tok-b"),
                        form(doc, run: run, execution: "exec-c", token: "tok-c")], at: at)
            #expect(generation == 2)
            let forms = try await store.humanInputForms(workflowRunId: run)
            #expect(forms.count == 3, "no second form for an execution that already has one")
            let b = forms.first { $0.executionId == "exec-b" }
            #expect(b?.id == "form-exec-b" && b?.token == "tok-b", "B keeps the link it was given")
            #expect(b?.generation == 2, "B moved to the pause that is now waiting for it")
            let a = forms.first { $0.executionId == "exec-a" }
            #expect(a?.status == .submitted && a?.generation == 1, "a finished form stays with its own pause")
            #expect(try await store.pause(workflowRunId: run, generation: 2)?.resumeRequested == false)
        }
    }

    @Test func twoPausesWrittenTogetherGetDistinctGenerations() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            // Both writers lock the run row first, so the generation is allocated one after the other instead of two
            // pauses landing on the same key (the duplicate-key failure Winnie reproduced).
            async let first = store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                                forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            async let second = store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                                 forms: [form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            let generations = try await [first, second].sorted()
            #expect(generations == [1, 2])
            #expect(try await store.openPauses(workflowRunId: run).map(\.generation) == [1, 2])
        }
    }

    @Test func submittingTwiceAnswersOnceAndTheFirstPayloadStays() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            let first = try await store.submitHumanInputForm(token: "tok-a", inputs: #"{"approved":true}"#, action: "approve",
                                                             userId: "u-1", at: at, now: now())
            guard case .accepted(let accepted) = first else {
                Issue.record("first submission must be accepted, got \(first)")
                return
            }
            #expect(accepted.status == .submitted && accepted.submittedBy == "u-1")
            let second = try await store.submitHumanInputForm(token: "tok-a", inputs: #"{"approved":false}"#, action: "reject",
                                                             userId: "u-2", at: at, now: now())
            #expect(second == .alreadySubmitted)
            let stored = try await store.humanInputForm(token: "tok-a")
            #expect(stored?.submittedBy == "u-1" && stored?.submittedInputs == #"{"approved":true}"#)
        }
    }

    @Test func anExpiredFormIsRefusedAndRecordedAsExpired() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            let past = Int(at.timeIntervalSince1970) - 60
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a", expiration: past)], at: at)
            #expect(try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                         at: at, now: now()) == .expired)
            #expect(try await store.humanInputForm(token: "tok-a")?.status == .expired)
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == true,
                    "an expired form is terminal, so the run may continue")
        }
    }

    @Test func aNodeTimeoutIsNotAnExpiredForm() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a"),
                                                form(doc, run: run, execution: "exec-b", token: "tok-b")], at: at)
            // The node's own deadline: that node fails (__timeout) while the other keeps waiting.
            #expect(try await store.endHumanInputForm(token: "tok-a", status: .timedOut, at: at))
            #expect(try await store.humanInputForm(token: "tok-a")?.status == .timedOut)
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == false,
                    "B still waits")
            #expect(try await store.endHumanInputForm(token: "tok-b", status: .expired, at: at))
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == true)
            #expect(try await store.humanInputForm(token: "tok-b")?.status == .expired,
                    "the two endings stay distinct")
        }
    }

    @Test func anUnknownTokenIsNotFound() async throws {
        try await withStore { store, _ in
            let missing = try await store.humanInputForm(token: "nope")
            #expect(missing == nil)
            let outcome = try await store.submitHumanInputForm(token: "nope", inputs: "{}", action: "approve", userId: "u-1",
                                                               at: Date(), now: now())
            #expect(outcome == .notFound)
        }
    }

    @Test func aPauseThatCannotBeWrittenFails() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            _ = doc
            // An unknown run: the pause must not be written quietly, the caller has to stop the run and report it.
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
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            // A value the schema does not define: guessing `waiting` would reopen a form that is closed.
            try await store.executeForTest("UPDATE human_input_forms SET status = 'mystery' WHERE token = 'tok-a'")
            await #expect(throws: HumanInputStoreError.unknownStatus("mystery")) {
                _ = try await store.humanInputForm(token: "tok-a")
            }
        }
    }

    @Test func consumingASubmittedFormIsIdempotent() async throws {
        try await withStore { store, _ in
            let (doc, run) = try await run(store)
            let at = Date()
            try await store.createPause(workflowRunId: run, docId: doc, snapshot: "{}",
                                        forms: [form(doc, run: run, execution: "exec-a", token: "tok-a")], at: at)
            _ = try await store.submitHumanInputForm(token: "tok-a", inputs: "{}", action: "approve", userId: "u-1",
                                                    at: at, now: now())
            try await store.consumeHumanInputForm(token: "tok-a", at: at)
            let first = try await store.humanInputForm(token: "tok-a")?.consumedAt
            try await store.consumeHumanInputForm(token: "tok-a", at: at.addingTimeInterval(60))
            #expect(first != nil)
            #expect(try await store.humanInputForm(token: "tok-a")?.consumedAt == first, "the first read wins")
        }
    }
}
