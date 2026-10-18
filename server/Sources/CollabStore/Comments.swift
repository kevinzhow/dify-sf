import CollabCore
import Foundation
import PostgresNIO

/// A canvas comment as stored (Dify's `WorkflowComment` with its replies and mentions).
public struct StoredComment: Sendable, Equatable {
    public var id: String
    public var positionX: Double
    public var positionY: Double
    public var content: String
    public var createdBy: ClientID
    public var createdAt: Date
    public var updatedAt: Date
    public var resolved: Bool
    public var resolvedBy: ClientID?
    public var resolvedAt: Date?
    /// Mentioned client ids, in the order given.
    public var mentions: [ClientID]
    /// Oldest first.
    public var replies: [StoredReply]
}

/// A reply to a canvas comment (Dify's `WorkflowCommentReply`).
public struct StoredReply: Sendable, Equatable {
    public var id: String
    public var content: String
    public var createdBy: ClientID
    public var createdAt: Date
    public var updatedAt: Date
    public var mentions: [ClientID]
}

/// Why a comment write was refused.
public enum CommentError: Error, Sendable, Equatable {
    /// No such comment (or reply) in this document.
    case notFound
    /// Only the author (the client id that created it) may edit or delete it.
    case notAuthor
}

/// Canvas comments: a resource beside the document (no ops, no log, no snapshots). Every operation is bounded by
/// `operationTimeout`; writes return the stored state after the write.
extension PostgresStore {
    /// A fresh time-ordered id (UUID version 7, lowercase, as Dify's `gen_uuidv7_string`).
    public static func newCommentId(now: Date = Date()) -> String {
        var b = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: ms >> (8 * (5 - i))) }
        var rng = SystemRandomNumberGenerator()
        for i in 6..<16 { b[i] = UInt8.random(in: 0...255, using: &rng) }
        b[6] = 0x70 | (b[6] & 0x0F)  // version 7
        b[8] = 0x80 | (b[8] & 0x3F)  // RFC 4122 variant
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let h = Array(hex)
        return "\(String(h[0..<8]))-\(String(h[8..<12]))-\(String(h[12..<16]))-\(String(h[16..<20]))-\(String(h[20..<32]))"
    }

    /// Every comment of the document with its replies, newest first (Dify's list order), resolved ones included.
    public func comments(_ doc: String) async throws -> [StoredComment] {
        try await bounded { try await self.loadComments(doc, only: nil) }
    }

    public func comment(_ doc: String, id: String) async throws -> StoredComment? {
        try await bounded { try await self.loadComments(doc, only: id).first }
    }

    public func createComment(_ doc: String, id: String, x: Double, y: Double, content: String, by: ClientID,
                              mentions: [ClientID]) async throws -> StoredComment {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO comments (doc_id, id, position_x, position_y, content, created_by, mentions)
                VALUES (\(doc), \(id), \(x), \(y), \(content), \(by), \(mentions)::text[])
                """, logger: self.logger)
            guard let c = try await self.loadComments(doc, only: id).first else { throw CommentError.notFound }
            return c
        }
    }

    /// Author only. `nil` leaves a field unchanged (`mentions: nil` keeps the mentions, as Dify).
    public func updateComment(_ doc: String, id: String, by: ClientID, content: String?, x: Double?, y: Double?,
                              mentions: [ClientID]?) async throws -> StoredComment {
        try await bounded {
            let rows = try await self.client.query("""
                UPDATE comments SET content = COALESCE(\(content), content), position_x = COALESCE(\(x), position_x),
                       position_y = COALESCE(\(y), position_y), mentions = COALESCE(\(mentions)::text[], mentions), updated_at = now()
                WHERE doc_id = \(doc) AND id = \(id) AND created_by = \(by) RETURNING id
                """, logger: self.logger)
            if try await !self.anyRow(rows) { try await self.refusal(table: "comments", doc: doc, id: id) }
            guard let c = try await self.loadComments(doc, only: id).first else { throw CommentError.notFound }
            return c
        }
    }

    /// Author only. Deletes the replies with it.
    public func deleteComment(_ doc: String, id: String, by: ClientID) async throws {
        try await bounded {
            let rows = try await self.client.query(
                "DELETE FROM comments WHERE doc_id = \(doc) AND id = \(id) AND created_by = \(by) RETURNING id", logger: self.logger)
            if try await !self.anyRow(rows) { try await self.refusal(table: "comments", doc: doc, id: id) }
        }
    }

    /// Anyone. Idempotent as Dify's: resolving a resolved comment changes nothing (the first resolver and time stay).
    /// `changed` is false in that case.
    public func resolveComment(_ doc: String, id: String, by: ClientID) async throws -> (comment: StoredComment, changed: Bool) {
        try await bounded {
            let rows = try await self.client.query("""
                UPDATE comments SET resolved = true, resolved_by = \(by), resolved_at = now(), updated_at = now()
                WHERE doc_id = \(doc) AND id = \(id) AND NOT resolved RETURNING id
                """, logger: self.logger)
            let changed = try await self.anyRow(rows)
            guard let c = try await self.loadComments(doc, only: id).first else { throw CommentError.notFound }
            return (c, changed)
        }
    }

    /// Anyone. `notFound` if the comment does not exist.
    public func createReply(_ doc: String, comment: String, id: String, content: String, by: ClientID,
                            mentions: [ClientID]) async throws -> StoredReply {
        try await bounded {
            let rows = try await self.client.query("""
                INSERT INTO comment_replies (doc_id, comment_id, id, content, created_by, mentions)
                SELECT \(doc), \(comment), \(id), \(content), \(by), \(mentions)::text[]
                WHERE EXISTS (SELECT 1 FROM comments WHERE doc_id = \(doc) AND id = \(comment))
                RETURNING id
                """, logger: self.logger)
            guard try await self.anyRow(rows), let r = try await self.loadReply(doc, comment: comment, id: id) else {
                throw CommentError.notFound
            }
            return r
        }
    }

    /// Author only. Replaces the mentions (Dify: an omitted list clears them).
    public func updateReply(_ doc: String, comment: String, id: String, by: ClientID, content: String,
                            mentions: [ClientID]) async throws -> StoredReply {
        try await bounded {
            let rows = try await self.client.query("""
                UPDATE comment_replies SET content = \(content), mentions = \(mentions)::text[], updated_at = now()
                WHERE doc_id = \(doc) AND comment_id = \(comment) AND id = \(id) AND created_by = \(by) RETURNING id
                """, logger: self.logger)
            if try await !self.anyRow(rows) { try await self.refusal(table: "comment_replies", doc: doc, id: id, comment: comment) }
            guard let r = try await self.loadReply(doc, comment: comment, id: id) else { throw CommentError.notFound }
            return r
        }
    }

    /// Author only.
    public func deleteReply(_ doc: String, comment: String, id: String, by: ClientID) async throws {
        try await bounded {
            let rows = try await self.client.query("""
                DELETE FROM comment_replies WHERE doc_id = \(doc) AND comment_id = \(comment) AND id = \(id) AND created_by = \(by)
                RETURNING id
                """, logger: self.logger)
            if try await !self.anyRow(rows) { try await self.refusal(table: "comment_replies", doc: doc, id: id, comment: comment) }
        }
    }

    // MARK: - Helpers

    private func anyRow(_ rows: PostgresRowSequence) async throws -> Bool {
        var any = false
        for try await _ in rows { any = true }
        return any
    }

    /// A conditional write matched nothing: tells "does not exist" from "someone else's".
    private func refusal(table: String, doc: String, id: String, comment: String? = nil) async throws -> Never {
        let rows: PostgresRowSequence
        if let comment {
            rows = try await client.query(
                "SELECT 1 FROM comment_replies WHERE doc_id = \(doc) AND comment_id = \(comment) AND id = \(id)", logger: logger)
        } else {
            rows = try await client.query("SELECT 1 FROM comments WHERE doc_id = \(doc) AND id = \(id)", logger: logger)
        }
        throw try await anyRow(rows) ? CommentError.notAuthor : CommentError.notFound
    }

    private func loadReply(_ doc: String, comment: String, id: String) async throws -> StoredReply? {
        let rows = try await client.query("""
            SELECT id, content, created_by, created_at, updated_at, mentions FROM comment_replies
            WHERE doc_id = \(doc) AND comment_id = \(comment) AND id = \(id)
            """, logger: logger)
        for try await r in rows.decode((String, String, String, Date, Date, [String]).self) {
            return StoredReply(id: r.0, content: r.1, createdBy: r.2, createdAt: r.3, updatedAt: r.4, mentions: r.5)
        }
        return nil
    }

    private func loadComments(_ doc: String, only: String?) async throws -> [StoredComment] {
        let rows = try await client.query("""
            SELECT id, position_x, position_y, content, created_by, created_at, updated_at, resolved, resolved_by, resolved_at, mentions
            FROM comments WHERE doc_id = \(doc) AND (\(only)::text IS NULL OR id = \(only))
            ORDER BY created_at DESC, id DESC
            """, logger: logger)
        var out: [StoredComment] = []
        var index: [String: Int] = [:]
        for try await r in rows.decode((String, Double, Double, String, String, Date, Date, Bool, String?, Date?, [String]).self) {
            index[r.0] = out.count
            out.append(StoredComment(id: r.0, positionX: r.1, positionY: r.2, content: r.3, createdBy: r.4, createdAt: r.5,
                                     updatedAt: r.6, resolved: r.7, resolvedBy: r.8, resolvedAt: r.9, mentions: r.10, replies: []))
        }
        if out.isEmpty { return out }
        let replies = try await client.query("""
            SELECT comment_id, id, content, created_by, created_at, updated_at, mentions FROM comment_replies
            WHERE doc_id = \(doc) AND (\(only)::text IS NULL OR comment_id = \(only))
            ORDER BY created_at, id
            """, logger: logger)
        for try await r in replies.decode((String, String, String, String, Date, Date, [String]).self) {
            guard let i = index[r.0] else { continue }
            out[i].replies.append(StoredReply(id: r.1, content: r.2, createdBy: r.3, createdAt: r.4, updatedAt: r.5, mentions: r.6))
        }
        return out
    }
}
