// Dify 1.17.1 conversation/message records and parent-message threads. Debug conversations are private to their
// creating account; workflow execution, files and collaboration documents keep their existing stores.
import Foundation
import PostgresNIO

public struct StoredChatConversation: Sendable, Equatable {
    public var id: String
    public var docId: String
    public var accountId: String
    public var endUserId: String?
    public var inputs: String
    public var variables: String
    public var activeRunId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String, docId: String, accountId: String, inputs: String, variables: String, at: Date) {
        self.id = id; self.docId = docId; self.accountId = accountId; self.inputs = inputs; self.variables = variables
        self.activeRunId = nil; self.createdAt = at; self.updatedAt = at
    }
}

public struct StoredChatMessage: Sendable, Equatable {
    public var id: String
    public var docId: String
    public var conversationId: String
    public var accountId: String
    public var endUserId: String?
    public var parentMessageId: String?
    public var workflowRunId: String
    public var query: String
    public var inputs: String
    public var files: String
    public var answer = ""
    public var reasoning = "{}"
    public var outputFiles = "[]"
    public var metadata = "{}"
    public var status = "normal"
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String, docId: String, conversationId: String, accountId: String, parentMessageId: String?, workflowRunId: String,
                query: String, inputs: String, files: String, at: Date) {
        self.id = id; self.docId = docId; self.conversationId = conversationId; self.accountId = accountId
        self.parentMessageId = parentMessageId; self.workflowRunId = workflowRunId; self.query = query
        self.inputs = inputs; self.files = files; self.createdAt = at; self.updatedAt = at
    }
}

public enum ChatStoreError: Error, Sendable { case notFound, busy, invalidParent, leaseLost }

