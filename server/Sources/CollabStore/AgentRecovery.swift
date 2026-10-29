import Foundation
import PostgresNIO

extension PostgresStore {
    /// Run lock is acquired before the session lock everywhere, including stop, pause and result persistence.
    /// Uncommitted remote results are cancelled and cleaned, never acknowledged as successful work.
    func terminateAgentSessions(run: String, tx: PostgresConnection) async throws {
        // Per-round cleanup parks files. Only a terminal workflow may purge them.
        for try await _ in try await tx.query("""
            SELECT 1 FROM agent_node_sessions s JOIN workflow_runs r ON r.id = s.workflow_run_id
            WHERE r.id = \(run) AND r.status IN ('succeeded', 'partial-succeeded', 'failed', 'stopped')
              AND s.usage->>'retain_session' = 'true' LIMIT 1
            """, logger: logger) {
            try await agentOutbox(tx: tx, id: "workflow-cleanup:" + run, execution: run,
                workflowRun: run, generation: 1, kind: "workflow_cleanup")
        }
        for try await (execution, generation, remote) in try await tx.query("""
            UPDATE agent_node_sessions SET status = 'cancelled', updated_at = now()
            WHERE workflow_run_id = \(run) AND status IN ('prepared', 'running', 'result_ready', 'paused', 'retry')
            RETURNING execution_id, generation, agent_run_id
            """, logger: logger).decode((String, Int, String?).self) {
            if let remote {
                try await agentOutbox(tx: tx, id: "cancel:" + execution + ":" + String(generation), execution: execution,
                    workflowRun: run, generation: generation, kind: "cancel", agentRun: remote)
            }
            // DELETE execution also cancels an accepted run whose POST response was lost.
            try await agentOutbox(tx: tx, id: "cleanup:" + execution + ":" + String(generation), execution: execution,
                workflowRun: run, generation: generation, kind: "cleanup")
        }
    }

    /// Only a durable pause can be adopted. Active computation is never automatically replayed after owner failure.
    public func adoptPausedAgent(execution: String, owner: String) async throws -> StoredAgentSession {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var workflow: String?
                for try await run in try await tx.query("SELECT workflow_run_id FROM agent_node_sessions WHERE execution_id = \(execution)", logger: self.logger).decode(String.self) { workflow = run }
                guard let workflow else { throw StoreError.notCommitted("Unknown agent execution") }
                try await self.lockRun(workflow, tx)
                var found: StoredAgentSession?
                for try await json in try await tx.query("""
                    SELECT row_to_json(s)::text FROM agent_node_sessions s WHERE execution_id = \(execution) FOR UPDATE
                    """, logger: self.logger).decode(String.self) { found = try StoredAgentSession(json: json) }
                guard var session = found, session.status == "paused" else { throw StoreError.notCommitted("Agent execution has no recoverable pause") }
                // A locally owned live pause needs no generation change. Expired owners must pass the UPDATE fence.
                var renewed = false
                for try await _ in try await tx.query("""
                    UPDATE agent_node_sessions s SET lease_until = now() + interval '20 seconds', updated_at = now()
                    WHERE s.execution_id = \(execution) AND s.owner_id = \(owner) AND s.lease_until > now()
                      AND EXISTS(SELECT 1 FROM workflow_runs r JOIN apps a ON a.doc_id = r.doc_id
                        WHERE r.id = s.workflow_run_id AND r.status IN ('running', 'paused') AND a.deleted_at IS NULL)
                    RETURNING execution_id
                    """, logger: self.logger) { renewed = true }
                if renewed { return session }
                var adopted = false
                for try await next in try await tx.query("""
                    UPDATE agent_node_sessions s SET owner_id = \(owner), generation = generation + 1,
                        lease_until = now() + interval '20 seconds', updated_at = now()
                    WHERE s.execution_id = \(execution) AND s.lease_until <= now() AND s.status = 'paused'
                      AND EXISTS(SELECT 1 FROM workflow_runs r JOIN apps a ON a.doc_id = r.doc_id
                        WHERE r.id = s.workflow_run_id AND r.status IN ('running', 'paused') AND a.deleted_at IS NULL)
                    RETURNING generation
                    """, logger: self.logger).decode(Int.self) { session.generation = next; adopted = true }
                guard adopted else { throw StoreError.notCommitted("Agent pause is still owned by another worker") }
                session.ownerID = owner
                // ACK uses the service's current execution generation even for the preceding operation's result.
                _ = try await tx.query("""
                    UPDATE agent_runtime_outbox SET generation = \(session.generation)
                    WHERE execution_id = \(execution) AND done_at IS NULL AND kind = 'ack'
                    """, logger: self.logger)
                return session
            }
        }
    }

    /// An unanswered pause also needs a new lease owner after restart, so its remote workspace is kept alive.
    public func expiredPausedAgents() async throws -> [StoredAgentSession] {
        try await bounded {
            var found: [StoredAgentSession] = []
            for try await json in try await self.client.query("""
                SELECT row_to_json(s)::text FROM agent_node_sessions s
                JOIN workflow_runs r ON r.id = s.workflow_run_id
                WHERE s.status = 'paused' AND s.lease_until <= now() AND r.status IN ('running', 'paused')
                ORDER BY s.lease_until LIMIT 100
                """, logger: self.logger).decode(String.self) { found.append(try StoredAgentSession(json: json)) }
            return found
        }
    }

    /// Return expired active owners for the maintenance worker. A paused session stays recoverable across restarts.
    public func expiredActiveAgents() async throws -> [StoredAgentSession] {
        try await bounded {
            var found: [StoredAgentSession] = []
            for try await json in try await self.client.query("""
                SELECT row_to_json(s)::text FROM agent_node_sessions s
                WHERE status IN ('prepared', 'running', 'result_ready', 'retry') AND lease_until <= now()
                ORDER BY lease_until LIMIT 100
                """, logger: self.logger).decode(String.self) { found.append(try StoredAgentSession(json: json)) }
            return found
        }
    }

    /// Atomically fence the run and enqueue cleanup after an active owner expires. No model/tool operation is replayed.
    public func failExpiredAgent(_ session: StoredAgentSession) async throws -> Bool {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                try await self.lockRun(session.workflowRunID, tx)
                var expired = false
                for try await _ in try await tx.query("""
                    SELECT 1 FROM agent_node_sessions WHERE execution_id = \(session.executionID)
                      AND generation = \(session.generation) AND owner_id = \(session.ownerID) AND lease_until <= now()
                      AND status IN ('prepared', 'running', 'result_ready', 'retry') FOR UPDATE
                    """, logger: self.logger) { expired = true }
                guard expired else { return false }
                var won = false
                for try await _ in try await tx.query("""
                    UPDATE workflow_runs SET status = 'failed', error = 'Agent worker stopped before committing its result', finished_at = now()
                    WHERE id = \(session.workflowRunID) AND status IN ('running', 'paused') RETURNING id
                    """, logger: self.logger) { won = true }
                try await self.terminateAgentSessions(run: session.workflowRunID, tx: tx)
                if won {
                    _ = try await tx.query("""
                        UPDATE human_input_forms SET status = 'expired', consumed_at = now()
                        WHERE workflow_run_id = \(session.workflowRunID) AND status = 'waiting'
                        """, logger: self.logger)
                    _ = try await tx.query("""
                        UPDATE workflow_pauses SET resumed_at = now(), resume_requested = false
                        WHERE workflow_run_id = \(session.workflowRunID) AND resumed_at IS NULL
                        """, logger: self.logger)
                }
                return won
            }
        }
    }
}

