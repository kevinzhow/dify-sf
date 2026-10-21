import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Canvas comments (docs/protocol.md, "Comments"): Dify 1.17.1's workflow comments as a resource beside the document.
/// Not part of the collaborative document, the op log, snapshots, the export or undo. Authors are accounts (protocol 1.8):
/// any member reads; writing needs the edit role (Dify's `edit_permission_required`); only the author edits, moves or
/// deletes a comment or reply (`403 not_author`), any editor resolves (idempotent) and replies.
extension Routes {
    /// Dify's `_validate_content`: not blank, at most 1000 characters (Unicode scalars, as Python's `len`).
    static let maxCommentChars = 1000

    func registerComments(on r: any RoutesBuilder) {
        r.get("v1", "docs", ":doc", "comments") { req in await handle(req) { try await listComments(req, try docId(req)) } }
        r.post("v1", "docs", ":doc", "comments") { req in await handle(req) { try await createComment(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "comments", "mention-users") { req in await handle(req) { try await mentionUsers(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "comments", ":comment") { req in
            await handle(req) { try await getComment(req, try docId(req), try commentId(req)) }
        }
        r.put("v1", "docs", ":doc", "comments", ":comment") { req in
            await handle(req) { try await updateComment(req, try docId(req), try commentId(req)) }
        }
        r.delete("v1", "docs", ":doc", "comments", ":comment") { req in
            await handle(req) { try await deleteComment(req, try docId(req), try commentId(req)) }
        }
        r.post("v1", "docs", ":doc", "comments", ":comment", "resolve") { req in
            await handle(req) { try await resolveComment(req, try docId(req), try commentId(req)) }
        }
        r.post("v1", "docs", ":doc", "comments", ":comment", "replies") { req in
            await handle(req) { try await createReply(req, try docId(req), try commentId(req)) }
        }
        r.put("v1", "docs", ":doc", "comments", ":comment", "replies", ":reply") { req in
            await handle(req) { try await updateReply(req, try docId(req), try commentId(req), try replyId(req)) }
        }
        r.delete("v1", "docs", ":doc", "comments", ":comment", "replies", ":reply") { req in
            await handle(req) { try await deleteReply(req, try docId(req), try commentId(req), try replyId(req)) }
        }
    }

    // MARK: - Wire shapes

    /// A mentioned account (`{"account", "name"?, "avatar_url"?}`; name and avatar when the account exists).
    struct MentionJSON: Encodable {
        var account: String
        var name: String?
        var avatar_url: String?
    }

    struct ReplyJSON: Encodable {
        var id: String
        var content: String
        var created_by: String
        var created_by_name: String?
        var created_by_avatar_url: String?
        var created_at: String
        var updated_at: String
        var mentions: [MentionJSON]
    }

    struct CommentJSON: Encodable {
        var id: String
        var position_x: Double
        var position_y: Double
        var content: String
        var created_by: String
        var created_by_name: String?
        var created_by_avatar_url: String?
        var created_at: String
        var updated_at: String
        var resolved: Bool
        var resolved_by: String?
        var resolved_by_name: String?
        var resolved_by_avatar_url: String?
        var resolved_at: String?
        var mentions: [MentionJSON]
        var replies: [ReplyJSON]
        var reply_count: Int
    }

    typealias Names = [String: (name: String, avatarUrl: String?)]

    static func timestamp(_ d: Date) -> String {
        d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!))
    }

    static func mention(_ id: String, _ names: Names) -> MentionJSON {
        MentionJSON(account: id, name: names[id]?.name, avatar_url: names[id]?.avatarUrl)
    }

    static func wire(_ r: StoredReply, names: Names) -> ReplyJSON {
        ReplyJSON(id: r.id, content: r.content, created_by: r.createdBy, created_by_name: names[r.createdBy]?.name,
                  created_by_avatar_url: names[r.createdBy]?.avatarUrl, created_at: timestamp(r.createdAt),
                  updated_at: timestamp(r.updatedAt), mentions: r.mentions.map { mention($0, names) })
    }

    static func wire(_ c: StoredComment, names: Names) -> CommentJSON {
        CommentJSON(id: c.id, position_x: c.positionX, position_y: c.positionY, content: c.content, created_by: c.createdBy,
                    created_by_name: names[c.createdBy]?.name, created_by_avatar_url: names[c.createdBy]?.avatarUrl,
                    created_at: timestamp(c.createdAt), updated_at: timestamp(c.updatedAt), resolved: c.resolved,
                    resolved_by: c.resolvedBy, resolved_by_name: c.resolvedBy.flatMap { names[$0]?.name },
                    resolved_by_avatar_url: c.resolvedBy.flatMap { names[$0]?.avatarUrl }, resolved_at: c.resolvedAt.map(timestamp),
                    mentions: c.mentions.map { mention($0, names) }, replies: c.replies.map { wire($0, names: names) },
                    reply_count: c.replies.count)
    }

    // MARK: - Validation

    private func commentId(_ req: Request) throws -> String {
        guard let id = req.parameters.get("comment"), Self.validClientId(id) else { throw ServerError.missing("unknown comment") }
        return id
    }

    private func replyId(_ req: Request) throws -> String {
        guard let id = req.parameters.get("reply"), Self.validClientId(id) else { throw ServerError.missing("unknown reply") }
        return id
    }

    static func validateContent(_ content: String) throws {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ServerError.badRequest("Comment content cannot be empty")
        }
        if content.unicodeScalars.count > maxCommentChars {
            throw ServerError.badRequest("Comment content cannot exceed \(maxCommentChars) characters")
        }
    }

    /// Dify's `_filter_valid_mentioned_user_ids`: keeps the ids of workspace members, once each, in the order given.
    func mentions(_ ids: [String]?) async throws -> [String] {
        guard let ids, !ids.isEmpty else { return [] }
        let members = Set(try await storeCall { try await store.members() }.map(\.id))
        var seen = Set<String>()
        return ids.filter { members.contains($0) && seen.insert($0).inserted }
    }

    private func decodeBody<T: Decodable>(_ req: Request, _ t: T.Type, _ shape: String) async throws -> T {
        let data = try await body(req)
        do { return try WireJSON.decode(T.self, from: data) } catch { throw ServerError.badRequest("body must be \(shape)") }
    }

    private func finite(_ v: Double?) throws {
        if let v, !v.isFinite { throw ServerError.badRequest("positions must be finite numbers") }
    }

    private func mapped<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as CommentError {
            switch e {
            case .notFound: throw ServerError.missing("unknown \(what)")
            case .notAuthor: throw ServerError.forbidden(code: "not_author", message: "only the author may change or delete this \(what)")
            }
        } catch let e as ServerError {
            throw e
        } catch {
            throw ServerError.unavailable("\(error)")
        }
    }

