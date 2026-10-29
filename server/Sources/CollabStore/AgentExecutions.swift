import Foundation
import PostgresNIO

/// Private runtime state. Neither a browser session nor an SSE connection owns an execution.
public struct StoredAgentSession: Sendable {
    public var executionID: String
    public var workflowRunID: String
    public var docID: String
    public var nodeID: String
    public var agentID: String
    public var configSnapshotID: String
    public var ownerID: String
    public var generation: Int
    public var status: String
    public var outputAttempt: Int
    public var resumeSequence: Int
    public var operationID: String?
    public var agentRunID: String?
    public var resultEventID: Int?
    public var questionID: String?
    public var formID: String?
    public var continuation: String?
    public var preparedResult: String?
    public var usage: String
    public var acceptedOutputs: String?

    public init(executionID: String, workflowRunID: String, docID: String, nodeID: String, agentID: String,
                configSnapshotID: String, ownerID: String, generation: Int = 1) {
        self.executionID = executionID; self.workflowRunID = workflowRunID; self.docID = docID; self.nodeID = nodeID
        self.agentID = agentID; self.configSnapshotID = configSnapshotID; self.ownerID = ownerID; self.generation = generation
        status = "prepared"; outputAttempt = 0; resumeSequence = 0; usage = "{}"
    }

    init(json: String) throws {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw StoreError.notCommitted("Invalid agent session")
        }
        func text(_ key: String) -> String { value[key] as? String ?? "" }
        func nested(_ key: String) throws -> String? {
            guard let object = value[key], !(object is NSNull) else { return nil }
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        self.init(executionID: text("execution_id"), workflowRunID: text("workflow_run_id"), docID: text("doc_id"),
            nodeID: text("node_id"), agentID: text("agent_id"), configSnapshotID: text("config_snapshot_id"),
            ownerID: text("owner_id"), generation: (value["generation"] as? NSNumber)?.intValue ?? 0)
        status = text("status"); outputAttempt = (value["output_attempt"] as? NSNumber)?.intValue ?? 0
        resumeSequence = (value["resume_sequence"] as? NSNumber)?.intValue ?? 0
        operationID = value["operation_id"] as? String; agentRunID = value["agent_run_id"] as? String
        resultEventID = (value["result_event_id"] as? NSNumber)?.intValue
        questionID = value["question_id"] as? String; formID = value["form_id"] as? String
        continuation = try nested("continuation"); preparedResult = try nested("prepared_result")
        usage = try nested("usage") ?? "{}"; acceptedOutputs = try nested("accepted_outputs")
    }
}

public struct AgentOutcomeCommit: Sendable {
    public var executionID: String
    public var generation: Int
    public var operationID: String
    public var ownerID: String
    /// paused, retry, completed or failed. A prepared result is not a committed engine pause.
    public var status: String
    public var continuation: String?
    public var questionID: String?
    public var formID: String?
    public var acceptedOutputs: String?
    public var usage: String
    public var outputAttempt: Int
    public var resumeSequence: Int
    public init(session: StoredAgentSession, status: String, continuation: String? = nil, questionID: String? = nil,
                formID: String? = nil, acceptedOutputs: String? = nil, usage: String = "{}",
                outputAttempt: Int? = nil, resumeSequence: Int? = nil) {
        executionID = session.executionID; generation = session.generation; operationID = session.operationID ?? ""
        ownerID = session.ownerID; self.status = status; self.continuation = continuation; self.questionID = questionID
        self.formID = formID; self.acceptedOutputs = acceptedOutputs; self.usage = usage
        self.outputAttempt = outputAttempt ?? session.outputAttempt; self.resumeSequence = resumeSequence ?? session.resumeSequence
    }
}

public struct AgentRuntimeJob: Sendable {
    public var id: String
    public var executionID: String
    public var workflowRunID: String
    public var generation: Int
    public var kind: String
    public var agentRunID: String?
    public var resultEventID: Int?
    public var attempts: Int
}

extension PostgresStore {
    public func agentSession(execution: String) async throws -> StoredAgentSession? {
        try await bounded {
            for try await json in try await self.client.query("SELECT row_to_json(s)::text FROM agent_node_sessions s WHERE execution_id = \(execution)", logger: self.logger).decode(String.self) {
                return try StoredAgentSession(json: json)
            }
            return nil
        }
    }

