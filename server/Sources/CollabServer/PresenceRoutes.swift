import CollabCore
import Foundation
import Vapor

/// Protocol 1.22: `PUT /v1/docs/{doc}/presence` (a client's pointer and open panel) and `DELETE` (the client is gone). The
/// merged state reaches the document's streams as `event: presence` (`PresenceRoom`). Dify 1.17.1 refuses its
/// collaboration connection to members without edit permission, so reporting needs the edit role; every member's stream
/// still receives presence.
extension Routes {
    func registerPresence(on r: any RoutesBuilder) {
        r.put("v1", "docs", ":doc", "presence") { req in await handle(req) { try await putPresence(req, try docId(req)) } }
        r.delete("v1", "docs", ":doc", "presence") { req in await handle(req) { try await deletePresence(req, try docId(req)) } }
    }

    /// The body of `PUT .../presence`: a missing `cursor` / `drag` / `panel` leaves it unchanged, `null` clears it.
    struct PresenceReport: Decodable {
        var client: String
        var cursor: PresencePoint??
        var drag: PresenceDrag??
        var panel: String??

        enum CodingKeys: String, CodingKey { case client, cursor, drag, panel }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            client = try c.decode(String.self, forKey: .client)
            cursor = c.contains(.cursor) ? .some(try c.decodeNil(forKey: .cursor) ? nil : try c.decode(PresencePoint.self, forKey: .cursor)) : nil
            drag = c.contains(.drag) ? .some(try c.decodeNil(forKey: .drag) ? nil : try c.decode(PresenceDrag.self, forKey: .drag)) : nil
            panel = c.contains(.panel) ? .some(try c.decodeNil(forKey: .panel) ? nil : try c.decode(String.self, forKey: .panel)) : nil
        }
    }

    private func putPresence(_ req: Request, _ doc: String) async throws -> Response {
        let principal = try await authenticate(req, .edit)
        let report: PresenceReport
        do { report = try WireJSON.decode(PresenceReport.self, from: try await body(req)) } catch {
            throw ServerError.badRequest("malformed request body: \(error)")
        }
        guard Self.validClientId(report.client) else { throw ServerError.badRequest("invalid client id") }
        if case .some(.some(let p)) = report.cursor, !p.x.isFinite || !p.y.isFinite || abs(p.x) > 1e7 || abs(p.y) > 1e7 {
            throw ServerError.badRequest("cursor out of range")
        }
        if case .some(.some(let d)) = report.drag,
           d.node.isEmpty || d.node.utf8.count > 256 || !d.x.isFinite || !d.y.isFinite || abs(d.x) > 1e7 || abs(d.y) > 1e7 {
            throw ServerError.badRequest("invalid drag")
        }
        if case .some(.some(let n)) = report.panel, n.isEmpty || n.utf8.count > 256 { throw ServerError.badRequest("invalid panel") }
        // The first use binds a free id (and 404s an unknown document), as for ops.
        try await requireOwnClient(doc, report.client, principal, bindIfFree: true)
        await registry.presence(doc).update(
            client: report.client, account: principal.id, name: principal.account.name,
            avatar: signedAvatar(principal.account.avatarUrl), cursor: report.cursor, drag: report.drag, panel: report.panel)
        return Response(status: .noContent)
    }

    private func deletePresence(_ req: Request, _ doc: String) async throws -> Response {
        let principal = try await authenticate(req)
        guard let client = query(req)["client"], Self.validClientId(client) else { throw ServerError.badRequest("invalid client id") }
        let owner = try await registry.sequencer(doc).account(of: client)
        if let owner, owner != principal.id {
            throw ServerError.http(status: 403, code: "forbidden", message: "client id \(client) belongs to another account")
        }
        await registry.presence(doc).remove(client: client)
        return Response(status: .noContent)
    }
}
