import Foundation
import PostgresNIO

/// UploadFile metadata, separate from document ops. The key is private server state.
public struct StoredUploadFile: Sendable {
    public var id: String
    public var workspaceId: String
    public var key: String
    public var name: String
    public var size: Int64
    public var extensionName: String
    public var mimeType: String
    public var createdBy: String
    public var createdAt: Date
    public var sha256: String
    public var sourceURL: String?
    public var ready: Bool
    public var endUserId: String?

    public init(id: String, workspaceId: String, key: String, name: String, size: Int64, extensionName: String,
                mimeType: String, createdBy: String, createdAt: Date = Date(), sha256: String, sourceURL: String? = nil, ready: Bool = false, endUserId: String? = nil) {
        self.id = id; self.workspaceId = workspaceId; self.key = key; self.name = name; self.size = size
        self.extensionName = extensionName; self.mimeType = mimeType; self.createdBy = createdBy
        self.createdAt = createdAt; self.sha256 = sha256; self.sourceURL = sourceURL; self.ready = ready; self.endUserId = endUserId
    }
}

extension PostgresStore {
    public func insertUploadFile(_ f: StoredUploadFile) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO upload_files (id, workspace_id, storage_key, name, size, extension, mime_type, created_by_role,
                                          created_by, created_at, sha256, source_url, ready, end_user_id)
                VALUES (\(f.id), \(f.workspaceId), \(f.key), \(f.name), \(f.size), \(f.extensionName), \(f.mimeType),
                        \(f.endUserId == nil ? "account" : "end_user"), \(f.createdBy), \(f.createdAt), \(f.sha256), \(f.sourceURL), \(f.ready), \(f.endUserId))
                """, logger: self.logger)
        }
    }

    @discardableResult
    public func markUploadReady(_ id: String, workspace: String) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query("""
                UPDATE upload_files SET ready = true WHERE id = \(id) AND workspace_id = \(workspace) AND NOT ready AND NOT deleting RETURNING id
                """, logger: self.logger) { return true }
            return false
        }
    }

    public func uploadFile(id: String, workspace: String, includePending: Bool = false) async throws -> StoredUploadFile? {
        try await bounded {
            for try await r in try await self.client.query("""
                SELECT id, workspace_id, storage_key, name, size, extension, mime_type, created_by, created_at, sha256, source_url, ready, end_user_id
                FROM upload_files WHERE id = \(id) AND workspace_id = \(workspace) AND (ready OR \(includePending))
                """, logger: self.logger).decode((String, String, String, String, Int64, String, String, String, Date, String, String?, Bool, String?).self) {
                return StoredUploadFile(id: r.0, workspaceId: r.1, key: r.2, name: r.3, size: r.4, extensionName: r.5,
                    mimeType: r.6, createdBy: r.7, createdAt: r.8, sha256: r.9, sourceURL: r.10, ready: r.11, endUserId: r.12)
            }
            return nil
        }
    }

    /// Reserve an unready upload for cleanup before deleting its bytes; publication must lose the race atomically.
    public func claimPendingUploadCleanup(id: String, workspace: String) async throws -> String? {
        try await bounded {
            for try await (key,) in try await self.client.query("""
                UPDATE upload_files SET deleting = true WHERE id = \(id) AND workspace_id = \(workspace) AND NOT ready
                RETURNING storage_key
                """, logger: self.logger).decode((String,).self) { return key }
            return nil
        }
    }

    /// Refuses to remove a committed file. Used only for failed/pending upload compensation.
    @discardableResult
    public func removePendingUpload(id: String, workspace: String) async throws -> String? {
        try await bounded {
            for try await (key,) in try await self.client.query("""
                DELETE FROM upload_files WHERE id = \(id) AND workspace_id = \(workspace) AND NOT ready AND deleting RETURNING storage_key
                """, logger: self.logger).decode((String,).self) { return key }
            return nil
        }
    }

    /// Old unready rows can be reconciled after an upload/process failed. Ready files are never swept.
    public func pendingUploads(workspace: String, before: Date) async throws -> [(id: String, key: String)] {
        try await bounded {
            var result: [(String, String)] = []
            for try await row in try await self.client.query("""
                SELECT id, storage_key FROM upload_files WHERE workspace_id = \(workspace) AND NOT ready AND created_at < \(before)
                ORDER BY created_at LIMIT 1000
                """, logger: self.logger).decode((String, String).self) { result.append(row) }
            return result
        }
    }

}
