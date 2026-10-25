import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import PostgresNIO
import Testing
@testable import CollabServer

@Suite("Agent durable execution transactions", .enabled(if: testDbHost != nil))
struct AgentExecutionStoreTests {
    static func seed(_ api: API, _ store: PostgresStore) async throws -> StoredAgentSession {
        let (token, user, app) = try await AgentComposerTests.seed(api, store)
        let saved = try await api.send(.put, AgentComposerTests.path(app), AgentComposerTests.payload().compactJSON(), token: token)
        #expect(saved.status == 200)
        let config = try #require(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID))
        let run = UUID().uuidString.lowercased()
        try await store.insertWorkflowRun(.init(id: run, docId: app, docSeq: 3, workflowId: app, type: "workflow", triggeredFrom: "debugging",
            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: user, createdAt: Date()))
        return try await store.createAgentSession(.init(executionID: UUID().uuidString.lowercased(), workflowRunID: run, docID: app,
            nodeID: AgentComposerTests.nodeID, agentID: config.agentId, configSnapshotID: config.id, ownerID: "worker-a"))
    }
    static func result(_ s: StoredAgentSession, _ store: PostgresStore, sequence: Int = 0) async throws -> StoredAgentSession {
        let operation = "\(s.executionID):0:\(sequence)"
        try await store.startAgentOperation(session: s, operation: operation, digest: "fixture-digest", tokenHash: "hashed-capability")
        var current = try #require(try await store.agentSession(execution: s.executionID))
        try await store.recordAgentRun(session: current, run: "remote-\(sequence)")
        try await store.recordAgentResult(session: current, run: "remote-\(sequence)", event: 1, result: #"{"status":"paused"}"#)
        current = try #require(try await store.agentSession(execution: s.executionID))
        return current
    }
    static func form(_ s: StoredAgentSession, question: String) -> StoredHumanInputForm {
        .init(id: UUID().uuidString.lowercased(), workflowRunId: s.workflowRunID, executionId: s.executionID, docId: s.docID,
              nodeId: s.nodeID, nodeTitle: "Agent", token: UUID().uuidString.lowercased(), formContent: "Question", inputs: "[]", userActions: "[]",
              renderedContent: "Question", actions: "[]", displayInUi: true, createdAt: Date(), questionID: question)
    }
    static func finish(_ store: PostgresStore, _ run: String, status: String) async throws -> Bool {
        try await store.finishWorkflowRun(id: run, status: status, outputs: "{}", error: nil, elapsedTime: 0, totalTokens: 0,
            totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
    }
    @Test func pauseAndAckShareTheExistingTransactionAndNewQuestionsKeepExecutionIdentity() async throws {
        try await withServer { api, store, _ in
            var s = try await Self.result(try await Self.seed(api, store), store)
            let q1 = Self.form(s, question: s.executionID + ":q1")
            var change = AgentOutcomeCommit(session: s, status: "paused", continuation: "{}", questionID: q1.questionID,
                formID: q1.id, resumeSequence: 1)
            // Missing actual form is a failed transaction, not an ACK-worthy pause.
            do {
                _ = try await store.createPause(workflowRunId: s.workflowRunID, docId: s.docID, snapshot: "{}", forms: [], at: Date(), agentOutcomes: [change])
                Issue.record("An absent form committed an agent pause")
            } catch { }
            #expect(try await store.workflowRun(id: s.workflowRunID)?.status == "running")
            #expect(try await store.pendingAgentJobs().isEmpty)
            #expect(try await store.openPauses(workflowRunId: s.workflowRunID).isEmpty)
            _ = try await store.createPause(workflowRunId: s.workflowRunID, docId: s.docID, snapshot: "{}", forms: [q1], at: Date(), agentOutcomes: [change])
            #expect(try await store.agentSession(execution: s.executionID)?.status == "paused")
            let firstJobs = try await store.pendingAgentJobs()
            #expect(firstJobs.count == 1 && firstJobs.first?.kind == "ack")
            // Same execution, next genuine question, without consuming/reusing the previous form ID.
            _ = try await store.client.query("UPDATE workflow_runs SET status = 'running' WHERE id = \(s.workflowRunID)", logger: store.logger)
            _ = try await store.client.query("UPDATE workflow_pauses SET resumed_at = now() WHERE workflow_run_id = \(s.workflowRunID)", logger: store.logger)
            s = try #require(try await store.agentSession(execution: s.executionID))
            s = try await Self.result(s, store, sequence: 1)
            let q2 = Self.form(s, question: s.executionID + ":q2")
            change = AgentOutcomeCommit(session: s, status: "paused", continuation: "{}", questionID: q2.questionID, formID: q2.id, resumeSequence: 2)
            _ = try await store.createPause(workflowRunId: s.workflowRunID, docId: s.docID, snapshot: "{}", forms: [q2], at: Date(), agentOutcomes: [change])
            let forms = try await store.humanInputForms(workflowRunId: s.workflowRunID)
            #expect(forms.count == 2 && forms.allSatisfy { $0.executionId == s.executionID })
            #expect(try await store.humanInputForm(workflowRunId: s.workflowRunID, executionId: s.executionID) == nil)
            #expect(try await store.humanInputForm(workflowRunId: s.workflowRunID, executionId: s.executionID, questionID: q2.questionID)?.id == q2.id)
        }
    }
    @Test func pausedOwnerCanBeAdoptedOnlyAfterExpiryAndAckUsesTheNewGeneration() async throws {
        try await withServer { api, store, _ in
            let s = try await Self.result(try await Self.seed(api, store), store)
            let form = Self.form(s, question: s.executionID + ":q1")
            let change = AgentOutcomeCommit(session: s, status: "paused", continuation: "{}", questionID: form.questionID, formID: form.id)
            _ = try await store.createPause(workflowRunId: s.workflowRunID, docId: s.docID, snapshot: "{}", forms: [form], at: Date(), agentOutcomes: [change])
            do { _ = try await store.adoptPausedAgent(execution: s.executionID, owner: "worker-b"); Issue.record("Live pause was stolen") } catch { }
            _ = try await store.client.query("UPDATE agent_node_sessions SET lease_until = now() - interval '1 second' WHERE execution_id = \(s.executionID)", logger: store.logger)
            let adopted = try await store.adoptPausedAgent(execution: s.executionID, owner: "worker-b")
            #expect(adopted.generation == 2 && adopted.formID == form.id && adopted.continuation == "{}")
            #expect(try await store.renewAgentSession(execution: s.executionID, owner: "worker-a", generation: 1) == false)
            #expect(try await store.pendingAgentJobs().first?.generation == 2)
        }
    }
    @Test func expiredActiveOwnerFailsWithoutReplayAndLateResultsCannotResurrectRun() async throws {
        try await withServer { api, store, _ in
            var s = try await Self.seed(api, store)
            try await store.startAgentOperation(session: s, operation: s.executionID + ":0:0", digest: "digest", tokenHash: "hash")
            s = try #require(try await store.agentSession(execution: s.executionID))
            try await store.recordAgentRun(session: s, run: "remote-run")
            _ = try await store.client.query("UPDATE agent_node_sessions SET lease_until = now() - interval '1 second' WHERE execution_id = \(s.executionID)", logger: store.logger)
            #expect(try await store.expiredActiveAgents().count == 1)
            #expect(try await store.failExpiredAgent(s))
            #expect(try await store.workflowRun(id: s.workflowRunID)?.status == "failed")
            do { try await store.recordAgentResult(session: s, run: "remote-run", event: 1, result: "{}"); Issue.record("A late result was accepted") } catch { }
            #expect(try await Self.finish(store, s.workflowRunID, status: "succeeded") == false)
            let jobs = try await store.pendingAgentJobs()
            #expect(Set(jobs.map(\.kind)) == Set(["cancel", "cleanup"]))
            #expect(try await store.failExpiredAgent(s) == false)
        }
    }
    @Test func cleanupWaitsForCommittedAckAndFailedDeliveryRemainsPending() async throws {
        try await withServer { api, store, _ in
            let s = try await Self.result(try await Self.seed(api, store), store)
            let change = AgentOutcomeCommit(session: s, status: "retry", outputAttempt: 1)
            try await store.commitAgentRetry(change)
            _ = try await Self.finish(store, s.workflowRunID, status: "stopped")
            var jobs = try await store.pendingAgentJobs()
            #expect(jobs.contains { $0.kind == "ack" } && !jobs.contains { $0.kind == "cleanup" })
            let ack = try #require(jobs.first { $0.kind == "ack" })
            try await store.finishAgentJob(id: ack.id, succeeded: false, delaySeconds: 1)
            var attempts = 0
            for try await n in try await store.client.query("SELECT attempts FROM agent_runtime_outbox WHERE id = \(ack.id)", logger: store.logger).decode(Int.self) { attempts = n }
            #expect(attempts == 1)
            #expect(try await store.pendingAgentJobs().allSatisfy { $0.kind != "cleanup" })
            try await store.finishAgentJob(id: ack.id, succeeded: true)
            jobs = try await store.pendingAgentJobs()
            #expect(jobs.contains { $0.kind == "cleanup" })
        }
    }
    @Test func pausedSessionsCountTowardDatabaseAdmissionLimit() async throws {
        try await withServer { api, store, _ in
            let first = try await Self.seed(api, store)
            _ = try await store.client.query("UPDATE agent_node_sessions SET status = 'paused' WHERE execution_id = \(first.executionID)", logger: store.logger)
            var next = first; next.executionID = UUID().uuidString.lowercased()
            do { _ = try await store.createAgentSession(next, maxConcurrent: 1); Issue.record("Paused execution did not count") } catch { }
            #expect(try await store.createAgentSession(first, maxConcurrent: 1).executionID == first.executionID)
            #expect(try await store.agentSession(execution: next.executionID) == nil)
        }
    }
    @Test func nodeResultAndAckRollbackTogetherWhenOwnershipWasLost() async throws {
        try await withServer { api, store, _ in
            let s = try await Self.result(try await Self.seed(api, store), store)
            _ = try await Self.finish(store, s.workflowRunID, status: "stopped")
            let now = Date()
            let node = StoredNodeExecution(id: s.executionID, docId: s.docID, workflowRunId: s.workflowRunID, triggeredFrom: "debugging", docSeq: 3,
                index: 1, predecessorNodeId: nil, nodeId: s.nodeID, nodeType: "agent", title: "Agent", inputs: "{}", processData: "{}", outputs: "{}",
                status: "succeeded", error: nil, elapsedTime: 0, executionMetadata: "{}", createdBy: nil, createdAt: now, finishedAt: now)
            do { try await store.upsertNodeExecution(node, agentOutcome: .init(session: s, status: "completed")); Issue.record("Unowned result committed") } catch { }
            #expect(try await store.nodeExecutions(doc: s.docID, run: s.workflowRunID).isEmpty)
            #expect(try await store.pendingAgentJobs().allSatisfy { $0.kind != "ack" })
        }
    }
}
