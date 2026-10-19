import Foundation
import PostgresNIO

/// A stored draft variable (protocol 1.14, Dify's `workflow_draft_variables`): one account's latest value of a node
/// output, system variable or conversation variable in one app. `value` is the JSON text of the value (key order kept).
public struct StoredDraftVariable: Sendable, Equatable {
    public var id: String
    public var docId: String
    public var userId: String
    public var nodeId: String
    public var name: String
    public var description: String
    public var valueType: String
    public var value: String
    public var visible: Bool
    public var editable: Bool
    public var nodeExecutionId: String?
    /// The document seq of the run that produced it (nil for values not produced by a run: defaults, edits only).
    public var docSeq: Int?
    public var lastEditedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, docId: String, userId: String, nodeId: String, name: String, description: String = "", valueType: String,
                value: String, visible: Bool, editable: Bool, nodeExecutionId: String?, docSeq: Int?, lastEditedAt: Date? = nil,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.docId = docId
        self.userId = userId
        self.nodeId = nodeId
        self.name = name
        self.description = description
        self.valueType = valueType
        self.value = value
        self.visible = visible
        self.editable = editable
        self.nodeExecutionId = nodeExecutionId
        self.docSeq = docSeq
        self.lastEditedAt = lastEditedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `selector` column: `[node_id, name]`.
    public var selector: [String] { [nodeId, name] }
}

/// Draft variables: beside the document, never ops.
extension PostgresStore {
    static let draftVariableColumns = """
        id, doc_id, user_id, node_id, name, description, value_type, value, visible, editable, node_execution_id, doc_seq,
        last_edited_at, created_at, updated_at
        """

    static func draftVariable(_ row: PostgresRow) throws -> StoredDraftVariable {
        let r = row.makeRandomAccess()
        return StoredDraftVariable(
            id: try r[0].decode(String.self), docId: try r[1].decode(String.self), userId: try r[2].decode(String.self),
            nodeId: try r[3].decode(String.self), name: try r[4].decode(String.self), description: try r[5].decode(String.self),
            valueType: try r[6].decode(String.self), value: try r[7].decode(String.self), visible: try r[8].decode(Bool.self),
            editable: try r[9].decode(Bool.self), nodeExecutionId: try r[10].decode(String?.self),
            docSeq: try r[11].decode(Int64?.self).map(Int.init), lastEditedAt: try r[12].decode(Date?.self),
            createdAt: try r[13].decode(Date.self), updatedAt: try r[14].decode(Date.self))
    }