extension PostgresStore {
    /// A fresh process waits for the prior owner's pause lease before consuming any answers.
    public func canResumeAgentQuestions(run: String, owner: String) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query("""
                SELECT 1 FROM agent_node_sessions WHERE workflow_run_id = \(run) AND status = 'paused'
                  AND owner_id <> \(owner) AND lease_until > now() LIMIT 1
                """, logger: self.logger) { return false }
            return true
        }
    }
    public func terminalRunsWithActiveAgents() async throws -> [String] {
        try await bounded {
            var runs: [String] = []
            for try await id in try await self.client.query("""
                SELECT DISTINCT s.workflow_run_id FROM agent_node_sessions s JOIN workflow_runs r ON r.id = s.workflow_run_id
                WHERE r.status IN ('succeeded', 'partial-succeeded', 'failed', 'stopped') AND (
                  s.status IN ('prepared', 'running', 'result_ready', 'paused', 'retry') OR
                  (s.usage->>'retain_session' = 'true' AND NOT EXISTS (
                    SELECT 1 FROM agent_runtime_outbox j WHERE j.id = 'workflow-cleanup:' || r.id))) LIMIT 100
                """, logger: self.logger).decode(String.self) { runs.append(id) }
            return runs
        }
    }
    public func cancelAgentsInTerminalRun(run: String) async throws {
        try await bounded { try await self.client.withTransaction(logger: self.logger) { tx in
            try await self.lockRun(run, tx)
            for try await _ in try await tx.query("""
                SELECT 1 FROM workflow_runs WHERE id = \(run) AND status IN ('succeeded', 'partial-succeeded', 'failed', 'stopped')
                """, logger: self.logger) { try await self.terminateAgentSessions(run: run, tx: tx); return }
        } }
    }
    public func abandonAgentExecution(execution: String, owner: String, generation: Int) async throws {
        try await bounded { try await self.client.withTransaction(logger: self.logger) { tx in
            var workflow: String?
            for try await id in try await tx.query("SELECT workflow_run_id FROM agent_node_sessions WHERE execution_id = \(execution)", logger: self.logger).decode(String.self) { workflow = id }
            guard let workflow else { return }
            try await self.lockRun(workflow, tx)
            var remote: String?
            var active = false
            for try await run in try await tx.query("""
                UPDATE agent_node_sessions SET status = 'failed', updated_at = now()
                WHERE execution_id = \(execution) AND owner_id = \(owner) AND generation = \(generation)
                  AND status IN ('prepared', 'running', 'result_ready', 'retry') RETURNING agent_run_id
                """, logger: self.logger).decode(String?.self) { active = true; remote = run }
            guard active else { return }
            if let remote {
                try await self.agentOutbox(tx: tx, id: "cancel:" + execution + ":" + String(generation), execution: execution,
                    workflowRun: workflow, generation: generation, kind: "cancel", agentRun: remote)
            }
            try await self.agentOutbox(tx: tx, id: "cleanup:" + execution + ":" + String(generation), execution: execution,
                workflowRun: workflow, generation: generation, kind: "cleanup")
        } }
    }
}


extension PostgresStore {
    public func retainedAgentRunApp(run: String) async throws -> String? {
        try await bounded {
            for try await doc in try await self.client.query("""
                SELECT DISTINCT s.doc_id FROM agent_node_sessions s JOIN workflow_runs r ON r.id = s.workflow_run_id
                WHERE s.workflow_run_id = \(run) AND s.usage->>'retain_session' = 'true'
                  AND r.status IN ('succeeded', 'partial-succeeded', 'failed', 'stopped') LIMIT 1
                """, logger: self.logger).decode(String.self) { return doc }
            return nil
        }
    }
}
