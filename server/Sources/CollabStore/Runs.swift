import Foundation
import PostgresNIO

/// A stored node execution (protocol 1.13, Dify's `workflow_node_executions`). JSON members are the exact text the
/// runtime produced (key order kept), nil when absent.
public struct StoredNodeExecution: Sendable, Equatable {
    public var id: String
    public var docId: String
    public var workflowRunId: String?
    /// `single-step` or `workflow-run` (Dify's `WorkflowNodeExecutionTriggeredFrom`).
    public var triggeredFrom: String
    /// The document seq the run read.
    public var docSeq: Int
    public var index: Int
    public var predecessorNodeId: String?
    public var nodeId: String
    public var nodeType: String
    public var title: String
    public var inputs: String?
    public var processData: String?
    public var outputs: String?
    public var status: String
    public var error: String?
    public var elapsedTime: Double
    public var executionMetadata: String?
    public var createdBy: String?
    public var createdAt: Date
    public var finishedAt: Date?
    /// The creator's name and email (read only).
    public var createdByName: String?
    public var createdByEmail: String?

    public init(id: String, docId: String, workflowRunId: String?, triggeredFrom: String, docSeq: Int, index: Int,
                predecessorNodeId: String?, nodeId: String, nodeType: String, title: String, inputs: String?, processData: String?,
                outputs: String?, status: String, error: String?, elapsedTime: Double, executionMetadata: String?, createdBy: String?,
                createdAt: Date, finishedAt: Date?) {
        self.id = id
        self.docId = docId
        self.workflowRunId = workflowRunId
        self.triggeredFrom = triggeredFrom
        self.docSeq = docSeq
        self.index = index
        self.predecessorNodeId = predecessorNodeId
        self.nodeId = nodeId
        self.nodeType = nodeType
        self.title = title
        self.inputs = inputs
        self.processData = processData
        self.outputs = outputs
        self.status = status
        self.error = error
        self.elapsedTime = elapsedTime
        self.executionMetadata = executionMetadata
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

/// Run records (protocol 1.13): beside the document, never ops.
extension PostgresStore {
    public func insertNodeExecution(_ e: StoredNodeExecution) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO workflow_node_executions (id, doc_id, workflow_run_id, triggered_from, doc_seq, run_index, predecessor_node_id,
                    node_id, node_type, title, inputs, process_data, outputs, status, error, elapsed_time, execution_metadata, created_by,
                    created_at, finished_at)
                VALUES (\(e.id), \(e.docId), \(e.workflowRunId), \(e.triggeredFrom), \(e.docSeq), \(e.index), \(e.predecessorNodeId),
                    \(e.nodeId), \(e.nodeType), \(e.title), \(e.inputs), \(e.processData), \(e.outputs), \(e.status), \(e.error),
                    \(e.elapsedTime), \(e.executionMetadata), \(e.createdBy), \(e.createdAt), \(e.finishedAt))
                """, logger: self.logger)
        }
    }

    /// Dify's `get_node_last_run`: the newest execution of `nodeId` in the app (single-step or within a run).
    public func lastNodeExecution(doc: String, nodeId: String) async throws -> StoredNodeExecution? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT e.id, e.doc_id, e.workflow_run_id, e.triggered_from, e.doc_seq, e.run_index, e.predecessor_node_id, e.node_id,
                       e.node_type, e.title, e.inputs, e.process_data, e.outputs, e.status, e.error, e.elapsed_time, e.execution_metadata,
                       e.created_by, e.created_at, e.finished_at, a.name, a.email
                FROM workflow_node_executions e LEFT JOIN accounts a ON a.id = e.created_by
                WHERE e.doc_id = \(doc) AND e.node_id = \(nodeId)
                ORDER BY e.created_at DESC, e.id DESC LIMIT 1
                """, logger: self.logger)
            for try await row in rows { return try Self.decodeNodeExecution(row) }
            return nil
        }
    }

    static func decodeNodeExecution(_ row: PostgresRow) throws -> StoredNodeExecution {
        let r = row.makeRandomAccess()
        var e = StoredNodeExecution(
            id: try r[0].decode(String.self), docId: try r[1].decode(String.self), workflowRunId: try r[2].decode(String?.self),
            triggeredFrom: try r[3].decode(String.self), docSeq: Int(try r[4].decode(Int64.self)), index: Int(try r[5].decode(Int32.self)),
            predecessorNodeId: try r[6].decode(String?.self), nodeId: try r[7].decode(String.self), nodeType: try r[8].decode(String.self),
            title: try r[9].decode(String.self), inputs: try r[10].decode(String?.self), processData: try r[11].decode(String?.self),
            outputs: try r[12].decode(String?.self), status: try r[13].decode(String.self), error: try r[14].decode(String?.self),
            elapsedTime: try r[15].decode(Double.self), executionMetadata: try r[16].decode(String?.self),
            createdBy: try r[17].decode(String?.self), createdAt: try r[18].decode(Date.self), finishedAt: try r[19].decode(Date?.self))
        e.createdByName = try r[20].decode(String?.self)
        e.createdByEmail = try r[21].decode(String?.self)
        return e
    }
}