    /// Account names and avatars, looked up when a comment is read (so a rename shows everywhere).
    private func names() async -> Names {
        ((try? await store.accountNames()) ?? [:]).mapValues { (name: $0.name, avatarUrl: signedAvatar($0.avatarUrl)) }
    }

    private func announce(_ doc: String, _ comment: String, _ action: CommentsEvent.Action) async {
        await registry.sequencer(doc).announceComment(CommentsEvent(comment: comment, action: action))
    }

    // MARK: - Handlers

    /// Dify's `/comments/mention-users`: every workspace member, `{"users": [{id, name, email, avatar_url?, role}]}`.
    private func mentionUsers(_ req: Request, _ doc: String) async throws -> Response {
        _ = try await authenticate(req)
        try await requireDoc(doc)
        let all = try await storeCall { try await store.members() }
        struct User: Encodable { var id: String; var name: String; var email: String; var avatar_url: String?; var role: String }
        struct Users: Encodable { var users: [User] }
        return try json(Users(users: all.map { User(id: $0.id, name: $0.name, email: $0.email, avatar_url: signedAvatar($0.avatarUrl), role: $0.role ?? "") }))
    }

    private func listComments(_ req: Request, _ doc: String) async throws -> Response {
        _ = try await authenticate(req)
        try await requireDoc(doc)
        let all = try await mapped("comment") { try await store.comments(doc) }
        let n = await names()
        struct List: Encodable { var comments: [CommentJSON] }
        return try json(List(comments: all.map { Self.wire($0, names: n) }))
    }

    private func getComment(_ req: Request, _ doc: String, _ id: String) async throws -> Response {
        _ = try await authenticate(req)
        try await requireDoc(doc)
        guard let c = try await mapped("comment", { try await store.comment(doc, id: id) }) else { throw ServerError.missing("unknown comment") }
        return try json(Self.wire(c, names: await names()))
    }

