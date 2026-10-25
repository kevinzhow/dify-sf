import CollabCore
import CollabDSL
import CollabStore
import Foundation
import HTTPTypes
import Logging
import Vapor

/// HTTP surface (docs/protocol.md, section 2).
struct Routes: Sendable {
    /// Forgot password: Dify's mail and code limits (per process).
    let passwordResetLimits = PasswordResetLimits()
    /// Changing the email (protocol 1.12): Dify's mail and code limits (per process).
    let changeEmailLimits = ChangeEmailLimits()
    /// Draft runs in progress (protocol 1.14), by task id.
    let runs = WorkflowRunRegistry()
    /// This process's live run channels, for `GET /v1/workflow/{runId}/events` (Dify's reconnect endpoint).
    let runChannels = RunChannelRegistry()
    let registry: DocumentRegistry
    let store: PostgresStore
    let config: ServerConfig
    let logger: Logger
    let blobs: any BlobStore
    let uploadBudget = UploadBudget()
    let agentModelScopes = AgentModelScopes()
    let agentShellHealth = AgentShellHealthCache()
    let agentOwner = UUID().uuidString.lowercased()

    static let maxBodyBytes = 1 << 20
    static let maxOpsPerRequest = 100

    /// Dify's login error rate limit (per process).
    let limiter: LoginLimiter
    /// Model providers (protocol 1.9): the catalog and the credential checker.
    let models: ModelService

    /// `models` defaults to the vendored catalog with real credential checks (as configured).
    init(registry: DocumentRegistry, store: PostgresStore, config: ServerConfig, logger: Logger, models: ModelService? = nil, blobs: (any BlobStore)? = nil) throws {
        self.registry = registry
        self.store = store
        self.config = config
        self.logger = logger
        self.blobs = try blobs ?? LocalBlobStore(directory: config.files.directory)
        limiter = LoginLimiter(maxFailures: config.loginMaxFailures, lockoutSeconds: config.loginLockoutSeconds)
        self.models = try models ?? ModelService.live(config: config)
    }

