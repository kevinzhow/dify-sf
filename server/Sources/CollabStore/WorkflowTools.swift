import Foundation
import PostgresNIO

/// A tool references an immutable published version, never a subsequently edited draft.
public struct StoredWorkflowTool: Sendable {
    public var id: String
    public var appId: String
    public var versionId: String
    public var name: String
    public var definition: String
    public var createdBy: String
}
extension PostgresStore {
    public func workflowTools() async throws -> [StoredWorkflowTool] {
        try await bounded {
            var result: [StoredWorkflowTool] = []
            for try await (id, app, version, name, definition, owner) in try await self.client.query("""
                SELECT t.id, t.app_id, t.version_id, t.name, t.definition::text, t.created_by
                FROM workflow_tool_providers t JOIN apps a ON a.doc_id = t.app_id WHERE a.deleted_at IS NULL ORDER BY t.name, t.id
                """, logger: self.logger).decode((String, String, String, String, String, String).self) {
                result.append(StoredWorkflowTool(id: id, appId: app, versionId: version, name: name, definition: definition, createdBy: owner))
            }
            return result
        }
    }
    public func saveWorkflowTool(id existing: String?, appId: String, versionId: String, name: String, definition: String, userId: String, privileged: Bool) async throws -> String {
        let id = existing ?? UUID().uuidString.lowercased()
        return try await modelsTransaction { tx in
            if existing != nil {
                var found = false
                for try await _ in try await tx.query("""
                    SELECT id FROM workflow_tool_providers WHERE id = \(id) AND app_id = \(appId)
                    AND (created_by = \(userId) OR \(privileged)) FOR UPDATE
                    """, logger: self.logger) { found = true }
                guard found else { throw ModelStoreError.notFound("Workflow tool not found") }
                _ = try await tx.query("""
                    UPDATE workflow_tool_providers SET version_id = \(versionId), name = \(name), definition = \(definition)::jsonb
                    WHERE id = \(id)
                    """, logger: self.logger)
            } else {
                _ = try await tx.query("""
                    INSERT INTO workflow_tool_providers(id, app_id, version_id, name, definition, created_by)
                    VALUES (\(id), \(appId), \(versionId), \(name), \(definition)::jsonb, \(userId))
                    """, logger: self.logger)
            }
            return id
        }
    }
    public func deleteWorkflowTool(id: String, userId: String, privileged: Bool) async throws {
        try await modelsTransaction { tx in
            var found = false
            for try await _ in try await tx.query("DELETE FROM workflow_tool_providers WHERE id = \(id) AND (created_by = \(userId) OR \(privileged)) RETURNING id", logger: self.logger) { found = true }
            guard found else { throw ModelStoreError.notFound("Workflow tool not found") }
        }
    }
}
