import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Logging
import Vapor

/// HTTP surface (docs/protocol.md, section 2).
struct Routes: Sendable {
    let registry: DocumentRegistry
    let store: PostgresStore
    let config: ServerConfig
    let logger: Logger

    static let maxBodyBytes = 1 << 20
    static let maxOpsPerRequest = 100

    func register(on app: Application) {
        let r = app.routes
        r.get("healthz") { req in await handle(req) { try await healthz() } }
        r.post("v1", "docs") { req in await handle(req) { try await createDoc(req, id: nil) } }
        r.put("v1", "docs", ":doc") { req in
            await handle(req) { try await createDoc(req, id: try docId(req)) }
        }
        r.get("v1", "docs", ":doc") { req in await handle(req) { try await docInfo(try docId(req)) } }
        r.get("v1", "docs", ":doc", "snapshot") { req in await handle(req) { try await snapshot(try docId(req)) } }
        r.post("v1", "docs", ":doc", "ops") { req in await handle(req) { try await submit(req, doc: try docId(req)) } }
        r.get("v1", "docs", ":doc", "events") { req in await handle(req) { try await events(req, doc: try docId(req)) } }
    }

    // MARK: - Plumbing

    private func handle(_ req: Request, _ body: () async throws -> Response) async -> Response {
        do {
            return try await body()
        } catch let e as ServerError {
            switch e {
            case .badRequest(let m): return error(.badRequest, "bad_request", m)
            case .notFound: return error(.notFound, "not_found", "unknown document")
            case .payloadTooLarge: return error(.contentTooLarge, "payload_too_large", "request body over \(Self.maxBodyBytes) bytes")
            case .unavailable(let m):
                logger.warning("503: \(m)")
                return error(.serviceUnavailable, "unavailable", m)
            case .internalError(let m): return error(.internalServerError, "internal", m)
            }
        } catch let e as Abort where e.status == .contentTooLarge {
            return error(.contentTooLarge, "payload_too_large", "request body over \(Self.maxBodyBytes) bytes")
        } catch {
            logger.error("unhandled error: \(error)")
            return self.error(.internalServerError, "internal", "\(error)")
        }
    }

    private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try WireJSON.encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    private func error(_ status: HTTPResponse.Status, _ code: String, _ message: String) -> Response {
        struct Body: Encodable { struct E: Encodable { var code: String; var message: String }; var error: E }
        let data = (try? WireJSON.encode(Body(error: .init(code: code, message: message)))) ?? Data()
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    private func docId(_ req: Request) throws -> String {
        guard let id = req.parameters.get("doc"), Self.validDocId(id) else { throw ServerError.badRequest("invalid document id") }
        return id
    }

    static func validDocId(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }
    }

