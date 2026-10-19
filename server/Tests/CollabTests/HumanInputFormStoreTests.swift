import CollabCore
import CollabStore
import Foundation
import Logging
import Testing

// Human-input persistence (protocol 1.16): the pause and its forms are written together, a form is answered at most
// once, and a pause is claimed by exactly one resumption. Runs against a real Postgres (server/run-db-tests.sh).

@Suite("Human input forms (store)", .enabled(if: testDbHost != nil))
struct HumanInputFormStoreTests {
    private func doc(_ store: PostgresStore) async throws -> String {
        let id = "f-\(UUID().uuidString.lowercased().prefix(12))"
        _ = try await store.createDocument(id: id, initial: Document(nodes: [Node(id: "human", type: "llm", config: [:])]))
        return id
    }

    private func form(_ doc: String, run: String = "run-1", execution: String = "exec-1", token: String = "tok-1",
                      status: HumanInputFormStatus = .waiting, expiration: Int? = nil, now: Date = Date()) -> StoredHumanInputForm {
        StoredHumanInputForm(
            id: "form-\(execution)", workflowRunId: run, executionId: execution, docId: doc, nodeId: "human",
            nodeTitle: "Approval", token: token, formContent: #"{"a":"b"}"#, inputs: #"[{"type":"paragraph"}]"#,
            userActions: #"[{"id":"approve"}]"#, renderedContent: "Please approve", defaultValues: #"{"x":"1"}"#,
            resolvedDefaultValues: #"{"x":"1"}"#, actions: #"[{"id":"approve"}]"#, displayInUi: true,
            expirationTime: expiration, status: status, createdAt: now)
    }

    private func pause(_ doc: String, run: String = "run-1", execution: String = "exec-1", now: Date = Date()) -> StoredWorkflowPause {
        StoredWorkflowPause(workflowRunId: run, executionId: execution, docId: doc, nodeId: "human",
                            snapshot: #"{"frames":[],"executionId":"exec-1"}"#, totalTokens: 12, totalSteps: 3,
                            elapsedTime: 1.5, createdAt: now)
    }

    @Test func pauseAndFormAreWrittenTogetherAndReadBack() async throws {
        try await withStore { store, _ in
            let doc = try await doc(store)
            try await store.createPause(pause(doc), forms: [form(doc)])

            let read = try await store.humanInputForm(token: "tok-1")
            #expect(read?.executionId == "exec-1")
            #expect(read?.status == .waiting)
            #expect(read?.formContent == #"{"a":"b"}"#)
            #expect(read?.defaultValues == #"{"x":"1"}"#)
            #expect(read?.displayInUi == true)
            #expect(read?.expirationTime == nil)
            #expect(read?.submittedAt == nil)

            let open = try await store.openPauses(workflowRunId: "run-1")
            #expect(open.count == 1 && open[0].executionId == "exec-1")
            #expect(open[0].snapshot == #"{"frames":[],"executionId":"exec-1"}"#)
            #expect(open[0].totalTokens == 12 && open[0].totalSteps == 3)
            #expect(open[0].elapsedTime == 1.5)
            #expect(try await store.pause(workflowRunId: "run-1", executionId: "exec-1")?.nodeId == "human")
        }
    }

