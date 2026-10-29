import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent retained workspace node configuration")
struct AgentRetainedNodeTests {
    static func data(_ session: JSONValue?) -> JSONObject {
        var value: JSONObject = ["type": "agent", "version": "2", "agent_node_kind": "dify_agent",
            "agent_binding": ["binding_type": "inline_agent", "agent_id": "agent", "current_snapshot_id": "snapshot"]]
        value["agent_session"] = session
        return value
    }
    @Test func simpleSwitchRejectsPathsAndOldArchiveBindings() throws {
        for value in [nil, JSONValue.null, [:], ["enabled": false]] as [JSONValue?] {
            #expect(try AgentNodeData(Self.data(value)).retainSession == false)
        }
        #expect(try AgentNodeData(Self.data(["enabled": true])).retainSession)
        for value in [1, "yes", ["enabled": 1], ["enabled": .null], ["enabled": true, "input": "file"], ["path": "/other"]] as [JSONValue] {
            #expect(throws: NodeDataError.self) { try AgentNodeData(Self.data(value)) }
        }
    }
}

@Suite("Agent retained session receipts")
struct AgentRetainedSessionStatusTests {
    @Test func saveFailureKeepsOnlyAPublicCodeAndValidReceiptsAreBounded() throws {
        let failed = try AgentRetainedSessionStatus.normalize(["saved": false, "error": ["code": "unsafe", "message": "fixture-secret /host/private"]])
        #expect(failed == ["saved": false, "error": "session_save_failed"])
        #expect(try AgentRetainedSessionStatus.normalize(["saved": true, "thread_id": "thread-id", "turns": 2]) == ["saved": true, "thread_id": "thread-id", "turns": 2])
        for value in [nil, [:], ["saved": true], ["saved": true, "thread_id": "/host/path", "turns": 2], ["saved": true, "thread_id": "thread-id", "turns": -1]] as [JSONValue?] {
            #expect(throws: NodeError.self) { try AgentRetainedSessionStatus.normalize(value) }
        }
    }
}

@Suite("Agent retained workspace lifecycle", .enabled(if: testDbHost != nil))
struct AgentRetainedWorkspaceTests {
    @Test func pausedAndRunningKeepFilesAndTerminalCleanupIsDurableAndIdempotent() async throws {
        try await withServer { api, store, _ in
            let session = try await AgentExecutionStoreTests.seed(api, store)
            #expect(try await store.pinAgentRetention(session: session, enabled: true))
            #expect(try await store.pinAgentRetention(session: session, enabled: false))
            _ = try await store.client.query("UPDATE agent_node_sessions SET status = 'completed' WHERE execution_id = \(session.executionID)", logger: store.logger)
            for status in ["running", "paused"] {
                _ = try await store.client.query("UPDATE workflow_runs SET status = \(status) WHERE id = \(session.workflowRunID)", logger: store.logger)
                #expect(try await store.terminalRunsWithActiveAgents().isEmpty)
                #expect(try await store.pendingAgentJobs().isEmpty)
                #expect(try await store.retainedAgentRunApp(run: session.workflowRunID) == nil)
            }
            _ = try await AgentExecutionStoreTests.finish(store, session.workflowRunID, status: "succeeded")
            var jobs = try await store.pendingAgentJobs()
            #expect(jobs.map(\.kind) == ["workflow_cleanup"])
            #expect(try await store.retainedAgentRunApp(run: session.workflowRunID) == session.docID)
            let job = try #require(jobs.first)
            try await store.finishAgentJob(id: job.id, succeeded: false, delaySeconds: 0)
            #expect(try await store.pendingAgentJobs().isEmpty) // The existing queue enforces at least one second backoff.
            _ = try await store.client.query("UPDATE agent_runtime_outbox SET next_at = now() - interval '1 second' WHERE id = \(job.id)", logger: store.logger)
            jobs = try await store.pendingAgentJobs()
            #expect(jobs.count == 1 && jobs.first?.attempts == 1)
            try await store.cancelAgentsInTerminalRun(run: session.workflowRunID)
            #expect(try await store.pendingAgentJobs().count == 1)
            try await store.finishAgentJob(id: job.id, succeeded: true)
            #expect(try await store.terminalRunsWithActiveAgents().isEmpty)
            #expect(try await store.pendingAgentJobs().isEmpty)
        }
    }
    @Test func workflowPurgeWaitsForResultAckAndPerRoundCleanup() async throws {
        try await withServer { api, store, _ in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            _ = try await store.pinAgentRetention(session: session, enabled: true)
            session = try await AgentExecutionStoreTests.result(session, store)
            try await store.commitAgentRetry(AgentOutcomeCommit(session: session, status: "retry", usage: #"{"retain_session":true}"#, outputAttempt: 1))
            _ = try await AgentExecutionStoreTests.finish(store, session.workflowRunID, status: "stopped")
            for _ in 0..<3 {
                let pending = try await store.pendingAgentJobs()
                #expect(!pending.contains { $0.kind == "workflow_cleanup" })
                for job in pending { try await store.finishAgentJob(id: job.id, succeeded: true) }
                let remaining = try await store.pendingAgentJobs()
                if remaining.allSatisfy({ $0.kind == "workflow_cleanup" }) { break }
            }
            #expect(try await store.pendingAgentJobs().map(\.kind) == ["workflow_cleanup"])
        }
    }
    @Test func terminalRecoveryFindsCompletedRetainedNodesButNeverPausedRuns() async throws {
        try await withServer { api, store, _ in
            let session = try await AgentExecutionStoreTests.seed(api, store)
            _ = try await store.pinAgentRetention(session: session, enabled: true)
            _ = try await store.client.query("UPDATE agent_node_sessions SET status = 'completed' WHERE execution_id = \(session.executionID)", logger: store.logger)
            _ = try await store.client.query("UPDATE workflow_runs SET status = 'failed', finished_at = now() WHERE id = \(session.workflowRunID)", logger: store.logger)
            #expect(try await store.terminalRunsWithActiveAgents() == [session.workflowRunID])
            try await store.cancelAgentsInTerminalRun(run: session.workflowRunID)
            #expect(try await store.pendingAgentJobs().map(\.kind) == ["workflow_cleanup"])
        }
    }
    @Test func disabledRetentionDoesNotCreateWorkflowCleanupAndExpiredOwnerCannotChangeIt() async throws {
        try await withServer { api, store, _ in
            let session = try await AgentExecutionStoreTests.seed(api, store)
            #expect(try await store.pinAgentRetention(session: session, enabled: false) == false)
            _ = try await store.client.query("UPDATE agent_node_sessions SET status = 'completed', lease_until = now() - interval '1 second' WHERE execution_id = \(session.executionID)", logger: store.logger)
            await #expect(throws: StoreError.self) { try await store.pinAgentRetention(session: session, enabled: true) }
            _ = try await AgentExecutionStoreTests.finish(store, session.workflowRunID, status: "failed")
            #expect(try await store.pendingAgentJobs().isEmpty)
        }
    }
}