    /// `_batch_upsert_draft_variable`: insert, or on `(doc, user, node, name)` either overwrite the value (and refresh
    /// `created_at` so it lists first, clearing `last_edited_at`; the id stays) or, with `ignoreExisting`, keep the row.
    public func upsertDraftVariables(_ vars: [StoredDraftVariable], ignoreExisting: Bool = false) async throws {
        guard !vars.isEmpty else { return }
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { conn in
                for v in vars {
                    if ignoreExisting {
                        _ = try await conn.query("""
                            INSERT INTO workflow_draft_variables (\(unescaped: Self.draftVariableColumns))
                            VALUES (\(v.id), \(v.docId), \(v.userId), \(v.nodeId), \(v.name), \(v.description), \(v.valueType), \(v.value),
                                \(v.visible), \(v.editable), \(v.nodeExecutionId), \(v.docSeq.map(Int64.init)), \(v.lastEditedAt), \(v.createdAt),
                                \(v.updatedAt))
                            ON CONFLICT (doc_id, user_id, node_id, name) DO NOTHING
                            """, logger: self.logger)
                    } else {
                        _ = try await conn.query("""
                            INSERT INTO workflow_draft_variables (\(unescaped: Self.draftVariableColumns))
                            VALUES (\(v.id), \(v.docId), \(v.userId), \(v.nodeId), \(v.name), \(v.description), \(v.valueType), \(v.value),
                                \(v.visible), \(v.editable), \(v.nodeExecutionId), \(v.docSeq.map(Int64.init)), \(v.lastEditedAt), \(v.createdAt),
                                \(v.updatedAt))
                            ON CONFLICT (doc_id, user_id, node_id, name) DO UPDATE SET
                                created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at, last_edited_at = EXCLUDED.last_edited_at,
                                description = EXCLUDED.description, value_type = EXCLUDED.value_type, value = EXCLUDED.value,
                                visible = EXCLUDED.visible, editable = EXCLUDED.editable, node_execution_id = EXCLUDED.node_execution_id,
                                doc_seq = EXCLUDED.doc_seq
                            """, logger: self.logger)
                    }
                }
            }
        }
    }

    public func draftVariable(id: String) async throws -> StoredDraftVariable? {
        try await bounded {
            let rows = try await self.client.query(
                "SELECT \(unescaped: Self.draftVariableColumns) FROM workflow_draft_variables WHERE id = \(id)", logger: self.logger)
            for try await row in rows { return try Self.draftVariable(row) }
            return nil
        }
    }

    /// A page of one account's draft variables of an app, newest first, and (first page only) their count.
    public func draftVariablesPage(doc: String, user: String, page: Int, limit: Int) async throws -> ([StoredDraftVariable], Int?) {
        try await bounded {
            var total: Int?
            if page == 1 {
                let rows = try await self.client.query(
                    "SELECT count(*) FROM workflow_draft_variables WHERE doc_id = \(doc) AND user_id = \(user)", logger: self.logger)
                for try await row in rows { total = Int(try row.decode(Int64.self)) }
            }
            let offset = (page - 1) * limit
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.draftVariableColumns) FROM workflow_draft_variables WHERE doc_id = \(doc) AND user_id = \(user)
                ORDER BY created_at DESC, id DESC LIMIT \(limit) OFFSET \(offset)
                """, logger: self.logger)
            var out: [StoredDraftVariable] = []
            for try await row in rows { out.append(try Self.draftVariable(row)) }
            return (out, total)
        }
    }

    /// One node's (or `sys` / `conversation`) draft variables of an account, newest first.
    public func draftVariables(doc: String, user: String, node: String) async throws -> [StoredDraftVariable] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.draftVariableColumns) FROM workflow_draft_variables
                WHERE doc_id = \(doc) AND user_id = \(user) AND node_id = \(node) ORDER BY created_at DESC, id DESC
                """, logger: self.logger)
            var out: [StoredDraftVariable] = []
            for try await row in rows { out.append(try Self.draftVariable(row)) }
            return out
        }
    }

    /// `get_draft_variables_by_selectors`: the variables at `[node, name]` of these selectors (longer selectors use their
    /// first two parts).
    public func draftVariables(doc: String, user: String, selectors: [[String]]) async throws -> [StoredDraftVariable] {
        let pairs = selectors.filter { $0.count >= 2 }
        guard !pairs.isEmpty else { return [] }
        let nodes = pairs.map { $0[0] }, names = pairs.map { $0[1] }
        return try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.draftVariableColumns) FROM workflow_draft_variables
                WHERE doc_id = \(doc) AND user_id = \(user)
                  AND (node_id, name) IN (SELECT * FROM unnest(\(nodes)::text[], \(names)::text[]))
                """, logger: self.logger)
            var out: [StoredDraftVariable] = []
            for try await row in rows { out.append(try Self.draftVariable(row)) }
            return out
        }
    }

    /// `update_variable` (name and/or value; an edit stamps `last_edited_at`) and the reset (value, `last_edited_at`
    /// cleared). Returns the row after the change, nil if it is gone.
    public func updateDraftVariable(id: String, name: String?, valueType: String?, value: String?, edited: Bool,
                                    now: Date = Date()) async throws -> StoredDraftVariable? {
        try await bounded {
            let rows = try await self.client.query("""
                UPDATE workflow_draft_variables SET
                    name = COALESCE(\(name), name), value_type = COALESCE(\(valueType), value_type), value = COALESCE(\(value), value),
                    last_edited_at = CASE WHEN \(edited) THEN \(now) ELSE NULL END, updated_at = \(now)
                WHERE id = \(id) RETURNING \(unescaped: Self.draftVariableColumns)
                """, logger: self.logger)
            for try await row in rows { return try Self.draftVariable(row) }
            return nil
        }
    }

    public func deleteDraftVariable(id: String) async throws {
        try await bounded {
            _ = try await self.client.query("DELETE FROM workflow_draft_variables WHERE id = \(id)", logger: self.logger)
        }
    }

    /// Deletes an account's draft variables of an app, all of them or one node's.
    public func deleteDraftVariables(doc: String, user: String, node: String? = nil) async throws {
        try await bounded {
            if let node {
                _ = try await self.client.query(
                    "DELETE FROM workflow_draft_variables WHERE doc_id = \(doc) AND user_id = \(user) AND node_id = \(node)", logger: self.logger)
            } else {
                _ = try await self.client.query(
                    "DELETE FROM workflow_draft_variables WHERE doc_id = \(doc) AND user_id = \(user)", logger: self.logger)
            }
        }
    }

    /// A node execution's stored outputs (the reset of a node or system variable reads them).
    public func nodeExecutionOutputs(id: String) async throws -> (nodeType: String, outputs: String?)? {
        try await bounded {
            let rows = try await self.client.query("SELECT node_type, outputs FROM workflow_node_executions WHERE id = \(id)", logger: self.logger)
            for try await row in rows {
                let r = row.makeRandomAccess()
                return (try r[0].decode(String.self), try r[1].decode(String?.self))
            }
            return nil
        }
    }
}