    /// The execution's immutable app/node/config identity cannot be replaced by a later graph edit or another worker.
    public func createAgentSession(_ s: StoredAgentSession, maxConcurrent: Int = 2) async throws -> StoredAgentSession {
        try await agentAdmission {
            try await self.client.withTransaction(logger: self.logger) { tx in
                try await self.lockRun(s.workflowRunID, tx)
                // A database-wide admission fence counts executing work; unanswered forms do not consume the running budget.
                _ = try await tx.query("SELECT pg_advisory_xact_lock(743229871)", logger: self.logger)
                for try await json in try await tx.query("SELECT row_to_json(s)::text FROM agent_node_sessions s WHERE execution_id = \(s.executionID) FOR UPDATE", logger: self.logger).decode(String.self) {
                    let found = try StoredAgentSession(json: json)
                    guard found.workflowRunID == s.workflowRunID, found.docID == s.docID, found.nodeID == s.nodeID,
                          found.agentID == s.agentID, found.configSnapshotID == s.configSnapshotID,
                          found.ownerID == s.ownerID, found.generation == s.generation else {
                        throw StoreError.notCommitted("Agent execution ownership changed")
                    }
                    return found
                }
                var count = 0
                for try await n in try await tx.query("""
                    SELECT count(*) FROM agent_node_sessions WHERE status IN ('prepared', 'running', 'result_ready', 'retry')
                    """, logger: self.logger).decode(Int.self) { count = n }
                guard maxConcurrent > 0, count < maxConcurrent else { throw StoreError.agentCapacityFull }
                var inserted = false
                for try await _ in try await tx.query("""
                    INSERT INTO agent_node_sessions(execution_id, workflow_run_id, doc_id, node_id, agent_id, config_snapshot_id,
                        owner_id, generation, lease_until, status)
                    SELECT \(s.executionID), r.id, \(s.docID), \(s.nodeID), \(s.agentID), \(s.configSnapshotID),
                        \(s.ownerID), \(s.generation), now() + interval '20 seconds', 'prepared'
                    FROM workflow_runs r JOIN apps a ON a.doc_id = r.doc_id
                    WHERE r.id = \(s.workflowRunID) AND r.doc_id = \(s.docID) AND r.status = 'running' AND a.deleted_at IS NULL
                    RETURNING execution_id
                    """, logger: self.logger) { inserted = true }
                guard inserted else { throw StoreError.notCommitted("The workflow no longer accepts an agent execution") }
                return s
            }
        }
    }

