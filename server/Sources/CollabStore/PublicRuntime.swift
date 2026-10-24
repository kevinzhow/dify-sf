// Public application identity is separate from console accounts and sessions.
import Foundation
import PostgresNIO

public struct StoredEndUser: Sendable, Equatable {
    public var id: String
    public var appId: String
    public var source: String
    public var namespace: String
    public var externalId: String
    public var createdAt: Date
}

public struct StoredPublicSession: Sendable {
    public var endUser: StoredEndUser
    public var siteCode: String
    public var expiresAt: Date
}

enum PublicRuntimeSchema {
    static let statements = [
        """
        CREATE TABLE IF NOT EXISTS app_end_users (
            id text PRIMARY KEY,
            doc_id text NOT NULL REFERENCES documents(id),
            source text NOT NULL CHECK (source IN ('api', 'web-app')),
            namespace text NOT NULL CHECK (length(namespace) BETWEEN 1 AND 512),
            external_id text NOT NULL CHECK (length(external_id) BETWEEN 1 AND 256),
            created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            UNIQUE (doc_id, source, namespace, external_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS app_public_sessions (
            token_hash text PRIMARY KEY,
            end_user_id text NOT NULL REFERENCES app_end_users(id) ON DELETE CASCADE,
            site_code text NOT NULL,
            expires_at timestamptz NOT NULL,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp()
        )
        """,
        "CREATE INDEX IF NOT EXISTS app_public_sessions_expiry ON app_public_sessions(expires_at)",
        "ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS end_user_id text REFERENCES app_end_users(id)",
        "ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS execution_account_id text REFERENCES accounts(id)",
        "ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS source_api_key_id text REFERENCES app_api_keys(id) ON DELETE SET NULL",
        "ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS created_by_role text NOT NULL DEFAULT 'account'",
        "ALTER TABLE app_chat_conversations ADD COLUMN IF NOT EXISTS end_user_id text REFERENCES app_end_users(id)",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS end_user_id text REFERENCES app_end_users(id)",
        "ALTER TABLE upload_files ADD COLUMN IF NOT EXISTS end_user_id text REFERENCES app_end_users(id)",
        "CREATE INDEX IF NOT EXISTS workflow_runs_end_user ON workflow_runs(doc_id, end_user_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS app_chat_conversations_end_user ON app_chat_conversations(doc_id, end_user_id, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS upload_files_end_user ON upload_files(end_user_id)",
    ]
}

extension PostgresStore {
    public func publicSiteApp(code: String) async throws -> (appId: String, owner: String)? {
        try await bounded {
            for try await value in try await self.client.query("""
                SELECT a.doc_id, a.created_by FROM apps a JOIN app_sites s ON s.doc_id = a.doc_id
                WHERE s.code = \(code) AND a.deleted_at IS NULL AND a.enable_site AND a.created_by IS NOT NULL
                """, logger: self.logger).decode((String, String).self) { return (value.0, value.1) }
            return nil
        }
    }

    public func endUser(appId: String, source: String, namespace: String, externalId: String) async throws -> StoredEndUser {
        let id = UUID().uuidString.lowercased()
        return try await bounded {
            for try await (id, created) in try await self.client.query("""
                INSERT INTO app_end_users(id, doc_id, source, namespace, external_id)
                VALUES (\(id), \(appId), \(source), \(namespace), \(externalId))
                ON CONFLICT (doc_id, source, namespace, external_id) DO UPDATE SET updated_at = clock_timestamp()
                RETURNING id, created_at
                """, logger: self.logger).decode((String, Date).self) {
                return StoredEndUser(id: id, appId: appId, source: source, namespace: namespace, externalId: externalId, createdAt: created)
            }
            throw StoreError.corrupt("end user insert returned nothing")
        }
    }

    public func endUser(id: String) async throws -> StoredEndUser? {
        try await bounded {
            for try await (doc, source, namespace, external, at) in try await self.client.query("""
                SELECT doc_id, source, namespace, external_id, created_at FROM app_end_users WHERE id = \(id)
                """, logger: self.logger).decode((String, String, String, String, Date).self) {
                return StoredEndUser(id: id, appId: doc, source: source, namespace: namespace, externalId: external, createdAt: at)
            }
            return nil
        }
    }

    public func createPublicSession(tokenHash: String, endUser: String, siteCode: String, expiresAt: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO app_public_sessions(token_hash, end_user_id, site_code, expires_at)
                VALUES (\(tokenHash), \(endUser), \(siteCode), \(expiresAt))
                """, logger: self.logger)
        }
    }

    /// Every request checks live site state and the current code: disable/reset/delete revoke old sessions immediately.
    public func publicSession(tokenHash: String, at: Date) async throws -> StoredPublicSession? {
        try await bounded {
            for try await (id, app, source, namespace, external, created, code, expires) in try await self.client.query("""
                SELECT e.id, e.doc_id, e.source, e.namespace, e.external_id, e.created_at, p.site_code, p.expires_at
                FROM app_public_sessions p JOIN app_end_users e ON e.id = p.end_user_id
                JOIN apps a ON a.doc_id = e.doc_id JOIN app_sites s ON s.doc_id = a.doc_id
                WHERE p.token_hash = \(tokenHash) AND p.expires_at > \(at) AND s.code = p.site_code
                  AND a.deleted_at IS NULL AND a.enable_site AND e.source = 'web-app' AND e.namespace = p.site_code
                """, logger: self.logger).decode((String, String, String, String, String, Date, String, Date).self) {
                let user = StoredEndUser(id: id, appId: app, source: source, namespace: namespace, externalId: external, createdAt: created)
                return StoredPublicSession(endUser: user, siteCode: code, expiresAt: expires)
            }
            return nil
        }
    }
}

extension PostgresStore {
    public func touchApiKey(_ id: String) async throws {
        try await bounded { _ = try await self.client.query("UPDATE app_api_keys SET last_used_at = clock_timestamp() WHERE id = \(id)", logger: self.logger) }
    }
    public func publicConversations(app: String, endUser: String, limit: Int = 21,
                                    cursor: StoredChatConversation? = nil, sort: String = "-updated_at") async throws -> [StoredChatConversation] {
        let descending = sort.hasPrefix("-")
        let column = sort.hasSuffix("created_at") ? "created_at" : "updated_at"
        let direction = descending ? "DESC" : "ASC", comparison = descending ? "<" : ">"
        let date = column == "created_at" ? cursor?.createdAt : cursor?.updatedAt
        let id = cursor.flatMap { UUID(uuidString:$0.id) }
        return try await bounded {
            var result: [StoredChatConversation] = []
            for try await row in try await self.client.query("""
                SELECT \(unescaped: Self.chatConversationColumns) FROM app_chat_conversations
                WHERE doc_id = \(app) AND end_user_id = \(endUser)
                  AND (\(id)::uuid IS NULL OR (\(unescaped: column),id) \(unescaped: comparison) (\(date)::timestamptz,\(id)::uuid))
                ORDER BY \(unescaped: column) \(unescaped: direction),id \(unescaped: direction) LIMIT \(min(max(limit,1),101))
                """, logger: self.logger) { result.append(try Self.decodeChatConversation(row)) }
            return result
        }
    }
}
