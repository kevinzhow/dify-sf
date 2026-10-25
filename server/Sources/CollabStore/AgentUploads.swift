import Foundation
import PostgresNIO

public struct StoredAgentUpload: Sendable {
    public var id: String
    public var executionID: String
    public var operationID: String
    public var generation: Int
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var state: String
    public var fileID: String?
}

extension PostgresStore {
    public func reserveAgentUpload(id: String, execution: String, operation: String, generation: Int,
                                   tokenHash: String, filename: String, mime: String, size: Int) async throws {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var found = false
                for try await _ in try await tx.query("""
                    SELECT 1 FROM agent_node_sessions s JOIN workflow_runs r ON r.id = s.workflow_run_id
                    WHERE s.execution_id = \(execution) AND s.operation_id = \(operation) AND s.generation = \(generation)
                      AND s.status = 'running' AND s.lease_until > now() AND r.status = 'running' FOR UPDATE OF s
                    """, logger: self.logger) { found = true }
                guard found, size >= 0, size <= 64 << 20 else { throw StoreError.notCommitted("Agent upload is no longer authorized") }
                for try await (count, bytes) in try await tx.query("""
                    SELECT count(*), coalesce(sum(size), 0)::bigint FROM agent_file_uploads WHERE execution_id = \(execution)
                    """, logger: self.logger).decode((Int, Int64).self) {
                    guard count < 128, bytes + Int64(size) <= 256 << 20 else { throw StoreError.notCommitted("Agent output file budget exhausted") }
                }
                _ = try await tx.query("""
                    INSERT INTO agent_file_uploads(id, execution_id, operation_id, generation, token_hash, filename, mime_type, size, expires_at)
                    VALUES (\(id), \(execution), \(operation), \(generation), \(tokenHash), \(filename), \(mime), \(size), now() + interval '10 minutes')
                    """, logger: self.logger)
            }
        }
    }

    public func claimAgentUpload(id: String, tokenHash: String) async throws -> StoredAgentUpload? {
        try await bounded {
            for try await (id, execution, operation, generation, name, mime, size) in try await self.client.query("""
                UPDATE agent_file_uploads u SET state = 'writing' FROM agent_node_sessions s, workflow_runs r
                WHERE u.id = \(id) AND u.token_hash = \(tokenHash) AND u.state = 'pending' AND u.expires_at > now()
                  AND s.execution_id = u.execution_id AND s.generation = u.generation AND s.operation_id = u.operation_id
                  AND s.status = 'running' AND s.lease_until > now() AND r.id = s.workflow_run_id AND r.status = 'running'
                RETURNING u.id, u.execution_id, u.operation_id, u.generation, u.filename, u.mime_type, u.size
                """, logger: self.logger).decode((String, String, String, Int, String, String, Int).self) {
                return StoredAgentUpload(id: id, executionID: execution, operationID: operation, generation: generation,
                    filename: name, mimeType: mime, size: size, state: "writing", fileID: nil)
            }
            return nil
        }
    }

    public func completeAgentUpload(_ upload: StoredAgentUpload, sha256: String) async throws -> Bool {
        try await bounded {
            // Keep the produced file associated even when stop won the race, so maintenance can inspect it.
            _ = try await self.client.query("""
                UPDATE agent_file_uploads SET file_id = \(upload.id), sha256 = \(sha256)
                WHERE id = \(upload.id) AND state = 'writing'
                """, logger: self.logger)
            for try await _ in try await self.client.query("""
                UPDATE agent_file_uploads u SET state = 'ready' FROM agent_node_sessions s, workflow_runs r
                WHERE u.id = \(upload.id) AND u.state = 'writing' AND u.expires_at > now()
                  AND s.execution_id = u.execution_id AND s.generation = u.generation AND s.operation_id = u.operation_id
                  AND s.status = 'running' AND s.lease_until > now() AND r.id = s.workflow_run_id AND r.status = 'running'
                  AND EXISTS(SELECT 1 FROM upload_files f WHERE f.id = u.file_id AND f.ready AND NOT f.deleting)
                RETURNING u.id
                """, logger: self.logger) { return true }
            return false
        }
    }

    public func agentUpload(id: String, execution: String, generation: Int) async throws -> StoredAgentUpload? {
        try await bounded {
            for try await (id, execution, operation, generation, name, mime, size, state, file) in try await self.client.query("""
                SELECT id, execution_id, operation_id, generation, filename, mime_type, size, state, file_id
                FROM agent_file_uploads WHERE id = \(id) AND execution_id = \(execution) AND generation <= \(generation) AND state = 'ready'
                """, logger: self.logger).decode((String, String, String, Int, String, String, Int, String, String?).self) {
                return StoredAgentUpload(id: id, executionID: execution, operationID: operation, generation: generation,
                    filename: name, mimeType: mime, size: size, state: state, fileID: file)
            }
            return nil
        }
    }
}