/// Additive, repeatable migrations. app_messages was the console's minimal message index: extend it instead of creating
/// a second message identity that would break existing feedback and annotation references.
enum ChatSchema {
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS app_chat_conversations (
            id uuid PRIMARY KEY,
            doc_id text NOT NULL REFERENCES documents(id),
            account_id text NOT NULL REFERENCES accounts(id),
            inputs text NOT NULL DEFAULT '{}',
            variables text NOT NULL DEFAULT '{}',
            active_run_id text,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
        )
        """,
        "ALTER TABLE app_chat_conversations ADD COLUMN IF NOT EXISTS lease_id text",
        "ALTER TABLE app_chat_conversations ADD COLUMN IF NOT EXISTS lease_until timestamptz",
        "CREATE INDEX IF NOT EXISTS app_chat_conversations_owner ON app_chat_conversations (doc_id, account_id, updated_at DESC)",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS account_id text REFERENCES accounts(id)",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS parent_message_id uuid",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS workflow_run_id text REFERENCES workflow_runs(id)",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS query text NOT NULL DEFAULT ''",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS inputs text NOT NULL DEFAULT '{}'",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS files text NOT NULL DEFAULT '[]'",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS answer text NOT NULL DEFAULT ''",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS reasoning text NOT NULL DEFAULT '{}'",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS output_files text NOT NULL DEFAULT '[]'",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS metadata text NOT NULL DEFAULT '{}'",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'normal'",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS error text",
        "ALTER TABLE app_messages ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT clock_timestamp()",
        "CREATE UNIQUE INDEX IF NOT EXISTS app_chat_messages_run ON app_messages (workflow_run_id) WHERE workflow_run_id IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS app_chat_messages_parent ON app_messages (conversation_id, parent_message_id)",
    ]
}

extension PostgresStore {
    static let chatConversationColumns = "id, doc_id, account_id, inputs, variables, active_run_id, created_at, updated_at, end_user_id"
    static let chatMessageColumns = "id, doc_id, conversation_id, account_id, parent_message_id, workflow_run_id, query, inputs, files, answer, reasoning, output_files, metadata, status, error, created_at, updated_at, end_user_id"
    static func decodeChatConversation(_ row: PostgresRow) throws -> StoredChatConversation {
        let r = row.makeRandomAccess()
        var c = StoredChatConversation(id: try r[0].decode(UUID.self).uuidString.lowercased(), docId: try r[1].decode(String.self),
            accountId: try r[2].decode(String.self), inputs: try r[3].decode(String.self), variables: try r[4].decode(String.self), at: try r[6].decode(Date.self))
        c.activeRunId = try r[5].decode(String?.self); c.updatedAt = try r[7].decode(Date.self)
        c.endUserId = try r[8].decode(String?.self)
        return c
    }
    static func decodeChatMessage(_ row: PostgresRow) throws -> StoredChatMessage {
        let r = row.makeRandomAccess()
        var m = StoredChatMessage(id: try r[0].decode(UUID.self).uuidString.lowercased(), docId: try r[1].decode(String.self),
            conversationId: try r[2].decode(UUID.self).uuidString.lowercased(), accountId: try r[3].decode(String.self),
            parentMessageId: try r[4].decode(UUID?.self)?.uuidString.lowercased(), workflowRunId: try r[5].decode(String.self),
            query: try r[6].decode(String.self), inputs: try r[7].decode(String.self), files: try r[8].decode(String.self), at: try r[15].decode(Date.self))
        m.answer = try r[9].decode(String.self); m.reasoning = try r[10].decode(String.self); m.outputFiles = try r[11].decode(String.self)
        m.metadata = try r[12].decode(String.self); m.status = try r[13].decode(String.self); m.error = try r[14].decode(String?.self)
        m.updatedAt = try r[16].decode(Date.self)
        m.endUserId = try r[17].decode(String?.self)
        return m
    }
    public func chatConversation(doc: String, id: String, account: String, endUser: String? = nil) async throws -> StoredChatConversation? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try await bounded {
            for try await row in try await self.client.query("""
                SELECT \(unescaped: Self.chatConversationColumns) FROM app_chat_conversations
                WHERE id = \(uuid) AND doc_id = \(doc) AND account_id = \(account) AND end_user_id IS NOT DISTINCT FROM \(endUser)::text
                """, logger: self.logger) { return try Self.decodeChatConversation(row) }
            return nil
        }
    }
    public func chatMessage(id: String) async throws -> StoredChatMessage? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try await bounded {
            for try await row in try await self.client.query("""
                SELECT \(unescaped: Self.chatMessageColumns) FROM app_messages WHERE id = \(uuid)
                """, logger: self.logger) { return try Self.decodeChatMessage(row) }
            return nil
        }
    }
    public func chatMessage(runId: String) async throws -> StoredChatMessage? {
        try await bounded {
            for try await row in try await self.client.query("""
                SELECT \(unescaped: Self.chatMessageColumns) FROM app_messages WHERE workflow_run_id = \(runId)
                """, logger: self.logger) { return try Self.decodeChatMessage(row) }
            return nil
        }
    }
    public func chatMessages(doc: String, conversation: String, account: String, limit: Int = 500, endUser: String? = nil, before: StoredChatMessage? = nil) async throws -> [StoredChatMessage] {
        guard let uuid = UUID(uuidString: conversation) else { throw ChatStoreError.notFound }
        let beforeId = before.flatMap { UUID(uuidString:$0.id) }, beforeDate = before?.createdAt
        return try await bounded {
            var out: [StoredChatMessage] = []
            for try await row in try await self.client.query("""
                SELECT \(unescaped: Self.chatMessageColumns) FROM app_messages
                WHERE doc_id = \(doc) AND conversation_id = \(uuid) AND account_id = \(account) AND end_user_id IS NOT DISTINCT FROM \(endUser)::text
                AND (\(beforeId)::uuid IS NULL OR (created_at,id) < (\(beforeDate)::timestamptz,\(beforeId)::uuid))
                ORDER BY created_at DESC, id DESC LIMIT \(min(max(limit, 1), 500))
                """, logger: self.logger) { out.append(try Self.decodeChatMessage(row)) }
            return out
        }
    }
}

extension PostgresStore {
    /// The row lock serializes sends across independent server processes. The workflow, message and ownership either
    /// all commit or none do; a rejected send cannot leave an orphan run or overwrite another turn's variables.
    public func beginChatTurn(conversation proposed: StoredChatConversation, message m: StoredChatMessage,
                              run: StoredWorkflowRun, lease: String, create: Bool) async throws -> StoredChatConversation {
        guard let cid = UUID(uuidString: proposed.id), let mid = UUID(uuidString: m.id) else { throw ChatStoreError.notFound }
        return try await bounded {
            do {
                return try await self.client.withTransaction(logger: self.logger) { c in
                    if create {
                        _ = try await c.query("""
                            INSERT INTO app_chat_conversations (id, doc_id, account_id, inputs, variables, created_at, updated_at, end_user_id)
                            VALUES (\(cid), \(proposed.docId), \(proposed.accountId), \(proposed.inputs), \(proposed.variables),
                                    \(proposed.createdAt), \(proposed.updatedAt), \(proposed.endUserId)) ON CONFLICT DO NOTHING
                            """, logger: self.logger)
                    }
                    var conversation: StoredChatConversation?
                    for try await row in try await c.query("""
                        SELECT \(unescaped: Self.chatConversationColumns) FROM app_chat_conversations
                        WHERE id = \(cid) AND doc_id = \(m.docId) AND account_id = \(m.accountId) AND end_user_id IS NOT DISTINCT FROM \(m.endUserId)::text FOR UPDATE
                        """, logger: self.logger) { conversation = try Self.decodeChatConversation(row) }
                    guard var conversation else { throw ChatStoreError.notFound }
                    guard conversation.activeRunId == nil else { throw ChatStoreError.busy }
                    let parent = m.parentMessageId.flatMap(UUID.init(uuidString:))
                    if m.parentMessageId != nil && m.parentMessageId != "00000000-0000-0000-0000-000000000000" {
                        guard let parent else { throw ChatStoreError.invalidParent }
                        var exists = false
                        for try await _ in try await c.query("""
                            SELECT 1 FROM app_messages WHERE id = \(parent) AND conversation_id = \(cid)
                                AND doc_id = \(m.docId) AND account_id = \(m.accountId) AND end_user_id IS NOT DISTINCT FROM \(m.endUserId)::text
                            """, logger: self.logger) { exists = true }
                        guard exists else { throw ChatStoreError.invalidParent }
                    }
                    _ = try await c.query(Self.insertWorkflowRunQuery(run), logger: self.logger)
                    _ = try await c.query("""
                        INSERT INTO app_messages (id, doc_id, conversation_id, account_id, parent_message_id, workflow_run_id,
                            query, inputs, files, created_at, updated_at, end_user_id)
                        VALUES (\(mid), \(m.docId), \(cid), \(m.accountId), \(parent), \(m.workflowRunId),
                            \(m.query), \(m.inputs), \(m.files), \(m.createdAt), \(m.updatedAt), \(m.endUserId))
                        """, logger: self.logger)
                    _ = try await c.query("""
                        UPDATE app_chat_conversations SET active_run_id = \(run.id), lease_id = \(lease),
                            lease_until = clock_timestamp() + interval '30 seconds', updated_at = clock_timestamp() WHERE id = \(cid)
                        """, logger: self.logger)
                    conversation.activeRunId = run.id
                    return conversation
                }
            } catch let e as PostgresTransactionError {
                if let inner = e.closureError as? ChatStoreError { throw inner }; throw e
            }
        }
    }

    /// The active run is fenced by a random lease, independent of process identity. A paused turn keeps the conversation
    /// occupied but has no expiry; the existing durable human-input claim is responsible for its resumption.
    public func renewChatLease(runId: String, lease: String, adopt: Bool = false) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query("""
                UPDATE app_chat_conversations SET lease_id = \(lease), lease_until = clock_timestamp() + interval '30 seconds'
                WHERE active_run_id = \(runId) AND (\(adopt) OR (lease_id = \(lease) AND lease_until > clock_timestamp()))
                  AND EXISTS (SELECT 1 FROM workflow_runs WHERE id = \(runId) AND status = 'running') RETURNING id
                """, logger: self.logger) { return true }
            return false
        }
    }

    public func saveChatProgress(runId: String, lease: String, answer: String, reasoning: String, files: String,
                                 metadata: String, variables: String? = nil) async throws -> Bool {
        try await bounded {
            // Taking the conversation lock first shares the ordering of turn creation and finalization.
            try await self.client.withTransaction(logger: self.logger) { c in
                var owned = false
                for try await _ in try await c.query("""
                    SELECT id FROM app_chat_conversations WHERE active_run_id = \(runId) AND lease_id = \(lease)
                        AND (lease_until IS NULL OR lease_until > clock_timestamp()) FOR UPDATE
                    """, logger: self.logger) { owned = true }
                guard owned else { return false }
                _ = try await c.query("""
                    UPDATE app_messages SET answer = \(answer), reasoning = \(reasoning), output_files = \(files),
                        metadata = \(metadata), updated_at = clock_timestamp() WHERE workflow_run_id = \(runId)
                    """, logger: self.logger)
                if let variables {
                    _ = try await c.query("""
                        UPDATE app_chat_conversations SET variables = (
                            CASE WHEN jsonb_typeof(variables::jsonb) = 'object' THEN variables::jsonb ELSE '{}'::jsonb END
                            || \(variables)::jsonb)::text WHERE active_run_id = \(runId)
                        """, logger: self.logger)
                }
                return true
            }
        }
    }

    /// Called after the durable workflow terminal update (including stop/timeout/preparation failures). Idempotent;
    /// an old worker cannot close or change the message of a later turn.
    public func closeChatTurn(runId: String) async throws {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                _ = try await c.query("SELECT id FROM app_chat_conversations WHERE active_run_id = \(runId) FOR UPDATE", logger: self.logger)
                _ = try await c.query("""
                    UPDATE app_messages m SET status = CASE WHEN r.status IN ('failed', 'stopped') THEN 'error' ELSE 'normal' END,
                        error = r.error, updated_at = clock_timestamp()
                    FROM workflow_runs r WHERE r.id = \(runId) AND m.workflow_run_id = r.id
                        AND r.status IN ('succeeded', 'partial-succeeded', 'failed', 'stopped')
                    """, logger: self.logger)
                _ = try await c.query("""
                    UPDATE app_chat_conversations SET active_run_id = NULL, lease_id = NULL, lease_until = NULL,
                        updated_at = clock_timestamp() WHERE active_run_id = \(runId)
                        AND EXISTS (SELECT 1 FROM workflow_runs WHERE id = \(runId)
                            AND status IN ('succeeded', 'partial-succeeded', 'failed', 'stopped'))
                    """, logger: self.logger)
            }
        }
    }

    /// An interrupted external invocation must never be replayed. Expiry releases the conversation for an explicit
    /// retry and retains its partial answer. SKIP LOCKED allows scans in more than one service process safely.
    public func expireChatLeases() async throws -> [String] {
        try await bounded {
            var candidates: [String] = []
            for try await row in try await self.client.query("""
                SELECT active_run_id FROM app_chat_conversations WHERE active_run_id IS NOT NULL
                    AND lease_until < clock_timestamp()
                """, logger: self.logger) { candidates.append(try row.decode(String.self)) }
            var expired: [String] = []
            for run in candidates {
                let won = try await self.client.withTransaction(logger: self.logger) { c in
                    // All run state transitions take this lock before the conversation row. Recheck after locking:
                    // a heartbeat, pause, stop or another scanner may have won since the candidate read.
                    try await self.lockRun(run, c)
                    var stale = false
                    for try await _ in try await c.query("""
                        SELECT id FROM app_chat_conversations WHERE active_run_id = \(run)
                            AND lease_until < clock_timestamp() FOR UPDATE
                        """, logger: self.logger) { stale = true }
                    guard stale else { return false }
                    var running = false
                    for try await _ in try await c.query("SELECT 1 FROM workflow_runs WHERE id = \(run) AND status = 'running' FOR UPDATE",
                                                        logger: self.logger) { running = true }
                    if running {
                        let error = "The server stopped during this turn. Retry to start a new turn."
                        _ = try await c.query("""
                            UPDATE workflow_runs SET status = 'failed', error = \(error), finished_at = clock_timestamp() WHERE id = \(run)
                            """, logger: self.logger)
                        _ = try await c.query("""
                            UPDATE app_messages SET status = 'error', error = \(error), updated_at = clock_timestamp()
                            WHERE workflow_run_id = \(run)
                            """, logger: self.logger)
                        _ = try await c.query("""
                            UPDATE app_chat_conversations SET active_run_id = NULL, lease_id = NULL, lease_until = NULL
                            WHERE active_run_id = \(run)
                            """, logger: self.logger)
                    } else {
                        // A paused turn never expires; its durable human-input claim governs resumption.
                        _ = try await c.query("UPDATE app_chat_conversations SET lease_until = NULL WHERE active_run_id = \(run)", logger: self.logger)
                    }
                    return running
                }
                if won { expired.append(run) }
            }
            return expired
        }
    }
}

extension PostgresStore {
    /// Stop competes with completion and human-input submission under the same run lock. A late stop cannot turn an
    /// already succeeded/failed turn into a stopped one; the run, form closure, message and conversation release commit
    /// together. The engine's old lease is fenced by clearing active_run_id.
    public func stopChatTurn(runId: String, error: String, at: Date) async throws -> Bool {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(runId, c)
                var active = false
                for try await _ in try await c.query("""
                    SELECT 1 FROM workflow_runs WHERE id = \(runId) AND type = 'chat' AND status IN ('running', 'paused')
                    """, logger: self.logger) { active = true }
                guard active else { return false }
                _ = try await c.query("""
                    UPDATE workflow_runs r SET status = 'stopped', error = \(error), finished_at = \(at),
                        outputs = CASE WHEN status = 'paused' THEN COALESCE(
                            (SELECT outputs FROM workflow_pauses WHERE workflow_run_id = r.id ORDER BY generation DESC LIMIT 1), outputs) ELSE outputs END,
                        elapsed_time = CASE WHEN status = 'paused' THEN COALESCE(
                            (SELECT elapsed_time FROM workflow_pauses WHERE workflow_run_id = r.id ORDER BY generation DESC LIMIT 1), elapsed_time) ELSE elapsed_time END,
                        total_tokens = CASE WHEN status = 'paused' THEN COALESCE(
                            (SELECT total_tokens FROM workflow_pauses WHERE workflow_run_id = r.id ORDER BY generation DESC LIMIT 1), total_tokens) ELSE total_tokens END,
                        total_steps = CASE WHEN status = 'paused' THEN COALESCE(
                            (SELECT total_steps FROM workflow_pauses WHERE workflow_run_id = r.id ORDER BY generation DESC LIMIT 1), total_steps) ELSE total_steps END
                    WHERE id = \(runId)
                    """, logger: self.logger)
                _ = try await c.query("UPDATE human_input_forms SET status = 'expired' WHERE workflow_run_id = \(runId) AND status = 'waiting'", logger: self.logger)
                _ = try await c.query("UPDATE workflow_pauses SET resumed_at = \(at) WHERE workflow_run_id = \(runId) AND resumed_at IS NULL", logger: self.logger)
                _ = try await c.query("UPDATE app_messages SET status = 'error', error = \(error), updated_at = \(at) WHERE workflow_run_id = \(runId)", logger: self.logger)
                _ = try await c.query("""
                    UPDATE app_chat_conversations SET active_run_id = NULL, lease_id = NULL, lease_until = NULL, updated_at = \(at)
                    WHERE active_run_id = \(runId)
                    """, logger: self.logger)
                return true
            }
        }
    }
    public func chatMessageCount(doc: String, conversation: String, account: String, endUser: String? = nil) async throws -> Int {
        guard let id = UUID(uuidString: conversation) else { throw ChatStoreError.notFound }
        return try await bounded {
            for try await row in try await self.client.query("""
                SELECT count(*)::bigint FROM app_messages WHERE doc_id = \(doc) AND conversation_id = \(id) AND account_id = \(account) AND end_user_id IS NOT DISTINCT FROM \(endUser)::text
                """, logger: self.logger) { return Int(try row.decode(Int64.self)) }
            return 0
        }
    }
}