    private func createComment(_ req: Request, _ doc: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        struct Body: Decodable {
            var position_x: Double
            var position_y: Double
            var content: String
            var mentioned_user_ids: [String]?
        }
        let b = try await decodeBody(req, Body.self, #"{"position_x","position_y","content","mentioned_user_ids"?}"#)
        try finite(b.position_x)
        try finite(b.position_y)
        try Self.validateContent(b.content)
        try await requireDoc(doc)
        let m = try await mentions(b.mentioned_user_ids)
        let id = PostgresStore.newCommentId()
        let c = try await mapped("comment") {
            try await store.createComment(doc, id: id, x: b.position_x, y: b.position_y, content: b.content, by: by, mentions: m)
        }
        await announce(doc, id, .created)
        return try json(Self.wire(c, names: await names()), status: .created)
    }

    /// Author only, also for a move (Dify lets only the creator drag a pin). Omitted fields stay; `content`, which Dify
    /// always requires, may be omitted here (a move).
    private func updateComment(_ req: Request, _ doc: String, _ id: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        struct Body: Decodable {
            var content: String?
            var position_x: Double?
            var position_y: Double?
            var mentioned_user_ids: [String]?
        }
        let b = try await decodeBody(req, Body.self, #"{"content"?,"position_x"?,"position_y"?,"mentioned_user_ids"?}"#)
        try finite(b.position_x)
        try finite(b.position_y)
        if let content = b.content { try Self.validateContent(content) }
        try await requireDoc(doc)
        let m: [String]? = b.mentioned_user_ids == nil ? nil : try await mentions(b.mentioned_user_ids)
        let c = try await mapped("comment") {
            try await store.updateComment(doc, id: id, by: by, content: b.content, x: b.position_x, y: b.position_y, mentions: m)
        }
        await announce(doc, id, .updated)
        return try json(Self.wire(c, names: await names()))
    }

    private func deleteComment(_ req: Request, _ doc: String, _ id: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        try await requireDoc(doc)
        try await mapped("comment") { try await store.deleteComment(doc, id: id, by: by) }
        await announce(doc, id, .deleted)
        return Response(status: .noContent)
    }

    private func resolveComment(_ req: Request, _ doc: String, _ id: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        try await requireDoc(doc)
        let (c, changed) = try await mapped("comment") { try await store.resolveComment(doc, id: id, by: by) }
        if changed { await announce(doc, id, .resolved) }
        return try json(Self.wire(c, names: await names()))
    }

    private struct ReplyBody: Decodable {
        var content: String
        var mentioned_user_ids: [String]?
    }

    private func createReply(_ req: Request, _ doc: String, _ comment: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        let b = try await decodeBody(req, ReplyBody.self, #"{"content","mentioned_user_ids"?}"#)
        try Self.validateContent(b.content)
        try await requireDoc(doc)
        let m = try await mentions(b.mentioned_user_ids)
        let id = PostgresStore.newCommentId()
        let r = try await mapped("comment") {
            try await store.createReply(doc, comment: comment, id: id, content: b.content, by: by, mentions: m)
        }
        await announce(doc, comment, .reply)
        return try json(Self.wire(r, names: await names()), status: .created)
    }

    /// Author only. As Dify, the mentions are replaced (an omitted list clears them).
    private func updateReply(_ req: Request, _ doc: String, _ comment: String, _ id: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        let b = try await decodeBody(req, ReplyBody.self, #"{"content","mentioned_user_ids"?}"#)
        try Self.validateContent(b.content)
        try await requireDoc(doc)
        let m = try await mentions(b.mentioned_user_ids)
        let r = try await mapped("reply") {
            try await store.updateReply(doc, comment: comment, id: id, by: by, content: b.content, mentions: m)
        }
        await announce(doc, comment, .reply)
        return try json(Self.wire(r, names: await names()))
    }

    private func deleteReply(_ req: Request, _ doc: String, _ comment: String, _ id: String) async throws -> Response {
        let by = try await authenticate(req, .edit).id
        try await requireDoc(doc)
        try await mapped("reply") { try await store.deleteReply(doc, comment: comment, id: id, by: by) }
        await announce(doc, comment, .reply)
        return Response(status: .noContent)
    }
}