    public func renewAgentSession(execution: String, owner: String, generation: Int) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query("""
                UPDATE agent_node_sessions s SET lease_until = now() + interval '20 seconds', updated_at = now()
                FROM workflow_runs r, apps a WHERE s.execution_id = \(execution) AND s.owner_id = \(owner)
                  AND s.generation = \(generation) AND s.lease_until > now()
                  AND s.status IN ('prepared', 'running', 'result_ready', 'paused', 'retry')
                  AND r.id = s.workflow_run_id AND r.status IN ('running', 'paused')
                  AND a.doc_id = s.doc_id AND a.deleted_at IS NULL RETURNING s.execution_id
                """, logger: self.logger) { return true }
            return false
        }
    }

    public func ownedAgentSessions(owner: String) async throws -> [StoredAgentSession] {
        try await bounded {
            var result: [StoredAgentSession] = []
            for try await json in try await self.client.query("""
                SELECT row_to_json(s)::text FROM agent_node_sessions s WHERE owner_id = \(owner)
                  AND status IN ('prepared', 'running', 'result_ready', 'paused', 'retry') ORDER BY updated_at LIMIT 1000
                """, logger: self.logger).decode(String.self) { result.append(try StoredAgentSession(json: json)) }
            return result
        }
    }

    public func startAgentOperation(session: StoredAgentSession, operation: String, digest: String, tokenHash: String, startedData: String? = nil, maxConcurrent: Int = 2) async throws {
        try await agentAdmission {
            try await self.client.withTransaction(logger: self.logger) { tx in
                try await self.lockRun(session.workflowRunID, tx)
                _ = try await tx.query("SELECT pg_advisory_xact_lock(743229871)", logger: self.logger)
                var executing = 0
                for try await count in try await tx.query("""
                    SELECT count(*) FROM agent_node_sessions WHERE execution_id <> \(session.executionID)
                      AND status IN ('prepared', 'running', 'result_ready', 'retry')
                    """, logger: self.logger).decode(Int.self) { executing = count }
                guard maxConcurrent > 0, executing < maxConcurrent else { throw StoreError.agentCapacityFull }
                var active = false
                for try await _ in try await tx.query("""
                    UPDATE agent_node_sessions SET status = 'running', operation_id = \(operation), agent_run_id = NULL,
                        result_event_id = NULL, prepared_result = NULL, updated_at = now(),
                        usage = CASE WHEN \(startedData)::jsonb IS NULL THEN usage
                            ELSE jsonb_set(usage, '{node_started}', \(startedData)::jsonb) END
                    WHERE execution_id = \(session.executionID) AND owner_id = \(session.ownerID)
                      AND generation = \(session.generation) AND lease_until > now() AND status IN ('prepared', 'paused', 'retry')
                      AND EXISTS(SELECT 1 FROM workflow_runs WHERE id = \(session.workflowRunID) AND status = 'running')
                    RETURNING execution_id
                    """, logger: self.logger) { active = true }
                guard active else { throw StoreError.notCommitted("Agent operation ownership changed") }
                _ = try await tx.query("""
                    INSERT INTO agent_operations(id, execution_id, generation, output_attempt, resume_sequence, request_digest, token_hash, status)
                    VALUES (\(operation), \(session.executionID), \(session.generation), \(session.outputAttempt), \(session.resumeSequence),
                        \(digest), \(tokenHash), 'running')
                    """, logger: self.logger)
            }
        }
    }

    public func recordAgentRun(session: StoredAgentSession, run: String) async throws {
        try await bounded {
            for try await _ in try await self.client.query("""
                UPDATE agent_node_sessions SET agent_run_id = \(run), updated_at = now()
                WHERE execution_id = \(session.executionID) AND owner_id = \(session.ownerID) AND generation = \(session.generation)
                  AND operation_id = \(session.operationID) AND status = 'running' AND lease_until > now()
                RETURNING execution_id
                """, logger: self.logger) { return }
            throw StoreError.notCommitted("Late agent operation rejected")
        }
    }

    public func recordAgentResult(session: StoredAgentSession, run: String, event: Int, result: String) async throws {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                try await self.lockRun(session.workflowRunID, tx)
                var won = false
                for try await _ in try await tx.query("""
                    UPDATE agent_node_sessions SET status = 'result_ready', agent_run_id = \(run), result_event_id = \(event),
                        prepared_result = \(result)::jsonb, updated_at = now()
                    WHERE execution_id = \(session.executionID) AND owner_id = \(session.ownerID) AND generation = \(session.generation)
                      AND operation_id = \(session.operationID) AND status = 'running' AND lease_until > now()
                      AND EXISTS(SELECT 1 FROM workflow_runs WHERE id = \(session.workflowRunID) AND status = 'running')
                    RETURNING execution_id
                    """, logger: self.logger) { won = true }
                guard won else { throw StoreError.notCommitted("Late agent result rejected") }
                _ = try await tx.query("""
                    UPDATE agent_operations SET status = 'terminal', agent_run_id = \(run), result_event_id = \(event),
                        result_json = \(result)::jsonb, updated_at = now() WHERE id = \(session.operationID)
                      AND execution_id = \(session.executionID) AND generation = \(session.generation) AND status = 'running'
                    """, logger: self.logger)
            }
        }
    }

    /// Called from the existing form/engine-pause transaction or the node-execution transaction. ACK becomes eligible only here.
    func commitAgentOutcome(_ change: AgentOutcomeCommit, tx: PostgresConnection) async throws {
        guard ["paused", "retry", "completed", "failed"].contains(change.status), !change.operationID.isEmpty,
              change.status != "paused" || (change.formID != nil && change.questionID != nil && change.continuation != nil) else {
            throw StoreError.notCommitted("Invalid agent outcome")
        }
        var run: String?
        var agentRun: String?
        var event: Int?
        for try await (workflow, remote, sequence) in try await tx.query("""
            SELECT workflow_run_id, agent_run_id, result_event_id FROM agent_node_sessions
            WHERE execution_id = \(change.executionID) AND owner_id = \(change.ownerID) AND generation = \(change.generation)
              AND operation_id = \(change.operationID) AND status = 'result_ready' AND lease_until > now()
              AND EXISTS(SELECT 1 FROM workflow_runs r WHERE r.id = agent_node_sessions.workflow_run_id AND r.status IN ('running', 'paused'))
            FOR UPDATE
            """, logger: logger).decode((String, String?, Int?).self) { run = workflow; agentRun = remote; event = sequence }
        guard let run, let agentRun, let event else { throw StoreError.notCommitted("Agent result is no longer owned") }
        if change.status == "paused" {
            var formMatches = false
            for try await _ in try await tx.query("""
                SELECT 1 FROM human_input_forms WHERE id = \(change.formID) AND workflow_run_id = \(run)
                  AND execution_id = \(change.executionID) AND question_id = \(change.questionID)
                """, logger: logger) { formMatches = true }
            guard formMatches else { throw StoreError.notCommitted("Agent question is not in the committed pause") }
        }
        _ = try await tx.query("""
            UPDATE agent_node_sessions SET status = \(change.status), continuation = \(change.continuation)::jsonb,
                question_id = \(change.questionID), form_id = \(change.formID), accepted_outputs = \(change.acceptedOutputs)::jsonb,
                usage = \(change.usage)::jsonb, output_attempt = \(change.outputAttempt), resume_sequence = \(change.resumeSequence), updated_at = now()
            WHERE execution_id = \(change.executionID)
            """, logger: logger)
        _ = try await tx.query("UPDATE agent_operations SET status = 'committed', updated_at = now() WHERE id = \(change.operationID)", logger: logger)
        try await agentOutbox(tx: tx, id: "ack:" + change.operationID, execution: change.executionID, workflowRun: run,
            generation: change.generation, kind: "ack", agentRun: agentRun, event: event)
        if change.status == "completed" || change.status == "failed" {
            try await agentOutbox(tx: tx, id: "cleanup:" + change.executionID + ":" + String(change.generation), execution: change.executionID,
                workflowRun: run, generation: change.generation, kind: "cleanup")
        }
    }

    public func commitAgentRetry(_ change: AgentOutcomeCommit) async throws {
        guard change.status == "retry" else { throw StoreError.notCommitted("Invalid agent retry") }
        try await bounded { try await self.client.withTransaction(logger: self.logger) { tx in
            var run: String?
            for try await id in try await tx.query("SELECT workflow_run_id FROM agent_node_sessions WHERE execution_id = \(change.executionID)", logger: self.logger).decode(String.self) { run = id }
            guard let run else { throw StoreError.notCommitted("Unknown agent execution") }
            try await self.lockRun(run, tx)
            try await self.commitAgentOutcome(change, tx: tx)
        } }
    }

    func agentOutbox(tx: PostgresConnection, id: String, execution: String, workflowRun: String, generation: Int,
                     kind: String, agentRun: String? = nil, event: Int? = nil) async throws {
        _ = try await tx.query("""
            INSERT INTO agent_runtime_outbox(id, execution_id, workflow_run_id, generation, kind, agent_run_id, result_event_id)
            VALUES (\(id), \(execution), \(workflowRun), \(generation), \(kind), \(agentRun), \(event)) ON CONFLICT(id) DO NOTHING
            """, logger: logger)
    }

    public func pendingAgentJobs() async throws -> [AgentRuntimeJob] {
        try await bounded {
            var jobs: [AgentRuntimeJob] = []
            for try await (id, execution, workflow, generation, kind, run, event, attempts) in try await self.client.query("""
                SELECT id, execution_id, workflow_run_id, generation, kind, agent_run_id, result_event_id, attempts
                FROM agent_runtime_outbox j WHERE done_at IS NULL AND next_at <= now()
                  AND (kind <> 'cleanup' OR NOT EXISTS(SELECT 1 FROM agent_runtime_outbox a
                    WHERE a.execution_id = j.execution_id AND a.generation = j.generation AND a.kind = 'ack' AND a.done_at IS NULL))
                  AND (kind <> 'workflow_cleanup' OR NOT EXISTS(SELECT 1 FROM agent_runtime_outbox a
                    WHERE a.workflow_run_id = j.workflow_run_id AND a.kind IN ('ack', 'cancel', 'cleanup') AND a.done_at IS NULL))
                ORDER BY created_at, id LIMIT 100
                """, logger: self.logger).decode((String, String, String, Int, String, String?, Int?, Int).self) {
                jobs.append(.init(id: id, executionID: execution, workflowRunID: workflow, generation: generation,
                    kind: kind, agentRunID: run, resultEventID: event, attempts: attempts))
            }
            return jobs
        }
    }

    public func finishAgentJob(id: String, succeeded: Bool, delaySeconds: Int = 5) async throws {
        try await bounded {
            if succeeded {
                _ = try await self.client.query("UPDATE agent_runtime_outbox SET done_at = now() WHERE id = \(id)", logger: self.logger)
            } else {
                _ = try await self.client.query("""
                    UPDATE agent_runtime_outbox SET attempts = attempts + 1,
                        next_at = now() + make_interval(secs => \(Double(max(1, min(300, delaySeconds)))))
                    WHERE id = \(id) AND done_at IS NULL
                    """, logger: self.logger)
            }
        }
    }
}


extension PostgresStore {
    /// PostgresNIO wraps a rolled-back closure error. Preserve only the admission refusal's typed identity;
    /// begin/commit/rollback failures keep their original semantics and must never become a retryable capacity wait.
    private func agentAdmission<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        do { return try await bounded(work) }
        catch let error as PostgresTransactionError {
            if error.beginError == nil, error.commitError == nil, error.rollbackError == nil,
               let cause = error.closureError as? StoreError {
                if case .agentCapacityFull = cause { throw cause }
            }
            throw error
        }
    }
}
