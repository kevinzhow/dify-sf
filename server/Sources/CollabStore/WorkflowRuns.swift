import Foundation
import PostgresNIO

/// A stored workflow run (protocol 1.14, Dify's `workflow_runs`). JSON members are the exact text the runtime produced.
public struct StoredWorkflowRun: Sendable, Equatable {
    public var id: String
    public var docId: String
    public var docSeq: Int
    public var workflowId: String
    /// `workflow` or `chat`.
    public var type: String
    /// `debugging` (draft runs) or `app-run`.
    public var triggeredFrom: String
    /// `draft` or a version.
    public var version: String
    public var graph: String
    public var inputs: String
    /// `running`, `succeeded`, `failed`, `stopped`, `partial-succeeded`.
    public var status: String
    public var outputs: String?
    public var error: String?
    public var elapsedTime: Double
    public var totalTokens: Int
    public var totalSteps: Int
    public var exceptionsCount: Int
    public var createdBy: String?
    public var createdAt: Date
    public var finishedAt: Date?
    /// The creator's name and email (read only).
    public var createdByName: String?
    public var createdByEmail: String?

    public init(id: String, docId: String, docSeq: Int, workflowId: String, type: String, triggeredFrom: String, version: String, graph: String,
                inputs: String, status: String, createdBy: String?, createdAt: Date) {
        self.id = id
        self.docId = docId
        self.docSeq = docSeq
        self.workflowId = workflowId
        self.type = type
        self.triggeredFrom = triggeredFrom
        self.version = version
        self.graph = graph
        self.inputs = inputs
        self.status = status
        elapsedTime = 0
        totalTokens = 0
        totalSteps = 0
        exceptionsCount = 0
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

extension PostgresStore {
    public func insertWorkflowRun(_ r: StoredWorkflowRun) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO workflow_runs (id, doc_id, doc_seq, workflow_id, type, triggered_from, version, graph, inputs, status, outputs,
                    error, elapsed_time, total_tokens, total_steps, exceptions_count, created_by, created_at, finished_at)
                VALUES (\(r.id), \(r.docId), \(r.docSeq), \(r.workflowId), \(r.type), \(r.triggeredFrom), \(r.version), \(r.graph), \(r.inputs),
                    \(r.status), \(r.outputs), \(r.error), \(r.elapsedTime), \(r.totalTokens), \(r.totalSteps), \(r.exceptionsCount),
                    \(r.createdBy), \(r.createdAt), \(r.finishedAt))
                """, logger: self.logger)
        }
    }

    /// The end of a run: status, outputs, error and totals.
    public func finishWorkflowRun(id: String, status: String, outputs: String?, error: String?, elapsedTime: Double, totalTokens: Int,
                                  totalSteps: Int, exceptionsCount: Int, finishedAt: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE workflow_runs SET status = \(status), outputs = \(outputs), error = \(error), elapsed_time = \(elapsedTime),
                    total_tokens = \(totalTokens), total_steps = \(totalSteps), exceptions_count = \(exceptionsCount), finished_at = \(finishedAt)
                WHERE id = \(id)
                """, logger: self.logger)
        }
    }

    /// Runs still `running` that started before `startedBefore` (older than any run can last): a server stopped while
    /// they ran. They end as failed.
    public func failStaleWorkflowRuns(error: String, startedBefore: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE workflow_runs SET status = 'failed', error = \(error), finished_at = now()
                WHERE status = 'running' AND created_at < \(startedBefore)
                """, logger: self.logger)
        }
    }

    static let runColumns = """
        r.id, r.doc_id, r.doc_seq, r.workflow_id, r.type, r.triggered_from, r.version, r.graph, r.inputs, r.status, r.outputs, r.error,
        r.elapsed_time, r.total_tokens, r.total_steps, r.exceptions_count, r.created_by, r.created_at, r.finished_at, a.name, a.email
        """

    static func decodeRun(_ row: PostgresRow) throws -> StoredWorkflowRun {
        let r = row.makeRandomAccess()
        var run = StoredWorkflowRun(
            id: try r[0].decode(String.self), docId: try r[1].decode(String.self), docSeq: Int(try r[2].decode(Int64.self)),
            workflowId: try r[3].decode(String.self), type: try r[4].decode(String.self), triggeredFrom: try r[5].decode(String.self),
            version: try r[6].decode(String.self), graph: try r[7].decode(String.self), inputs: try r[8].decode(String.self),
            status: try r[9].decode(String.self), createdBy: try r[16].decode(String?.self), createdAt: try r[17].decode(Date.self))
        run.outputs = try r[10].decode(String?.self)
        run.error = try r[11].decode(String?.self)
        run.elapsedTime = try r[12].decode(Double.self)
        run.totalTokens = Int(try r[13].decode(Int64.self))
        run.totalSteps = Int(try r[14].decode(Int32.self))
        run.exceptionsCount = Int(try r[15].decode(Int32.self))
        run.finishedAt = try r[18].decode(Date?.self)
        run.createdByName = try r[19].decode(String?.self)
        run.createdByEmail = try r[20].decode(String?.self)
        return run
    }

    public func workflowRun(doc: String, id: String) async throws -> StoredWorkflowRun? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.runColumns) FROM workflow_runs r LEFT JOIN accounts a ON a.id = r.created_by
                WHERE r.doc_id = \(doc) AND r.id = \(id)
                """, logger: self.logger)
            for try await row in rows { return try Self.decodeRun(row) }
            return nil
        }
    }

    /// Dify's `get_paginated_workflow_runs`: newest first, `limit + 1` read to tell `has_more`; `lastId` = the cursor
    /// (nil result when it is not a run of this document and source).
    public func workflowRuns(doc: String, triggeredFrom: String, status: String?, limit: Int, lastId: String?) async throws
        -> (runs: [StoredWorkflowRun], hasMore: Bool)? {
        try await bounded {
            var cursor: Date?
            if let lastId {
                let rows = try await self.client.query("""
                    SELECT created_at FROM workflow_runs WHERE doc_id = \(doc) AND triggered_from = \(triggeredFrom) AND id = \(lastId)
                    """, logger: self.logger)
                for try await row in rows { cursor = try row.decode(Date.self) }
                guard cursor != nil else { return nil }
            }
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.runColumns) FROM workflow_runs r LEFT JOIN accounts a ON a.id = r.created_by
                WHERE r.doc_id = \(doc) AND r.triggered_from = \(triggeredFrom)
                  AND (\(status)::text IS NULL OR r.status = \(status))
                  AND (\(cursor)::timestamptz IS NULL OR (r.created_at < \(cursor) AND r.id <> \(lastId)))
                ORDER BY r.created_at DESC, r.id DESC LIMIT \(limit + 1)
                """, logger: self.logger)
            var out: [StoredWorkflowRun] = []
            for try await row in rows { out.append(try Self.decodeRun(row)) }
            let more = out.count > limit
            return (Array(out.prefix(limit)), more)
        }
    }

    /// A node execution as it ends (insert, or replace the row of the same id).
    public func upsertNodeExecution(_ e: StoredNodeExecution) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO workflow_node_executions (id, doc_id, workflow_run_id, triggered_from, doc_seq, run_index, predecessor_node_id,
                    node_id, node_type, title, inputs, process_data, outputs, status, error, elapsed_time, execution_metadata, created_by,
                    created_at, finished_at)
                VALUES (\(e.id), \(e.docId), \(e.workflowRunId), \(e.triggeredFrom), \(e.docSeq), \(e.index), \(e.predecessorNodeId),
                    \(e.nodeId), \(e.nodeType), \(e.title), \(e.inputs), \(e.processData), \(e.outputs), \(e.status), \(e.error),
                    \(e.elapsedTime), \(e.executionMetadata), \(e.createdBy), \(e.createdAt), \(e.finishedAt))
                ON CONFLICT (id) DO UPDATE SET run_index = EXCLUDED.run_index, inputs = EXCLUDED.inputs, process_data = EXCLUDED.process_data,
                    outputs = EXCLUDED.outputs, status = EXCLUDED.status, error = EXCLUDED.error, elapsed_time = EXCLUDED.elapsed_time,
                    execution_metadata = EXCLUDED.execution_metadata, finished_at = EXCLUDED.finished_at
                """, logger: self.logger)
        }
    }

    /// The node executions of a run, oldest first (Dify's `get_executions_by_workflow_run`).
    public func nodeExecutions(doc: String, run: String) async throws -> [StoredNodeExecution] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT e.id, e.doc_id, e.workflow_run_id, e.triggered_from, e.doc_seq, e.run_index, e.predecessor_node_id, e.node_id,
                       e.node_type, e.title, e.inputs, e.process_data, e.outputs, e.status, e.error, e.elapsed_time, e.execution_metadata,
                       e.created_by, e.created_at, e.finished_at, a.name, a.email
                FROM workflow_node_executions e LEFT JOIN accounts a ON a.id = e.created_by
                WHERE e.doc_id = \(doc) AND e.workflow_run_id = \(run)
                ORDER BY e.created_at, e.run_index
                """, logger: self.logger)
            var out: [StoredNodeExecution] = []
            for try await row in rows { out.append(try Self.decodeNodeExecution(row)) }
            return out
        }
    }
}