    @Test func aSecondFormForTheSameExecutionIsRefusedAndLeavesNoPause() async throws {
        try await withStore { store, _ in
            let doc = try await doc(store)
            // Same (run, execution) twice: the unique key refuses the second form, so the whole transaction — the pause
            // included — must be rolled back. A run that kept the pause would wait on a form it could not show.
            await #expect(throws: (any Error).self) {
                try await store.createPause(pause(doc), forms: [form(doc), form(doc, token: "tok-2")])
            }
            #expect(try await store.openPauses(workflowRunId: "run-1").isEmpty)
            #expect(try await store.humanInputForm(token: "tok-1") == nil)
        }
    }

    @Test func submittingTwiceAnswersOnceAndTheFirstPayloadStays() async throws {
        try await withStore { store, _ in
            let doc = try await doc(store)
            let now = Date()
            try await store.createPause(pause(doc, now: now), forms: [form(doc, now: now)])

            let first = try await store.submitHumanInputForm(token: "tok-1", inputs: #"{"approved":true}"#, action: "approve",
                                                             userId: "u-1", at: now, now: Int(now.timeIntervalSince1970))
            guard case .accepted(let accepted) = first else {
                Issue.record("first submission must be accepted, got \(first)")
                return
            }
            #expect(accepted.status == .submitted && accepted.submittedBy == "u-1" && accepted.submittedAction == "approve")
            #expect(accepted.submittedInputs == #"{"approved":true}"#)

            let second = try await store.submitHumanInputForm(token: "tok-1", inputs: #"{"approved":false}"#, action: "reject",
                                                             userId: "u-2", at: now, now: Int(now.timeIntervalSince1970))
            #expect(second == .alreadySubmitted)
            let stored = try await store.humanInputForm(token: "tok-1")
            #expect(stored?.submittedBy == "u-1")
            #expect(stored?.submittedInputs == #"{"approved":true}"#)
        }
    }

    @Test func anExpiredFormIsRefusedAndRecordedAsExpired() async throws {
        try await withStore { store, _ in
            let doc = try await doc(store)
            let now = Date()
            let past = Int(now.timeIntervalSince1970) - 60
            try await store.createPause(pause(doc, now: now), forms: [form(doc, expiration: past, now: now)])

            let outcome = try await store.submitHumanInputForm(token: "tok-1", inputs: "{}", action: "approve", userId: "u-1",
                                                              at: now, now: Int(now.timeIntervalSince1970))
            #expect(outcome == .expired)
            #expect(try await store.humanInputForm(token: "tok-1")?.status == .expired)
            // A later submission reads the same answer, not `waiting` again.
            #expect(try await store.submitHumanInputForm(token: "tok-1", inputs: "{}", action: "approve", userId: "u-1",
                                                         at: now, now: Int(now.timeIntervalSince1970)) == .expired)
        }
    }

    @Test func anUnknownTokenIsNotFound() async throws {
        try await withStore { store, _ in
            #expect(try await store.humanInputForm(token: "nope") == nil)
            let outcome = try await store.submitHumanInputForm(token: "nope", inputs: "{}", action: "approve", userId: "u-1",
                                                              at: Date(), now: Int(Date().timeIntervalSince1970))
            #expect(outcome == .notFound)
        }
    }

    @Test func exactlyOneResumptionClaimsAPause() async throws {
        try await withStore { store, _ in
            let doc = try await doc(store)
            let now = Date()
            try await store.createPause(pause(doc, now: now), forms: [form(doc, now: now)])

            // Two submissions arriving together must not start two engines: the conditional update lets one through.
            async let a = store.claimPause(workflowRunId: "run-1", executionId: "exec-1", at: now)
            async let b = store.claimPause(workflowRunId: "run-1", executionId: "exec-1", at: now)
            let (first, second) = try await (a, b)
            #expect([first, second].filter { $0 }.count == 1)
            #expect(try await store.claimPause(workflowRunId: "run-1", executionId: "exec-1", at: now) == false)
            #expect(try await store.openPauses(workflowRunId: "run-1").isEmpty, "a claimed pause is no longer open")
        }
    }

    @Test func consumingASubmittedFormIsIdempotent() async throws {
        try await withStore { store, _ in
            let doc = try await doc(store)
            let now = Date()
            try await store.createPause(pause(doc, now: now), forms: [form(doc, now: now)])
            _ = try await store.submitHumanInputForm(token: "tok-1", inputs: "{}", action: "approve", userId: "u-1",
                                                    at: now, now: Int(now.timeIntervalSince1970))
            try await store.consumeHumanInputForm(token: "tok-1", at: now)
            let first = try await store.humanInputForm(token: "tok-1")?.consumedAt
            try await store.consumeHumanInputForm(token: "tok-1", at: now.addingTimeInterval(60))
            #expect(first != nil)
            #expect(try await store.humanInputForm(token: "tok-1")?.consumedAt == first, "the first read wins")
        }
    }
}