    static func validClientId(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 58
        }
    }

    private func query(_ req: Request) -> [String: String] {
        var out: [String: String] = [:]
        guard let q = req.url.query else { return out }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            let v = kv.count > 1 ? String(kv[1]) : ""
            out[String(k).removingPercentEncoding ?? String(k)] = v.removingPercentEncoding ?? v
        }
        return out
    }

    private func body(_ req: Request) async throws -> Data {
        try await req.body.collect(max: .specified(ByteCount(value: Self.maxBodyBytes))) ?? Data()
    }

    // MARK: - Handlers

    private func healthz() async throws -> Response {
        do {
            try await store.ping()
        } catch {
            throw ServerError.unavailable("database: \(error)")
        }
        struct Health: Encodable { var status = "ok" }
        return try json(Health())
    }

    private func createDoc(_ req: Request, id: String?) async throws -> Response {
        struct CreateBody: Decodable { var template: String? }
        let data = try await body(req)
        let template = data.isEmpty ? nil : (try? WireJSON.decode(CreateBody.self, from: data))?.template
        guard let initial = Templates.named(template) else { throw ServerError.badRequest("unknown template") }
        let docId = id ?? UUID().uuidString.lowercased()
        let created: Bool
        do { created = try await store.createDocument(id: docId, initial: initial) } catch { throw ServerError.unavailable("\(error)") }
        let head: Int
        do { head = try await store.documentHead(docId) ?? 0 } catch { throw ServerError.unavailable("\(error)") }
        struct Created: Encodable { var id: String; var head: Int; var created: Bool }
        return try json(Created(id: docId, head: head, created: created), status: created ? .created : .ok)
    }

    private func docInfo(_ id: String) async throws -> Response {
        let head: Int?
        do { head = try await store.documentHead(id) } catch { throw ServerError.unavailable("\(error)") }
        guard let head else { throw ServerError.notFound }
        struct Info: Encodable { var id: String; var head: Int }
        return try json(Info(id: id, head: head))
    }

    private func snapshot(_ id: String) async throws -> Response {
        let s = try await registry.sequencer(id).currentSnapshot()
        return try json(SnapshotResponse(seq: s.seq, doc: s.doc))
    }

    private func submit(_ req: Request, doc: String) async throws -> Response {
        let data = try await body(req)
        let parsed: SubmitRequest
        do { parsed = try WireJSON.decode(SubmitRequest.self, from: data) } catch {
            throw ServerError.badRequest("malformed request body: \(error)")
        }
        guard Self.validClientId(parsed.client) else { throw ServerError.badRequest("invalid client id") }
        guard parsed.ops.count <= Self.maxOpsPerRequest else { throw ServerError.badRequest("more than \(Self.maxOpsPerRequest) ops") }
        guard parsed.ops.allSatisfy({ $0.cseq >= 1 }), zip(parsed.ops, parsed.ops.dropFirst()).allSatisfy({ $0.cseq < $1.cseq }) else {
            throw ServerError.badRequest("cseq must be >= 1 and strictly increasing within a request")
        }
        if let f = parsed.floor, f < 1 { throw ServerError.badRequest("floor must be >= 1") }
        if let f = parsed.resolveFrom, f < 1 { throw ServerError.badRequest("resolveFrom must be >= 1") }
        if let first = parsed.ops.first, let f = parsed.floor, first.cseq < f {
            throw ServerError.badRequest("ops below the floor")
        }
        let response = try await registry.sequencer(doc).submit(parsed)
        return try json(response)
    }

    private func events(_ req: Request, doc: String) async throws -> Response {
        let q = query(req)
        var lastEventId: Int?
        let header = req.headers[HTTPField.Name("Last-Event-ID")!] ?? q["lastEventId"]
        if let h = header, !h.isEmpty {
            guard let n = Int(h), n >= 0 else { throw ServerError.badRequest("bad Last-Event-ID") }
            lastEventId = n
        }
        let clientParam = q["client"]
        if let c = clientParam, !Self.validClientId(c) { throw ServerError.badRequest("invalid client id") }
        let client = clientParam
        var fromParam: Int?
        if let f = q["from"] {
            guard let n = Int(f), n >= 1 else { throw ServerError.badRequest("bad from") }
            fromParam = n
        }
        let from = fromParam

        let sequencer = await registry.sequencer(doc)
        let sub = try await sequencer.subscribe(lastEventId: lastEventId, maxReplay: config.maxReplay)
        let store = self.store
        let logger = self.logger
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
        let stream = try Response.Body(stream: { writer in
            defer { Task { await sequencer.unsubscribe(sub.id) } }
            do {
                try await writer.write("retry: 1000\n\n")
                switch sub.plan {
                case .snapshot:
                    var committed: [Int: Int] = [:]
                    if let client, let from { committed = try await store.committedMap(doc, client: client, from: from, through: sub.head) }
                    let frame = try StreamEvent.snapshot(SnapshotEvent(seq: sub.head, doc: sub.doc!, committed: committed)).sseFrame()
                    try await writer.write(frame)
                case .replay(let after):
                    var cursor = after
                    while cursor < sub.head {
                        let chunk = try await store.entries(doc, after: cursor, through: min(sub.head, cursor + 500))
                        guard !chunk.isEmpty else { throw ServerError.internalError("log gap after \(cursor)") }
                        try await writer.write(try chunk.map { try StreamEvent.commit($0).sseFrame() }.joined())
                        cursor = chunk.last!.seq
                    }
                }
                try await writer.write(try StreamEvent.ready(head: sub.head).sseFrame())
                for await frame in sub.live { try await writer.write(frame) }
            } catch {
                logger.debug("stream for \(doc) ended: \(error)")
                throw error
            }
        }, count: nil)
        return Response(status: .ok, headers: headers, body: stream)
    }
}
