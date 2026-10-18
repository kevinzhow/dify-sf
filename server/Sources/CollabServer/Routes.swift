import CollabCore
import CollabDSL
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
        // Dify workflow files (protocol 1.5): import creates a document, export renders the current state.
        r.post("v1", "docs", "import") { req in await handle(req) { try await importDSL(req, id: nil) } }
        r.put("v1", "docs", ":doc", "import") { req in await handle(req) { try await importDSL(req, id: try docId(req)) } }
        r.get("v1", "docs", ":doc", "export") { req in await handle(req) { try await exportDSL(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "meta") { req in await handle(req) { try await appMeta(try docId(req)) } }
        r.post("v1", "docs", ":doc", "secrets") { req in await handle(req) { try await storeSecret(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "snapshot") { req in await handle(req) { try await snapshot(try docId(req)) } }
        r.post("v1", "docs", ":doc", "clients") { req in await handle(req) { try await issueClientId(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "clients") { req in await handle(req) { try await clientDirectory(try docId(req)) } }
        r.put("v1", "docs", ":doc", "clients", ":client") { req in await handle(req) { try await nameClient(req, try docId(req)) } }
        r.post("v1", "docs", ":doc", "ops") { req in await handle(req) { try await submit(req, doc: try docId(req)) } }
        r.get("v1", "docs", ":doc", "events") { req in await handle(req) { try await events(req, doc: try docId(req)) } }
        registerComments(on: r)
    }

    // MARK: - Plumbing

    /// Runs the handler in its own unstructured task: a client that hangs up (timeout, reset, retry) must not
    /// cancel work that is half-way through the database (a cancelled COMMIT is an uncertain commit).
    func handle(_ req: Request, _ body: @escaping @Sendable () async throws -> Response) async -> Response {
        do {
            return try await Task { try await body() }.value
        } catch let e as ServerError {
            switch e {
            case .badRequest(let m): return error(.badRequest, "bad_request", m)
            case .notFound: return error(.notFound, "not_found", "unknown document")
            case .missing(let m): return error(.notFound, "not_found", m)
            case .forbidden(let code, let m): return error(.forbidden, code, m)
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

    func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
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

    func docId(_ req: Request) throws -> String {
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

    func query(_ req: Request) -> [String: String] {
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

    func body(_ req: Request) async throws -> Data {
        try await req.body.collect(max: .specified(ByteCount(value: Self.maxBodyBytes))) ?? Data()
    }

    // MARK: - Handlers

    private func healthz() async throws -> Response {
        do {
            try await store.ping()
        } catch {
            throw ServerError.unavailable("database: \(String(reflecting: error))")
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

    /// Dify workflow files can be large; a 500-node workflow is a few hundred kilobytes.
    static let maxImportBytes = 16 << 20

    /// Body: the Dify DSL as YAML (any content type), or JSON `{"yaml": "..."}`. Creates the document if absent
    /// (`201`); an existing document is left alone (`200`, `created: false`), so a retried import is harmless.
    private func importDSL(_ req: Request, id: String?) async throws -> Response {
        let data = try await req.body.collect(max: .specified(ByteCount(value: Self.maxImportBytes))) ?? Data()
        struct Wrapped: Decodable { var yaml: String }
        let text = (try? WireJSON.decode(Wrapped.self, from: data))?.yaml ?? String(decoding: data, as: UTF8.self)
        let imported: DifyDSL.Imported
        do { imported = try DifyDSL.importYAML(text) } catch { throw ServerError.badRequest("not an importable Dify workflow: \(error)") }
        let docId = id ?? UUID().uuidString.lowercased()
        let created: Bool
        do {
            created = try await store.createDocument(id: docId, initial: imported.document, metadata: imported.metadata,
                                                     secrets: imported.secrets)
        } catch {
            throw ServerError.unavailable("\(error)")
        }
        let head: Int
        do { head = try await store.documentHead(docId) ?? 0 } catch { throw ServerError.unavailable("\(error)") }
        struct Created: Encodable { var id: String; var head: Int; var created: Bool; var nodes: Int; var edges: Int }
        return try json(Created(id: docId, head: head, created: created, nodes: imported.document.nodes.count,
                                edges: imported.document.edges.count), status: created ? .created : .ok)
    }

    /// The current state as a Dify workflow file: YAML, or `?format=json`. Documents that were not imported get a
    /// minimal app skeleton. Secret environment variables are exported with `""` unless `?include_secret=true` (Dify's
    /// option of the same name): then with their stored plaintext (protocol 1.7).
    private func exportDSL(_ req: Request, _ id: String) async throws -> Response {
        let meta: Value?
        do { meta = try await store.documentMetadata(id) } catch { throw ServerError.unavailable("\(error)") }
        let s = try await registry.sequencer(id).currentSnapshot()
        let metadata = meta ?? DifyDSL.defaultMetadata(name: id)
        let q = query(req)
        var secrets: [String: String]?
        if q["include_secret"] == "true" {
            do { secrets = try await store.secrets(id) } catch { throw ServerError.unavailable("\(error)") }
        }
        var headers = HTTPFields()
        if q["format"] == "json" {
            let v = try DifyDSL.exportValue(s.doc, metadata: metadata, secrets: secrets)
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(data: try WireJSON.encode(v)))
        }
        headers[.contentType] = "application/x-yaml; charset=utf-8"
        let yaml = try DifyDSL.exportYAML(s.doc, metadata: metadata, secrets: secrets)
        return Response(status: .ok, headers: headers, body: .init(data: Data(yaml.utf8)))
    }

    /// The Dify app metadata (mode, name, variables, features) without the graph; see `DifyDSL.appMeta`. Variables and
    /// features come from the document at head (protocol 1.7). Documents that were not imported get the same defaults as
    /// their export.
    private func appMeta(_ id: String) async throws -> Response {
        try await requireDoc(id)
        let meta: Value?
        do { meta = try await store.documentMetadata(id) } catch { throw ServerError.unavailable("\(error)") }
        let s = try await registry.sequencer(id).currentSnapshot()
        return try json(DifyDSL.appMeta(meta ?? DifyDSL.defaultMetadata(name: id), document: s.doc))
    }

    /// Protocol 1.7: `POST /secrets` `{"value": "..."}` stores the plaintext of a secret environment variable and answers
    /// `201 {"ref": "sec-<32 hex>", "masked": "<Dify's mask>"}`. The client then writes the variable with ordinary item ops,
    /// with `value` = the mask and `secret_ref` = the reference; the plaintext never enters ops, the log or snapshots.
    private func storeSecret(_ req: Request, _ doc: String) async throws -> Response {
        struct SecretBody: Decodable { var value: String }
        let data = try await body(req)
        guard let value = (try? WireJSON.decode(SecretBody.self, from: data))?.value else {
            throw ServerError.badRequest("body must be {\"value\": string}")
        }
        try await requireDoc(doc)
        let ref = DifyDSL.newSecretRef()
        do { try await store.storeSecret(doc, ref: ref, value: value) } catch { throw ServerError.unavailable("\(error)") }
        struct Stored: Encodable { var ref: String; var masked: String }
        return try json(Stored(ref: ref, masked: DifyDSL.maskSecret(value)), status: .created)
    }

    private func docInfo(_ id: String) async throws -> Response {
        let head: Int?
        do { head = try await store.documentHead(id) } catch { throw ServerError.unavailable("\(error)") }
        guard let head else { throw ServerError.notFound }
        struct Info: Encodable { var id: String; var head: Int }
        return try json(Info(id: id, head: head))
    }

    private struct NameBody: Decodable { var name: String? }

    private func displayName(_ req: Request, required: Bool) async throws -> String? {
        let data = try await body(req)
        let name = data.isEmpty ? nil : (try? WireJSON.decode(NameBody.self, from: data))?.name
        if let n = name {
            guard !n.isEmpty, n.utf8.count <= 64, !n.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw ServerError.badRequest("name must be 1-64 bytes without control characters")
            }
        } else if required { throw ServerError.badRequest("missing name") }
        return name
    }

    func requireDoc(_ doc: String) async throws {
        let head: Int?
        do { head = try await store.documentHead(doc) } catch { throw ServerError.unavailable("\(error)") }
        guard head != nil else { throw ServerError.notFound }
    }

    /// Hands out a fresh, unique client id (a UUID): the safe way to avoid two tabs/processes sharing one cseq stream.
    /// Optional body `{"name": "Bo"}` registers a display name for it (protocol 1.3).
    private func issueClientId(_ req: Request, _ doc: String) async throws -> Response {
        let name = try await displayName(req, required: false)
        try await requireDoc(doc)
        let id = "s-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        if let name { try await registry.sequencer(doc).setName(client: id, name: name) }
        struct Issued: Encodable { var client: String; var name: String? }
        return try json(Issued(client: id, name: name), status: .created)
    }

    /// `PUT /clients/{client}` `{"name": ...}`: names (or renames) a client id the client chose itself.
    private func nameClient(_ req: Request, _ doc: String) async throws -> Response {
        guard let client = req.parameters.get("client"), Self.validClientId(client) else { throw ServerError.badRequest("invalid client id") }
        let name = try await displayName(req, required: true)!
        try await requireDoc(doc)
        try await registry.sequencer(doc).setName(client: client, name: name)
        struct Named: Encodable { var client: String; var name: String }
        return try json(Named(client: client, name: name))
    }

    /// `GET /clients`: every registered display name of the document.
    private func clientDirectory(_ doc: String) async throws -> Response {
        try await requireDoc(doc)
        let names = try await registry.sequencer(doc).clientNames(force: true)
        struct Directory: Encodable { var clients: [String: String] }
        return try json(Directory(clients: names))
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
        // Protocol 1.6: `proto` is the version the client implements; older clients never get a commit they cannot decode
        // (restoreNode below 1.6, `$app` writes below 1.7).
        let proto = q["proto"]
        if let p = proto, StreamCompat.parse(p) == nil { throw ServerError.badRequest("bad proto") }

        let sequencer = await registry.sequencer(doc)
        var subscription = try await sequencer.subscribe(lastEventId: lastEventId, maxReplay: config.maxReplay, proto: proto)
        if !StreamCompat.acceptsAll(proto), case .replay(let after) = subscription.plan, after < subscription.head {
            do {
                let head = subscription.head
                // `doc` was captured at `head` for exactly this case.
                var unsupported = false
                if !StreamCompat.acceptsRestore(proto) {
                    unsupported = try await store.logContainsOp(doc, type: "restoreNode", after: after, through: head)
                }
                if !unsupported, !StreamCompat.acceptsApp(proto) {
                    unsupported = try await store.logTouchesApp(doc, after: after, through: head)
                }
                if unsupported { subscription.plan = .snapshot }
            } catch {
                await sequencer.unsubscribe(subscription.id)
                throw error
            }
        }
        let sub = subscription
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