    /// Every `/v1` route except setup, login, refresh and activation requires `Authorization: Bearer <access token>`
    /// (protocol 1.8): reads need any member, writes the edit role (`owner`, `admin`, `editor`).
    func register(on app: Application) {
        let r = app.routes
        r.get("healthz") { req in await handle(req) { try await healthz() } }
        registerAuth(on: r)
        r.post("v1", "docs") { req in await handle(req) { try await createDoc(req, id: nil) } }
        r.put("v1", "docs", ":doc") { req in
            await handle(req) { try await createDoc(req, id: try docId(req)) }
        }
        r.get("v1", "docs", ":doc") { req in await handle(req) { try await docInfo(req, try docId(req)) } }
        // Dify workflow files (protocol 1.5): import creates a document, export renders the current state.
        r.post("v1", "docs", "import") { req in await handle(req) { try await importDSL(req, id: nil) } }
        r.put("v1", "docs", ":doc", "import") { req in await handle(req) { try await importDSL(req, id: try docId(req)) } }
        r.post("v1", "docs", ":doc", "replace") { req in await handle(req) { try await replaceDSL(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "export") { req in await handle(req) { try await exportDSL(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "meta") { req in await handle(req) { try await appMeta(req, try docId(req)) } }
        r.post("v1", "docs", ":doc", "secrets") { req in await handle(req) { try await storeSecret(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "snapshot") { req in await handle(req) { try await snapshot(req, try docId(req)) } }
        r.post("v1", "docs", ":doc", "clients") { req in await handle(req) { try await issueClientId(req, try docId(req)) } }
        r.get("v1", "docs", ":doc", "clients") { req in await handle(req) { try await clientDirectory(req, try docId(req)) } }
        r.put("v1", "docs", ":doc", "clients", ":client") { req in await handle(req) { try await bindClient(req, try docId(req)) } }
        r.post("v1", "docs", ":doc", "ops") { req in await handle(req) { try await submit(req, doc: try docId(req)) } }
        r.get("v1", "docs", ":doc", "events") { req in await handle(req) { try await events(req, doc: try docId(req)) } }
        registerComments(on: r)
        registerModels(on: r)
        registerAgentComposer(on: r)
        registerAgentModels(on: r)
        registerAgentUploads(on: r)
        registerTools(on: r)
        registerHelpers(on: r)
        registerApps(on: r)
        registerAppDetail(on: r)
        registerRuntime(on: r)
        registerRuns(on: r)
        registerPublicRuntime(on: r)
        registerChatRuns(on: r)
        registerContainerRuns(on: r)
        registerDraftVariables(on: r)
        registerHumanInput(on: r)
        registerFiles(on: r)
        registerHumanInputNode(on: r)
        registerRunEvents(on: r)
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
            case .unauthorized(let m): return error(.unauthorized, "unauthorized", m)
            case .http(let status, let code, let m): return error(HTTPResponse.Status(code: status), code, m)
            case .appDeleted: return error(.notFound, "app_deleted", "the app was deleted")
            }
        } catch is SecretsKeyMissing {
            return error(.serviceUnavailable, "secrets_key_missing", "the server has no secrets key (COLLAB_SECRETS_KEY), so it cannot store secrets")
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
        let principal = try await authenticate(req, .edit)
        struct CreateBody: Decodable { var template: String? }
        let data = try await body(req)
        let template = data.isEmpty ? nil : (try? WireJSON.decode(CreateBody.self, from: data))?.template
        guard let initial = Templates.named(template) else { throw ServerError.badRequest("unknown template") }
        let docId = id ?? UUID().uuidString.lowercased()
        let created: Bool
        do {
            created = try await store.createDocument(id: docId, initial: initial, app: NewApp(name: docId, createdBy: principal.id))
        } catch { throw ServerError.unavailable("\(error)") }
        let head = try await liveHead(docId)
        struct Created: Encodable { var id: String; var head: Int; var created: Bool }
        return try json(Created(id: docId, head: head, created: created), status: created ? .created : .ok)
    }

    /// Dify workflow files can be large; a 500-node workflow is a few hundred kilobytes.
    static let maxImportBytes = 16 << 20

    /// Body: the Dify DSL as YAML (any content type), or JSON `{"yaml": "..."}`. Creates the document if absent
    /// (`201`); an existing document is left alone (`200`, `created: false`), so a retried import is harmless.
    private func importDSL(_ req: Request, id: String?) async throws -> Response {
        let principal = try await authenticate(req, .edit)
        let data = try await req.body.collect(max: .specified(ByteCount(value: Self.maxImportBytes))) ?? Data()
        struct Wrapped: Decodable { var yaml: String }
        let text = (try? WireJSON.decode(Wrapped.self, from: data))?.yaml ?? String(decoding: data, as: UTF8.self)
        let imported: DifyDSL.Imported
        do { imported = try DifyDSL.importYAML(text) } catch { throw ServerError.badRequest("not an importable Dify workflow: \(error)") }
        if !imported.secrets.isEmpty { try requireSecretsKey() }
        let docId = id ?? UUID().uuidString.lowercased()
        let created: Bool
        do {
            created = try await createAgentAwareDocument(id: docId, imported: imported,
                app: NewApp.from(metadata: imported.metadata, fallbackName: docId, createdBy: principal.id), user: principal.id)
        } catch let error as ServerError { throw error }
        catch { throw ServerError.unavailable("The workflow import could not be committed") }
        let head = try await liveHead(docId)
        struct Created: Encodable { var id: String; var head: Int; var created: Bool; var nodes: Int; var edges: Int }
        return try json(Created(id: docId, head: head, created: created, nodes: imported.document.nodes.count,
                                edges: imported.document.edges.count), status: created ? .created : .ok)
    }

    /// `POST /v1/docs/{doc}/replace` (docs/protocol.md section 2, "Replacing a document"): overwrites the document with a Dify
    /// workflow file, as ordinary ops of the caller's client id committed in one transaction. Body: the YAML, or JSON
    /// `{"yaml": "...", "client"?, "cseq"?, "confirm"?}`; `client`, `cseq` and `confirm` may also be query parameters.
    private func replaceDSL(_ req: Request, _ doc: String) async throws -> Response {
        let principal = try await authenticate(req, .edit)
        let data = try await req.body.collect(max: .specified(ByteCount(value: Self.maxImportBytes))) ?? Data()
        struct Wrapped: Decodable { var yaml: String; var client: String?; var cseq: Int?; var confirm: Bool? }
        let wrapped = try? WireJSON.decode(Wrapped.self, from: data)
        let q = query(req)
        guard let client = wrapped?.client ?? q["client"], Self.validClientId(client) else {
            throw ServerError.badRequest("client (the caller's client id) is required")
        }
        guard let cseq = wrapped?.cseq ?? q["cseq"].flatMap({ Int($0) }), cseq >= 1 else {
            throw ServerError.badRequest("cseq (the client's next cseq, >= 1) is required")
        }
        let confirm = wrapped?.confirm ?? (q["confirm"] == "true")
        try await requireDoc(doc)
        try await requireOwnClient(doc, client, principal, bindIfFree: true)
        let text = wrapped?.yaml ?? String(decoding: data, as: UTF8.self)
        let root: Value
        do { root = try DifyDSL.parseYAML(text) } catch {
            throw ServerError.badRequest("Invalid YAML format: \(error)")
        }
        switch try await replaceDocument(doc, with: root, principal: principal, client: client, cseq: cseq, confirm: confirm, adoptApp: true) {
        case .pending(let response): return response
        case .replaced(let answer): return try json(answer)
        }
    }

    /// The answer of a replacement (`POST /replace`, and protocol 1.11's version restore).
    struct ReplaceAnswer: Encodable {
        struct RenamedIds: Encodable { var nodes: [String: String]; var edges: [String: String] }
        var head: Int; var ops: Int; var nodes: Int; var edges: Int; var next_cseq: Int; var replayed: Bool
        var status: String; var imported_dsl_version: String; var current_dsl_version: String; var renamed: RenamedIds
    }

    enum ReplaceOutcome {
        /// The file's DSL version needs confirmation: the `400 version_unconfirmed` answer.
        case pending(Response)
        case replaced(ReplaceAnswer)
    }

    /// Replaces document `doc` (live, `client` already checked to be the caller's) by the Dify file `root` with ops of
    /// `client` from `cseq` (docs/protocol.md, "Replacing a document"). With `adoptApp` the app takes the file's name,
    /// description and icon (Dify's overwrite import); a version restore keeps them (Dify's restore touches the draft only).
    func replaceDocument(_ doc: String, with root: Value, principal: Principal, client: String, cseq: Int, confirm: Bool,
                         adoptApp: Bool) async throws -> ReplaceOutcome {
        let meta: Value?
        do { meta = try await store.documentMetadata(doc) } catch { throw ServerError.unavailable("\(error)") }
        let checked: (version: String, status: DifyDSL.VersionStatus)
        do { checked = try DifyDSL.checkReplacement(root, appMode: DifyDSL.appMode(meta), confirm: confirm) } catch {
            if let v = error.pendingVersion {
                struct Pending: Encodable {
                    struct E: Encodable { var code: String; var message: String; var imported_dsl_version: String; var current_dsl_version: String }
                    var error: E
                }
                return .pending(try json(Pending(error: .init(code: "version_unconfirmed", message: error.message, imported_dsl_version: v,
                                                              current_dsl_version: DifyDSL.currentDSLVersion)), status: .badRequest))
            }
            throw ServerError.badRequest(error.message)
        }
        let store = self.store
        let routes = self
        typealias Renamed = (nodes: [String: String], edges: [String: String])
        let (outcome, renamed) = try await registry.sequencer(doc).replace(client: client, cseq: cseq) { current, head -> (DocumentSequencer.ReplaceWork, Renamed) in
            let metadata: Value?, secrets: [String: String]
            do {
                metadata = try await store.documentMetadata(doc)
                secrets = try await store.secrets(doc)
            } catch { throw ServerError.unavailable("\(error)") }
            let plan: DifyDSL.ReplacementPlan
            do {
                plan = try DifyDSL.planReplacement(root, current: current, metadata: metadata, storedSecrets: secrets, client: client, base: head)
            } catch let e as Replacement.Failure {
                throw ServerError.badRequest("the workflow cannot be applied to this document: \(e)")
            } catch {
                throw ServerError.badRequest("not an importable Dify workflow: \(error)")
            }
            if !plan.secrets.isEmpty, store.cipher == nil { throw SecretsKeyMissing() }
            let agents = try await routes.agentImportPlan(plan.document, metadata: plan.metadata, app: doc,
                user: principal.id, preserveLocalBindings: !adoptApp)
            return (.init(ops: plan.ops + (try agents.bindingOps()), metadata: agents.metadata == metadata ? nil : agents.metadata,
                          secrets: plan.secrets, agentConfigs: agents.changes), (plan.renamedNodes, plan.renamedEdges))
        }
        // Protocol 1.10: as Dify's overwrite import, the app takes the file's name, description and icon.
        if adoptApp, !outcome.replayed { try await adoptAppSection(doc, of: root, by: principal.id) }
        return .replaced(ReplaceAnswer(head: outcome.head, ops: outcome.ops, nodes: outcome.doc.nodes.count, edges: outcome.doc.edges.count,
                                       next_cseq: outcome.nextCseq, replayed: outcome.replayed, status: checked.status.rawValue,
                                       imported_dsl_version: checked.version, current_dsl_version: DifyDSL.currentDSLVersion,
                                       renamed: .init(nodes: renamed?.nodes ?? [:], edges: renamed?.edges ?? [:])))
    }

    /// The current state as a Dify workflow file: YAML, or `?format=json`. Documents that were not imported get a
    /// minimal app skeleton. Secret environment variables are exported with `""` unless `?include_secret=true` (Dify's
    /// option of the same name): then with their stored plaintext (protocol 1.7), for the owner and admins only (1.8).
    private func exportDSL(_ req: Request, _ id: String) async throws -> Response {
        let p = try await authenticate(req)
        let q = query(req)
        let includeSecret = q["include_secret"] == "true"
        if includeSecret { try authorize(p, .privileged) }
        let (s, metadata, secrets) = try await exportParts(id, viewer: p.id, includeSecret: includeSecret)
        var headers = HTTPFields()
        if q["format"] == "json" {
            let v = try await agentExportValue(s.doc, metadata: metadata, secrets: secrets, app: id)
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(data: try WireJSON.encode(v)))
        }
        headers[.contentType] = "application/x-yaml; charset=utf-8"
        let yaml = try DifyDSL.encodeYAML(try await agentExportValue(s.doc, metadata: metadata, secrets: secrets, app: id))
        return Response(status: .ok, headers: headers, body: .init(data: Data(yaml.utf8)))
    }

    /// The Dify app metadata (mode, name, variables, features) without the graph; see `DifyDSL.appMeta`. Variables and
    /// features come from the document at head (protocol 1.7). Documents that were not imported get the same defaults as
    /// their export.
    private func appMeta(_ req: Request, _ id: String) async throws -> Response {
        let p = try await authenticate(req)
        try await requireDoc(id)
        let s = try await registry.sequencer(id).currentSnapshot()
        var meta = DifyDSL.appMeta(try await currentMetadata(id, viewer: p.id), document: s.doc)
        if case .map(var top) = meta, case .map(var a)? = top["app"],
           a["icon_type"] == .string("image"), case .string(let icon)? = a["icon"], let url = signedAvatar(icon) {
            a["icon_url"] = .string(url)
            top["app"] = .map(a)
            meta = .map(top)
        }
        return try json(meta)
    }

    /// Protocol 1.7: `POST /secrets` `{"value": "..."}` stores the plaintext of a secret environment variable and answers
    /// `201 {"ref": "sec-<32 hex>", "masked": "<Dify's mask>"}`. The client then writes the variable with ordinary item ops,
    /// with `value` = the mask and `secret_ref` = the reference; the plaintext never enters ops, the log or snapshots.
    private func storeSecret(_ req: Request, _ doc: String) async throws -> Response {
        _ = try await authenticate(req, .edit)
        struct SecretBody: Decodable { var value: String }
        let data = try await body(req)
        guard let value = (try? WireJSON.decode(SecretBody.self, from: data))?.value else {
            throw ServerError.badRequest("body must be {\"value\": string}")
        }
        try await requireDoc(doc)
        try requireSecretsKey()
        let ref = DifyDSL.newSecretRef()
        do { try await store.storeSecret(doc, ref: ref, value: value) } catch let e as SecretsKeyMissing { throw e } catch {
            throw ServerError.unavailable("\(error)")
        }
        struct Stored: Encodable { var ref: String; var masked: String }
        return try json(Stored(ref: ref, masked: DifyDSL.maskSecret(value)), status: .created)
    }

    private func docInfo(_ req: Request, _ id: String) async throws -> Response {
        _ = try await authenticate(req)
        let head = try await liveHead(id)
        struct Info: Encodable { var id: String; var head: Int }
        return try json(Info(id: id, head: head))
    }

    func requireDoc(_ doc: String) async throws { _ = try await liveHead(doc) }

    /// The head of a document: `404 not_found` if unknown, `404 app_deleted` if its app was deleted (protocol 1.10).
    func liveHead(_ doc: String) async throws -> Int {
        let status: DocumentStatus?
        do { status = try await store.documentStatus(doc) } catch { throw ServerError.unavailable("\(error)") }
        switch status {
        case .live(let head)?: return head
        case .deleted?: throw ServerError.appDeleted
        case nil: throw ServerError.notFound
        }
    }

    /// Hands out a fresh, unique client id (a UUID): the safe way to avoid two tabs/processes sharing one cseq stream.
    /// Protocol 1.8: the id belongs to the caller's account (ops under it from any other account are `403`). A `name` in the
    /// body (1.3) is ignored: names are the accounts' names.
    private func issueClientId(_ req: Request, _ doc: String) async throws -> Response {
        let p = try await authenticate(req)
        try await requireDoc(doc)
        let id = "s-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        _ = try await registry.sequencer(doc).bind(client: id, to: p.id)
        struct Issued: Encodable { var client: String; var account: String; var name: String }
        return try json(Issued(client: id, account: p.id, name: p.account.name), status: .created)
    }

    /// `PUT /clients/{client}` (1.3, kept for compatibility): since 1.8 it no longer names anything; it binds a client id
    /// the client chose itself to the caller's account (if nobody has it yet) and answers the account's name. `403` if the
    /// id belongs to another account. Any body is ignored.
    private func bindClient(_ req: Request, _ doc: String) async throws -> Response {
        let p = try await authenticate(req)
        guard let client = req.parameters.get("client"), Self.validClientId(client) else { throw ServerError.badRequest("invalid client id") }
        try await requireDoc(doc)
        try await requireOwnClient(doc, client, p, bindIfFree: true)
        struct Bound: Encodable { var client: String; var account: String; var name: String }
        return try json(Bound(client: client, account: p.id, name: p.account.name))
    }

    /// `403 forbidden` unless `client` belongs to the caller (an unbound id is bound to it with `bindIfFree`, else left alone).
    func requireOwnClient(_ doc: String, _ client: String, _ p: Principal, bindIfFree: Bool) async throws {
        let seqr = await registry.sequencer(doc)
        let owner = bindIfFree ? try await seqr.bind(client: client, to: p.id) : try await seqr.account(of: client)
        if let owner, owner != p.id {
            throw ServerError.http(status: 403, code: "forbidden", message: "client id \(client) belongs to another account")
        }
    }

    /// `GET /clients` (1.8): `{"clients": {"<client id>": {"account", "name", "avatar_url"?}}}` for every client id bound
    /// to an account.
    private func clientDirectory(_ req: Request, _ doc: String) async throws -> Response {
        _ = try await authenticate(req)
        try await requireDoc(doc)
        let dir = try await registry.sequencer(doc).clientDirectory(force: true)
        struct Entry: Encodable { var account: String; var name: String; var avatar_url: String? }
        struct Directory: Encodable { var clients: [String: Entry] }
        return try json(Directory(clients: dir.mapValues { Entry(account: $0.account, name: $0.name, avatar_url: signedAvatar($0.avatarUrl)) }))
    }

    private func snapshot(_ req: Request, _ id: String) async throws -> Response {
        _ = try await authenticate(req)
        let s = try await registry.sequencer(id).currentSnapshot()
        return try json(SnapshotResponse(seq: s.seq, doc: s.doc))
    }

    private func submit(_ req: Request, doc: String) async throws -> Response {
        let principal = try await authenticate(req, .edit)
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
        // 1.8: the whole batch is refused if the client id belongs to another account (the first use binds a free id).
        try await requireOwnClient(doc, parsed.client, principal, bindIfFree: true)
        let response = try await registry.sequencer(doc).submit(parsed)
        return try json(response)
    }

    private func events(_ req: Request, doc: String) async throws -> Response {
        let principal = try await authenticate(req, allowQuery: true)
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
        // The snapshot's `committed` map is about the client's own ops: only for its account (an unbound id is not bound).
        if let client { try await requireOwnClient(doc, client, principal, bindIfFree: false) }
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
