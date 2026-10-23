import CollabCore
import CollabDSL
import CollabModels
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// App detail pages (docs/protocol.md section 2, "App detail pages", protocol 1.11): Dify 1.17.1's console API for the
/// Access Point (`site.py`, `app.py` `site-enable` / `api-enable`, `apikey.py`), Annotations (`annotation.py`, `message.py`
/// `annotations/count`), publish and versions (`workflow.py`), and the Overview statistics and logs (`statistic.py`,
/// `workflow_statistic.py`, `workflow_app_log.py`, `conversation.py`, `message.py`, `workflow_run.py`), which answer Dify's
/// empty shapes until a runtime exists. Roles are Dify's community-edition decorators, quirks included.
extension Routes {
    func registerAppDetail(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        // Access Point.
        apps.post(":app", "site") { req in await handle(req) { try await updateSite(req) } }
        apps.post(":app", "site", "access-token-reset") { req in await handle(req) { try await resetSiteToken(req) } }
        apps.post(":app", "site-enable") { req in await handle(req) { try await setSwitch(req, api: false) } }
        apps.post(":app", "api-enable") { req in await handle(req) { try await setSwitch(req, api: true) } }
        apps.get(":app", "api-keys") { req in await handle(req) { try await listApiKeys(req) } }
        apps.post(":app", "api-keys") { req in await handle(req) { try await createApiKey(req) } }
        apps.delete(":app", "api-keys", ":key") { req in await handle(req) { try await deleteApiKey(req) } }
        // Annotations.
        apps.get(":app", "annotations") { req in await handle(req) { try await listAnnotations(req) } }
        apps.post(":app", "annotations") { req in await handle(req) { try await createAnnotation(req) } }
        apps.delete(":app", "annotations") { req in await handle(req) { try await deleteAnnotations(req) } }
        apps.get(":app", "annotations", "count") { req in await handle(req) { try await countAnnotations(req) } }
        apps.get(":app", "annotations", "export") { req in await handle(req) { try await exportAnnotations(req) } }
        apps.post(":app", "annotations", "batch-import") { req in await handle(req) { try await importAnnotations(req) } }
        apps.get(":app", "annotations", "batch-import-status", ":job") { req in await handle(req) { try await jobStatus(req, kind: "import") } }
        apps.post(":app", "annotations", ":annotation") { req in await handle(req) { try await updateAnnotation(req) } }
        apps.delete(":app", "annotations", ":annotation") { req in await handle(req) { try await deleteAnnotation(req) } }
        apps.get(":app", "annotations", ":annotation", "hit-histories") { req in await handle(req) { try await hitHistories(req) } }
        apps.get(":app", "annotation-setting") { req in await handle(req) { try await annotationSetting(req) } }
        apps.post(":app", "annotation-reply", ":action") { req in await handle(req) { try await annotationReply(req) } }
        apps.get(":app", "annotation-reply", ":action", "status", ":job") { req in
            await handle(req) { try await jobStatus(req, kind: try replyAction(req)) }
        }
        apps.post(":app", "annotation-settings", ":setting") { req in await handle(req) { try await updateAnnotationSetting(req) } }
        // Publish and versions.
        apps.get(":app", "workflows", "publish") { req in await handle(req) { try await publishedVersion(req) } }
        apps.post(":app", "workflows", "publish") { req in await handle(req) { try await publish(req) } }
        apps.get(":app", "workflows") { req in await handle(req) { try await listVersions(req) } }
        apps.get(":app", "workflows", ":version") { req in await handle(req) { try await getVersion(req) } }
        apps.patch(":app", "workflows", ":version") { req in await handle(req) { try await updateVersion(req) } }
        apps.delete(":app", "workflows", ":version") { req in await handle(req) { try await deleteVersion(req) } }
        apps.post(":app", "workflows", ":version", "restore") { req in await handle(req) { try await restoreVersion(req) } }
        // Overview statistics (empty until a runtime exists).
        for s in Self.statistics {
            let p = s.path.split(separator: "/").map(String.init)
            if p.count == 2 {
                apps.get(":app", "\(p[0])", "\(p[1])") { req in await handle(req) { try await statistic(req, s) } }
            } else {
                apps.get(":app", "\(p[0])", "\(p[1])", "\(p[2])") { req in await handle(req) { try await statistic(req, s) } }
            }
        }
        // Logs (empty until a runtime exists).
        apps.get(":app", "workflow-app-logs") { req in await handle(req) { try await workflowLogs(req) } }
        apps.get(":app", "workflow-runs", ":run") { req in await handle(req) { try await workflowRunDetail(req) } }
        apps.get(":app", "workflow-runs", ":run", "node-executions") { req in await handle(req) { try await workflowRunNodeExecutions(req) } }
        apps.get(":app", "chat-conversations") { req in await handle(req) { try await chatConversations(req) } }
        apps.get(":app", "chat-conversations", ":conversation") { req in await handle(req) { try await chatConversation(req) } }
        apps.get(":app", "chat-messages") { req in await handle(req) { try await chatMessages(req) } }
        apps.post(":app", "feedbacks") { req in await handle(req) { try await messageFeedback(req) } }
    }

    // MARK: - Plumbing

    /// The request's origin: `X-Forwarded-Proto` / `X-Forwarded-Host` (a proxy in front), else this server's own address.
    /// (The HTTP server does not pass the `Host` header on.)
    func requestOrigin(_ req: Request) -> String {
        let host = req.headers[HTTPField.Name("X-Forwarded-Host")!]?.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let host, !host.isEmpty {
            let proto = req.headers[HTTPField.Name("X-Forwarded-Proto")!]?.split(separator: ",").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? "http"
            return "\(proto)://\(host)"
        }
        let h = config.httpHost == "0.0.0.0" || config.httpHost == "::" || config.httpHost.isEmpty ? "localhost" : config.httpHost
        return "http://\(h):\(config.httpPort)"
    }

    /// Dify's `site.app_base_url` (`APP_WEB_URL` or the request's root), without a trailing `/`.
    func appBaseURL(_ req: Request) -> String {
        var s = config.webAppBaseURL.isEmpty ? requestOrigin(req) : config.webAppBaseURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Dify's `api_base_url` (`SERVICE_API_URL` or the request's root, normalised to end with `/v1`).
    func apiBaseURL(_ req: Request) -> String {
        var s = config.serviceAPIURL.isEmpty ? requestOrigin(req) : config.serviceAPIURL
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/v1"
    }

    /// Dify's site object (`AppDetailSiteResponse` / `AppSiteResponse` members) of app `a`, `null` if it has none.
    func siteJSON(_ a: StoredApp, req: Request) -> JSON {
        guard let text = a.siteJSON, var site = (try? JSONCoding.decode(Data(text.utf8)))?.object else { return .null }
        site["app_base_url"] = .string(appBaseURL(req))
        if site["icon_type"]?.string == "image" {
            site["icon_url"] = signedAvatar(site["icon"]?.string).map(JSON.string) ?? .null
        }
        return .object(site)
    }

    func notAllowedMode(_ modes: [String]) -> ServerError {
        // Dify's `get_app_model(mode=...)`: `AppNotFoundError(f"App mode is not in the supported list: {mode_values}")`.
        .http(status: 404, code: "app_not_found",
              message: "App mode is not in the supported list: {\(modes.map { "'\($0)'" }.joined(separator: ", "))}")
    }

    /// A live app of one of `modes` (else Dify's `404 app_not_found`).
    func appOfMode(_ req: Request, _ p: Principal, _ modes: [String]) async throws -> StoredApp {
        let a = try await liveApp(try appId(req), viewer: p.id)
        if !modes.contains(a.mode) { throw notAllowedMode(modes) }
        return a
    }

    func optionalBool(_ b: [String: JSON], _ key: String) throws -> Bool? {
        guard let v = b[key], !v.isNull else { return nil }
        guard let x = v.bool else { throw ServerError.badRequest("\(key) must be a boolean") }
        return x
    }

    /// An integer query parameter in `range` (else `400`), `def` when absent.
    func queryInt(_ q: [String: [String]], _ key: String, _ def: Int, _ range: ClosedRange<Int>) throws -> Int {
        guard let s = q[key]?.last, !s.isEmpty else { return def }
        guard let n = Int(s), range.contains(n) else {
            throw ServerError.badRequest("\(key) must be an integer in \(range.lowerBound)-\(range.upperBound)")
        }
        return n
    }

    func queryBool(_ q: [String: [String]], _ key: String) throws -> Bool {
        guard let s = q[key]?.last, !s.isEmpty else { return false }
        switch s.lowercased() {
        case "true", "1", "yes", "on", "t", "y": return true
        case "false", "0", "no", "off", "f", "n": return false
        default: throw ServerError.badRequest("\(key) must be a boolean")
        }
    }

    func pathId(_ req: Request, _ name: String, _ what: String) throws -> String {
        guard let id = req.parameters.get(name), Self.validDocId(id) else { throw ServerError.missing("\(what) not found") }
        return id
    }

    // MARK: - Access Point: site

    static func isHexColour(_ s: String) -> Bool {
        let hex = s.dropFirst()
        return s.hasPrefix("#") && (hex.count == 3 || hex.count == 6) && hex.allSatisfy(\.isHexDigit)
    }
    static let tokenStrategies = ["must", "allow", "not_allow"]

    /// `POST /v1/apps/{app}/site` (Dify's `AppSite.post`; owner, admin, editor).
    private func updateSite(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let id = try appId(req)
        let b = try await jsonBody(req)
        let current = try await liveApp(id, viewer: p.id)
        let oldSite = current.siteJSON.flatMap { (try? JSONCoding.decode(Data($0.utf8)))?.object } ?? [:]
        var c = SiteChanges()
        c.title = try optionalString(b, "title")
        c.iconType = try appIconType(b)
        c.icon = try optionalString(b, "icon")
        c.iconBackground = try optionalString(b, "icon_background")
        if (c.iconType ?? oldSite["icon_type"]?.string) == "image" {
            try await validateImageFile(c.icon ?? oldSite["icon"]?.string ?? "")
        }
        c.description = try optionalString(b, "description")
        c.defaultLanguage = try optionalString(b, "default_language")
        if let l = c.defaultLanguage, !SiteLanguages.all.contains(l) { throw ServerError.badRequest("\(l) is not a valid language.") }
        c.chatColorTheme = try optionalString(b, "chat_color_theme")
        if let t = c.chatColorTheme, !t.isEmpty, !Self.isHexColour(t) {
            throw ServerError.badRequest("chat_color_theme must be a colour like #1C64F2")
        }
        c.chatColorThemeInverted = try optionalBool(b, "chat_color_theme_inverted")
        c.customizeDomain = try optionalString(b, "customize_domain")
        c.copyright = try optionalString(b, "copyright")
        c.privacyPolicy = try optionalString(b, "privacy_policy")
        if let u = c.privacyPolicy, !u.isEmpty, !(u.hasPrefix("http://") || u.hasPrefix("https://")) {
            throw ServerError.badRequest("privacy_policy must be an http(s) URL")
        }
        c.inputPlaceholder = try optionalString(b, "input_placeholder")
        if let s = c.inputPlaceholder, s.count > 64 { throw ServerError.badRequest("input_placeholder must be at most 64 characters") }
        c.customDisclaimer = try optionalString(b, "custom_disclaimer")
        if let s = c.customDisclaimer, s.count > 512 { throw ServerError.badRequest("Custom disclaimer cannot exceed 512 characters.") }
        c.customizeTokenStrategy = try optionalString(b, "customize_token_strategy")
        if let s = c.customizeTokenStrategy, !Self.tokenStrategies.contains(s) {
            throw ServerError.badRequest("customize_token_strategy must be one of must, allow, not_allow")
        }
        c.promptPublic = try optionalBool(b, "prompt_public")
        c.showWorkflowSteps = try optionalBool(b, "show_workflow_steps")
        c.useIconAsAnswerIcon = try optionalBool(b, "use_icon_as_answer_icon")
        let ok: Bool
        do { ok = try await store.updateSite(id, c, by: p.id) } catch { throw ServerError.unavailable("\(error)") }
        let a = try await liveApp(id, viewer: p.id)
        if !ok { throw ServerError.missing("Site not found") }
        await announceAppChanged(id)
        return try json(siteJSON(a, req: req))
    }

    /// `POST /v1/apps/{app}/site/access-token-reset` (owner, admin).
    private func resetSiteToken(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        let id = try appId(req)
        let ok: Bool
        do { ok = try await store.resetSiteCode(id, by: p.id) } catch { throw ServerError.unavailable("\(error)") }
        let a = try await liveApp(id, viewer: p.id)
        if !ok { throw ServerError.missing("Site not found") }
        await announceAppChanged(id)
        return try json(siteJSON(a, req: req))
    }

    /// `POST /v1/apps/{app}/site-enable` (owner, admin, editor) and `/api-enable` (owner, admin) -> the app.
    private func setSwitch(_ req: Request, api: Bool) async throws -> Response {
        let p = try await authenticate(req, api ? .privileged : .edit)
        let id = try appId(req)
        let key = api ? "enable_api" : "enable_site"
        let b = try await jsonBody(req)
        guard let enabled = b[key]?.bool else { throw ServerError.badRequest("\(key) is required (a boolean)") }
        let outcome: SwitchOutcome
        do { outcome = try await store.setAppSwitch(id, api: api, enabled: enabled, by: p.id) } catch { throw ServerError.unavailable("\(error)") }
        switch outcome {
        case .missing: _ = try await liveApp(id, viewer: p.id)
        case .changed: await announceAppChanged(id)
        case .unchanged: break
        }
        return try await appDetail(id, p, req)
    }

    // MARK: - Access Point: Service API keys

    /// Dify's `BaseApiKeyListResource.max_keys`.
    static let maxApiKeys = 10

    func apiKeyJSON(_ k: StoredApiKey) -> JSON {
        .object(["id": .string(k.id), "type": "app", "token": .string(k.token ?? ""), "dataset_ids": .array([]),
                 "last_used_at": k.lastUsedAt.map { .int(Self.seconds($0)) } ?? .null, "created_at": .int(Self.seconds(k.createdAt))])
    }

    /// `GET /v1/apps/{app}/api-keys` (owner, admin, editor): the full keys (Dify does not mask app keys).
    private func listApiKeys(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await liveApp(try appId(req), viewer: p.id)
        let keys: [StoredApiKey]
        do { keys = try await store.apiKeys(a.id) } catch { throw ServerError.unavailable("\(error)") }
        return try json(JSON.object(["data": .array(keys.map(apiKeyJSON))]))
    }

    /// `POST /v1/apps/{app}/api-keys` (owner, admin, editor) -> `201` (Dify's `app-` + 24 letters and digits).
    private func createApiKey(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await liveApp(try appId(req), viewer: p.id)
        try requireSecretsKey()
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        let token = "app-" + String((0..<24).map { _ in letters[Int.random(in: 0..<letters.count, using: &rng)] })
        let keyId = UUID().uuidString.lowercased()
        let outcome: ApiKeyCreation
        do {
            outcome = try await store.createApiKey(a.id, id: keyId, token: token, tokenHash: Tokens.sha256(token), by: p.id, max: Self.maxApiKeys)
        } catch is SecretsKeyMissing { throw Self.secretsKeyMissing } catch { throw ServerError.unavailable("\(error)") }
        switch outcome {
        case .missing: _ = try await liveApp(a.id, viewer: p.id); throw ServerError.missing("App not found")
        case .limit:
            throw ServerError.http(status: 400, code: "max_keys_exceeded",
                                   message: "Cannot create more than \(Self.maxApiKeys) API keys for this resource type.")
        case .created(let at):
            return try json(apiKeyJSON(StoredApiKey(id: keyId, token: token, lastUsedAt: nil, createdAt: at)), status: .created)
        }
    }

    /// `DELETE /v1/apps/{app}/api-keys/{key}` -> `204`. Dify looks the app up first (`404`), then requires owner or admin
    /// (`403`, also for editors: the UI shows them the button).
    private func deleteApiKey(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let a = try await liveApp(try appId(req), viewer: p.id)
        try authorize(p, .privileged)
        let key = try pathId(req, "key", "API key")
        let ok: Bool
        do { ok = try await store.deleteApiKey(a.id, keyId: key) } catch { throw ServerError.unavailable("\(error)") }
        if !ok { throw ServerError.missing("API key not found") }
        return Response(status: .noContent)
    }

    // MARK: - Annotations

    /// Annotations exist for chatflows only (Dify's UI; dify-sf refuses workflow apps with Dify's wrong-mode error).
    func chatflow(_ req: Request, _ access: Access = .edit) async throws -> (Principal, StoredApp) {
        let p = try await authenticate(req, access)
        return (p, try await appOfMode(req, p, ["advanced-chat"]))
    }

    func annotationJSON(_ a: StoredAnnotation) -> JSON {
        .object(["id": .string(a.id), "question": .string(a.question), "answer": .string(a.answer), "hit_count": .int(a.hitCount),
                 "created_at": .int(Self.seconds(a.createdAt))])
    }

    /// `GET /v1/apps/{app}/annotations?page&limit&keyword`: Dify's `AnnotationList` (`has_more` = a full page, as Dify).
    private func listAnnotations(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let q = queryAll(req)
        let page = try queryInt(q, "page", 1, 1...Int(Int32.max)), limit = try queryInt(q, "limit", 20, 1...Int(Int32.max))
        let keyword = q["keyword"]?.last ?? ""
        // Dify's `paginate_query(..., max_per_page=100)`.
        let per = min(limit, 100)
        let result: (total: Int, rows: [StoredAnnotation])
        do { result = try await store.annotations(a.id, page: page, limit: per, keyword: keyword) } catch {
            throw ServerError.unavailable("\(error)")
        }
        return try json(JSON.object(["data": .array(result.rows.map(annotationJSON)), "has_more": .bool(result.rows.count == limit),
                                     "limit": .int(limit), "total": .int(result.total), "page": .int(page)]))
    }

    /// `GET /v1/apps/{app}/annotations/count` (any member, Dify's `MessageAnnotationCountApi`).
    private func countAnnotations(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req, .member)
        let n: Int
        do { n = try await store.annotationCount(a.id) } catch { throw ServerError.unavailable("\(error)") }
        return try json(JSON.object(["count": .int(n)]))
    }

    /// `GET /v1/apps/{app}/annotations/export`: every annotation (`{data}`), newest first.
    private func exportAnnotations(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let rows: [StoredAnnotation]
        do { rows = try await store.allAnnotations(a.id) } catch { throw ServerError.unavailable("\(error)") }
        return try json(JSON.object(["data": .array(rows.map(annotationJSON))]))
    }

    /// `POST /v1/apps/{app}/annotations` (Dify's `up_insert_app_annotation_from_message` without a message) -> `201`.
    private func createAnnotation(_ req: Request) async throws -> Response {
        let (p, a) = try await chatflow(req)
        let b = try await jsonBody(req)
        let answer = try optionalString(b, "answer").flatMap { $0.isEmpty ? nil : $0 } ?? (try optionalString(b, "content"))
        guard let answer, !answer.isEmpty else { throw ServerError.badRequest("Either 'answer' or 'content' must be provided") }
        if let m = try optionalString(b, "message_id"), !m.isEmpty {
            // No runtime, no messages.
            throw ServerError.missing("Message Not Exists.")
        }
        guard let question = try optionalString(b, "question"), !question.isEmpty else {
            throw ServerError.badRequest("'question' is required when 'message_id' is not provided")
        }
        let rows: [StoredAnnotation]
        do {
            rows = try await store.insertAnnotations(a.id, [(id: UUID().uuidString.lowercased(), question: question, answer: answer)], account: p.id)
        } catch { throw ServerError.unavailable("\(error)") }
        guard let row = rows.first else { throw ServerError.internalError("annotation insert returned nothing") }
        return try json(annotationJSON(row), status: .created)
    }

    /// `POST /v1/apps/{app}/annotations/{annotation}` `{question, answer}` (both required, as Dify).
    private func updateAnnotation(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let id = try pathId(req, "annotation", "Annotation")
        let b = try await jsonBody(req)
        let existing: StoredAnnotation?
        do { existing = try await store.annotation(a.id, id: id) } catch { throw ServerError.unavailable("\(error)") }
        guard existing != nil else { throw ServerError.missing("Annotation not found") }
        guard let question = try optionalString(b, "question"), !question.isEmpty else { throw ServerError.badRequest("'question' is required") }
        guard let answer = try optionalString(b, "answer"), !answer.isEmpty else { throw ServerError.badRequest("'answer' is required") }
        let row: StoredAnnotation?
        do { row = try await store.updateAnnotation(a.id, id: id, question: question, answer: answer) } catch {
            throw ServerError.unavailable("\(error)")
        }
        guard let row else { throw ServerError.missing("Annotation not found") }
        return try json(annotationJSON(row))
    }

    /// `DELETE /v1/apps/{app}/annotations/{annotation}` -> `204`.
    private func deleteAnnotation(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let id = try pathId(req, "annotation", "Annotation")
        let n: Int
        do { n = try await store.deleteAnnotations(a.id, ids: [id]) } catch { throw ServerError.unavailable("\(error)") }
        if n == 0 { throw ServerError.missing("Annotation not found") }
        return Response(status: .noContent)
    }

    /// `DELETE /v1/apps/{app}/annotations?annotation_id=...` (the given ones; unknown ids are ignored) or without ids (all).
    private func deleteAnnotations(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let ids = queryAll(req)["annotation_id"] ?? []
        if !ids.isEmpty, ids.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ServerError.badRequest("annotation_ids are required if the parameter is provided.")
        }
        do { try await store.deleteAnnotations(a.id, ids: ids.isEmpty ? nil : ids) } catch { throw ServerError.unavailable("\(error)") }
        return Response(status: .noContent)
    }

    /// Dify's `ANNOTATION_IMPORT_FILE_SIZE_LIMIT` (2 MB), `ANNOTATION_IMPORT_MAX_RECORDS`, `ANNOTATION_IMPORT_MIN_RECORDS`.
    static let annotationImportMaxBytes = 2 << 20
    static let annotationImportMaxRecords = 10_000
    static let annotationImportMinRecords = 1

    /// `POST /v1/apps/{app}/annotations/batch-import` (multipart `file`): Dify's checks and messages; the rows are stored at
    /// once (the job is `completed` when polled). A refused file is `200 {error_msg}`, as in Dify.
    private func importAnnotations(_ req: Request) async throws -> Response {
        let (p, a) = try await chatflow(req)
        let data: Data
        do { data = try await req.body.collect(max: .specified(ByteCount(value: Self.annotationImportMaxBytes + (64 << 10)))) ?? Data() } catch {
            throw ServerError.http(status: 413, code: "payload_too_large",
                                   message: "File size exceeds maximum limit of 2MB. Please reduce the file size and try again.")
        }
        let files = Multipart.files(data, contentType: req.headers[.contentType])
        guard let file = files.first(where: { $0.name == "file" }) else {
            throw ServerError.http(status: 400, code: "no_file_uploaded", message: "Please upload your file.")
        }
        if files.count > 1 { throw ServerError.http(status: 400, code: "too_many_files", message: "Only one file is allowed.") }
        guard let filename = file.filename, filename.lowercased().hasSuffix(".csv") else {
            throw ServerError.badRequest("Invalid file type. Only CSV files are allowed")
        }
        if file.data.count > Self.annotationImportMaxBytes {
            throw ServerError.http(status: 413, code: "payload_too_large",
                                   message: "File size exceeds maximum limit of 2MB. Please reduce the file size and try again.")
        }
        if file.data.isEmpty { throw ServerError.badRequest("The uploaded file is empty") }
        let parsed = AnnotationCSV.parse(file.data, maxRecords: Self.annotationImportMaxRecords, minRecords: Self.annotationImportMinRecords)
        if let error = parsed.error { return try json(JSON.object(["error_msg": .string(error)])) }
        let job = UUID().uuidString.lowercased()
        do {
            try await store.insertAnnotations(a.id, parsed.rows.map { (id: UUID().uuidString.lowercased(), question: $0.question, answer: $0.answer) },
                                              account: p.id)
            try await store.recordJob(job, doc: a.id, kind: "import", status: "completed")
        } catch { throw ServerError.unavailable("\(error)") }
        return try json(JSON.object(["job_id": .string(job), "job_status": "waiting", "record_count": .int(parsed.rows.count)]))
    }

    func replyAction(_ req: Request) throws -> String {
        guard let a = req.parameters.get("action"), a == "enable" || a == "disable" else { throw ServerError.missing("Not Found") }
        return a
    }

    /// `GET .../annotations/batch-import-status/{job}` and `.../annotation-reply/{action}/status/{job}`.
    private func jobStatus(_ req: Request, kind: String) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let id = try pathId(req, "job", "Job")
        let job: (status: String, error: String)?
        do { job = try await store.job(id, doc: a.id, kind: kind) } catch { throw ServerError.unavailable("\(error)") }
        guard let job else { throw ServerError.badRequest("The job does not exist.") }
        return try json(JSON.object(["job_id": .string(id), "job_status": .string(job.status), "error_msg": .string(job.error)]))
    }

    func settingJSON(_ s: StoredAnnotationSetting?) -> JSON {
        guard let s else { return .object(["enabled": .bool(false)]) }
        return .object(["id": .string(s.id), "enabled": .bool(true), "score_threshold": .double(s.scoreThreshold),
                        "embedding_model": .object(["embedding_provider_name": .string(s.embeddingProviderName),
                                                    "embedding_model_name": .string(s.embeddingModelName)])])
    }

    /// `GET /v1/apps/{app}/annotation-setting`.
    private func annotationSetting(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        do { return try json(settingJSON(try await store.annotationSetting(a.id))) } catch let e as ServerError { throw e } catch {
            throw ServerError.unavailable("\(error)")
        }
    }

    /// `POST /v1/apps/{app}/annotation-reply/{enable|disable}`: the setting is stored at once (no embeddings: no runtime);
    /// Dify's job answer (`waiting`; `completed` when polled).
    private func annotationReply(_ req: Request) async throws -> Response {
        let (p, a) = try await chatflow(req)
        let action = try replyAction(req)
        let data = try await body(req)
        let b = data.isEmpty ? [:] : ((try? JSONCoding.decode(data))?.object ?? [:])
        let job = UUID().uuidString.lowercased()
        do {
            if action == "enable" {
                guard let score = b["score_threshold"]?.double else { throw ServerError.badRequest("score_threshold is required (a number)") }
                guard let provider = b["embedding_provider_name"]?.string, !provider.isEmpty else {
                    throw ServerError.badRequest("embedding_provider_name is required")
                }
                guard let model = b["embedding_model_name"]?.string, !model.isEmpty else {
                    throw ServerError.badRequest("embedding_model_name is required")
                }
                try await store.enableAnnotationReply(a.id, newId: UUID().uuidString.lowercased(), scoreThreshold: score, provider: provider,
                                                      model: model, by: p.id)
            } else {
                try await store.disableAnnotationReply(a.id)
            }
            try await store.recordJob(job, doc: a.id, kind: action, status: "completed")
        } catch let e as ServerError { throw e } catch { throw ServerError.unavailable("\(error)") }
        return try json(JSON.object(["job_id": .string(job), "job_status": "waiting"]))
    }

    /// `POST /v1/apps/{app}/annotation-settings/{setting}` `{score_threshold}`.
    private func updateAnnotationSetting(_ req: Request) async throws -> Response {
        let (p, a) = try await chatflow(req)
        let id = try pathId(req, "setting", "App annotation")
        let b = try await jsonBody(req)
        guard let score = b["score_threshold"]?.double else { throw ServerError.badRequest("score_threshold is required (a number)") }
        let s: StoredAnnotationSetting?
        do { s = try await store.updateAnnotationScore(a.id, settingId: id, scoreThreshold: score, by: p.id) } catch {
            throw ServerError.unavailable("\(error)")
        }
        guard let s else { throw ServerError.missing("App annotation not found") }
        return try json(settingJSON(s))
    }

    /// `GET /v1/apps/{app}/annotations/{annotation}/hit-histories`: always empty (hits come from a runtime).
    private func hitHistories(_ req: Request) async throws -> Response {
        let (_, a) = try await chatflow(req)
        let id = try pathId(req, "annotation", "Annotation")
        let q = queryAll(req)
        let page = Int(q["page"]?.last ?? "") ?? 1, limit = Int(q["limit"]?.last ?? "") ?? 20
        let existing: StoredAnnotation?
        do { existing = try await store.annotation(a.id, id: id) } catch { throw ServerError.unavailable("\(error)") }
        guard existing != nil else { throw ServerError.missing("Annotation not found") }
        return try json(JSON.object(["data": .array([]), "has_more": .bool(limit == 0), "limit": .int(limit), "total": 0, "page": .int(page)]))
    }

    // MARK: - Publish and versions

    static let workflowModes = ["advanced-chat", "workflow"]

    /// Dify's `WorkflowResponse` of the document `doc` with metadata `metadata`: graph, features and variables as the export
    /// renders them (secret values `""`).
    func workflowJSON(id: String, doc: Document, metadata: Value, fields: [String: JSON]) throws -> JSON {
        let exported = try DifyDSL.exportValue(doc, metadata: metadata, secrets: nil)
        let j = try JSONCoding.decode(try WireJSON.encode(exported))
        let w = j["workflow"]?.object ?? [:]
        var out = fields
        out["id"] = .string(id)
        out["graph"] = w["graph"] ?? .object([:])
        out["features"] = w["features"] ?? .object([:])
        out["hash"] = .string(try Self.graphHash(w))
        out["tool_published"] = .bool(false)
        out["environment_variables"] = w["environment_variables"] ?? .array([])
        out["conversation_variables"] = w["conversation_variables"] ?? .array([])
        out["rag_pipeline_variables"] = .array([])
        return .object(out)
    }

    /// SHA-256 of the graph and features (Dify's `unique_hash`).
    static func graphHash(_ workflow: [String: JSON]) throws -> String {
        let canonical = try JSONCoding.encode(JSON.object(["graph": workflow["graph"] ?? .null, "features": workflow["features"] ?? .null]))
        return Tokens.sha256(String(decoding: canonical, as: UTF8.self))
    }

    func accountJSON(_ a: StoredVersion.Account?) -> JSON {
        guard let a else { return .null }
        return .object(["id": .string(a.id), "name": .string(a.name), "email": .string(a.email)])
    }

    func versionJSON(_ v: StoredVersion) throws -> JSON {
        let doc = try WireJSON.decode(Document.self, from: v.state)
        let metadata = try WireJSON.decode(Value.self, from: v.dsl)
        return try workflowJSON(id: v.id, doc: doc, metadata: metadata, fields: [
            "version": .string(v.version), "version_number": .int(v.number), "marked_name": .string(v.markedName),
            "marked_comment": .string(v.markedComment), "created_by": accountJSON(v.createdBy), "created_at": .int(Self.seconds(v.createdAt)),
            "updated_by": accountJSON(v.updatedBy), "updated_at": .int(Self.seconds(v.updatedAt)),
        ])
    }

    /// The draft (the document at head) as Dify's draft `WorkflowResponse`; its id is the app id.
    func draftJSON(_ a: StoredApp) async throws -> JSON {
        let s = try await registry.sequencer(a.id).currentSnapshot()
        let metadata = try await currentMetadata(a.id, viewer: "")
        func account(_ id: String?) async -> JSON {
            guard let id, let acc = try? await store.account(id: id) else { return .null }
            return .object(["id": .string(acc.id), "name": .string(acc.name), "email": .string(acc.email)])
        }
        return try workflowJSON(id: a.id, doc: s.doc, metadata: metadata, fields: [
            "version": "draft", "version_number": .null, "marked_name": "", "marked_comment": "",
            "created_by": await account(a.createdBy), "created_at": .int(Self.seconds(a.createdAt)),
            "updated_by": await account(a.updatedBy ?? a.createdBy), "updated_at": .int(Self.seconds(a.updatedAt)),
        ])
    }

    /// `GET /v1/apps/{app}/workflows/publish` (owner, admin, editor): the published version, or `null` (never published).
    private func publishedVersion(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let v: StoredVersion?
        do { v = try await store.latestVersion(a.id) } catch { throw ServerError.unavailable("\(error)") }
        guard let v else { return try json(JSON.null) }
        return try json(try versionJSON(v))
    }

    func versionNameAndComment(_ b: [String: JSON]) throws -> (String?, String?) {
        let name = try optionalString(b, "marked_name"), comment = try optionalString(b, "marked_comment")
        if let name, name.count > 20 { throw ServerError.badRequest("marked_name must be at most 20 characters") }
        if let comment, comment.count > 100 { throw ServerError.badRequest("marked_comment must be at most 100 characters") }
        return (name, comment)
    }

    /// `POST /v1/apps/{app}/workflows/publish` `{marked_name?, marked_comment?}` (owner, admin, editor): a new version of the
    /// document at head -> `{result: "success", created_at}`.
    private func publish(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let data = try await body(req)
        let b = data.isEmpty ? [:] : ((try? JSONCoding.decode(data))?.object ?? [:])
        let (name, comment) = try versionNameAndComment(b)
        let s = try await registry.sequencer(a.id).currentSnapshot()
        let metadata = try await currentMetadata(a.id, viewer: p.id)
        let exported = try JSONCoding.decode(try WireJSON.encode(try DifyDSL.exportValue(s.doc, metadata: metadata, secrets: nil)))
        let hash = try Self.graphHash(exported["workflow"]?.object ?? [:])
        let v: StoredVersion?
        do {
            v = try await store.publishVersion(a.id, id: UUID().uuidString.lowercased(), seq: s.seq, state: try WireJSON.encodeString(s.doc),
                                               dsl: try WireJSON.encodeString(metadata), hash: hash, markedName: name ?? "",
                                               markedComment: comment ?? "", by: p.id)
        } catch { throw ServerError.unavailable("\(error)") }
        guard let v else { _ = try await liveApp(a.id, viewer: p.id); throw ServerError.missing("App not found") }
        // The app's `updated_by` / `updated_at` changed.
        await announceAppChanged(a.id)
        return try json(JSON.object(["result": "success", "created_at": .int(Self.seconds(v.createdAt))]))
    }

    /// `GET /v1/apps/{app}/workflows?page&limit&user_id&named_only` (owner, admin, editor): Dify's
    /// `WorkflowPaginationResponse`: the draft first, then the versions newest first; nothing before the first publish.
    private func listVersions(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let q = queryAll(req)
        let page = try queryInt(q, "page", 1, 1...99999), limit = try queryInt(q, "limit", 10, 1...100)
        let userId = q["user_id"]?.last.flatMap { $0.isEmpty ? nil : $0 }
        let namedOnly = try queryBool(q, "named_only")
        if let userId, userId != p.id { throw ServerError.http(status: 403, code: "forbidden", message: "user_id must be your own account id") }
        func answer(_ items: [JSON], _ more: Bool) throws -> Response {
            try json(JSON.object(["items": .array(items), "page": .int(page), "limit": .int(limit), "has_more": .bool(more)]))
        }
        let latest: StoredVersion?
        do { latest = try await store.latestVersion(a.id) } catch { throw ServerError.unavailable("\(error)") }
        guard latest != nil else { return try answer([], false) }
        // Dify's filters apply to the draft too: it is the app creator's and has no name.
        let withDraft = !namedOnly && (userId == nil || userId == a.createdBy)
        let d = withDraft ? 1 : 0
        let start = (page - 1) * limit
        let from = max(0, start - d), count = start + limit - d - from
        let rows: [StoredVersion]
        do { rows = try await store.versions(a.id, offset: from, limit: count + 1, createdBy: userId, namedOnly: namedOnly) } catch {
            throw ServerError.unavailable("\(error)")
        }
        var items: [JSON] = []
        if withDraft && start == 0 { items.append(try await draftJSON(a)) }
        for v in rows.prefix(count) { items.append(try versionJSON(v)) }
        return try answer(items, rows.count > count)
    }

    /// `GET /v1/apps/{app}/workflows/{version}` (edit; dify-sf only, Dify has no such read): the version (or, with the app id,
    /// the draft) as Dify's `WorkflowResponse` plus `doc`, the document in the snapshot format (section 3), so a client can
    /// render it without reading Dify files.
    private func getVersion(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let id = try pathId(req, "version", "Workflow")
        if id == a.id {
            let s = try await registry.sequencer(a.id).currentSnapshot()
            guard var out = try await draftJSON(a).object else { throw ServerError.internalError("draft") }
            out["doc"] = try JSONCoding.decode(try WireJSON.encode(s.doc))
            return try json(JSON.object(out))
        }
        let v: StoredVersion?
        do { v = try await store.version(a.id, id: id) } catch { throw ServerError.unavailable("\(error)") }
        guard let v, var out = try versionJSON(v).object else { throw ServerError.missing("Workflow not found") }
        out["doc"] = try JSONCoding.decode(Data(v.state.utf8))
        return try json(JSON.object(out))
    }

    /// The Dify file of version `versionId` of app `a` (Dify's `export_dsl(workflow_id=...)`): the version's graph, features
    /// and variables under the app's current `app` section. nil for an unknown version.
    func versionExportYAML(_ a: StoredApp, versionId: String, includeSecret: Bool) async throws -> String? {
        let v: StoredVersion?
        do { v = try await store.version(a.id, id: versionId) } catch { throw ServerError.unavailable("\(error)") }
        guard let v else { return nil }
        var secrets: [String: String]?
        if includeSecret {
            do { secrets = try await store.secrets(a.id) } catch { throw ServerError.unavailable("\(error)") }
        }
        let metadata = Self.overlayingAppRow(try WireJSON.decode(Value.self, from: v.dsl), a, fallbackName: a.id)
        return try DifyDSL.exportYAML(try WireJSON.decode(Document.self, from: v.state), metadata: metadata, secrets: secrets)
    }

    /// `PATCH /v1/apps/{app}/workflows/{version}` `{marked_name?, marked_comment?}` -> the version.
    private func updateVersion(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let id = try pathId(req, "version", "Workflow")
        let b = try await jsonBody(req)
        let (name, comment) = try versionNameAndComment(b)
        if name == nil && comment == nil { throw ServerError.badRequest("No valid fields to update") }
        let v: StoredVersion?
        do { v = try await store.updateVersion(a.id, id: id, markedName: name, markedComment: comment, by: p.id) } catch {
            throw ServerError.unavailable("\(error)")
        }
        guard let v else { throw ServerError.missing("Workflow not found") }
        return try json(try versionJSON(v))
    }

    /// `DELETE /v1/apps/{app}/workflows/{version}` -> `204`; not the draft, not the published version (Dify's messages).
    private func deleteVersion(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let id = try pathId(req, "version", "Workflow")
        if id == a.id { throw ServerError.badRequest("Cannot delete draft workflow versions") }
        let outcome: VersionDeletion
        do { outcome = try await store.deleteVersion(a.id, id: id) } catch { throw ServerError.unavailable("\(error)") }
        switch outcome {
        case .deleted: return Response(status: .noContent)
        case .missing: throw ServerError.missing("Workflow with ID \(id) not found")
        case .inUse: throw ServerError.badRequest("Cannot delete workflow that is currently in use by app '\(a.id)'")
        }
    }

    /// `POST /v1/apps/{app}/workflows/{version}/restore` `{client, cseq, confirm?}`: the version replaces the draft through the
    /// replacement path (`POST /replace`'s rules and answer; the version's secrets stay on the server), plus Dify's
    /// `{result, hash, updated_at}`. The app's name and icon and its published version are unchanged (as Dify).
    private func restoreVersion(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let id = try pathId(req, "version", "Workflow")
        let b = try await jsonBody(req)
        guard let client = b["client"]?.string, Self.validClientId(client) else {
            throw ServerError.badRequest("client (the caller's client id) is required")
        }
        guard let cseq = b["cseq"]?.int, cseq >= 1 else { throw ServerError.badRequest("cseq (the client's next cseq, >= 1) is required") }
        let confirm = b["confirm"]?.bool ?? false
        if id == a.id { throw ServerError.badRequest("source workflow must be published") }
        let v: StoredVersion?
        do { v = try await store.version(a.id, id: id) } catch { throw ServerError.unavailable("\(error)") }
        guard let v else { throw ServerError.missing("Workflow not found.") }
        try await requireOwnClient(a.id, client, p, bindIfFree: true)
        let secrets: [String: String]
        do { secrets = try await store.secrets(a.id) } catch { throw ServerError.unavailable("\(error)") }
        let root = try DifyDSL.exportValue(try WireJSON.decode(Document.self, from: v.state), metadata: try WireJSON.decode(Value.self, from: v.dsl),
                                           secrets: secrets)
        switch try await replaceDocument(a.id, with: root, principal: p, client: client, cseq: cseq, confirm: confirm, adoptApp: false) {
        case .pending(let response): return response
        case .replaced(let answer):
            guard var out = try JSONCoding.decode(try WireJSON.encode(answer)).object else { throw ServerError.internalError("restore answer") }
            out["result"] = "success"
            out["hash"] = .string(v.hash)
            out["updated_at"] = .int(Self.seconds(Date()))
            return try json(JSON.object(out))
        }
    }

    // MARK: - Overview statistics

    struct Statistic: Sendable {
        var path: String
        /// nil = every mode.
        var modes: [String]?
    }

    /// Dify's statistic endpoints (`statistic.py`, `workflow_statistic.py`) and their modes.
    static let statistics: [Statistic] = [
        .init(path: "statistics/daily-messages", modes: nil),
        .init(path: "statistics/daily-conversations", modes: nil),
        .init(path: "statistics/daily-end-users", modes: nil),
        .init(path: "statistics/token-costs", modes: nil),
        .init(path: "statistics/average-session-interactions", modes: ["chat", "agent-chat", "advanced-chat", "agent"]),
        .init(path: "statistics/user-satisfaction-rate", modes: nil),
        .init(path: "statistics/average-response-time", modes: ["completion"]),
        .init(path: "statistics/tokens-per-second", modes: nil),
        .init(path: "workflow/statistics/daily-conversations", modes: nil),
        .init(path: "workflow/statistics/daily-terminals", modes: nil),
        .init(path: "workflow/statistics/token-costs", modes: nil),
        .init(path: "workflow/statistics/average-app-interactions", modes: ["workflow"]),
    ]

    /// Dify's `parse_time_range` format check (`YYYY-MM-DD HH:MM`) and order.
    func timeRange(_ q: [String: [String]]) throws {
        func parse(_ key: String) throws -> Date? {
            guard let s = q[key]?.last, !s.isEmpty else { return nil }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard s.wholeMatch(of: #/\d{4}-\d{1,2}-\d{1,2} \d{1,2}:\d{1,2}/#) != nil, let d = f.date(from: s) else {
                throw ServerError.badRequest("Invalid \(key) time format: time data '\(s)' does not match format '%Y-%m-%d %H:%M'")
            }
            return d
        }
        let start = try parse("start"), end = try parse("end")
        if let start, let end, start > end { throw ServerError.badRequest("start must be earlier than or equal to end") }
    }

    /// Any member (Dify: `app.acl.monitor`, not enforced without RBAC): `{data: []}`.
    private func statistic(_ req: Request, _ s: Statistic) async throws -> Response {
        let p = try await authenticate(req)
        let a = try await liveApp(try appId(req), viewer: p.id)
        if let modes = s.modes, !modes.contains(a.mode) { throw notAllowedMode(modes) }
        try timeRange(queryAll(req))
        return try json(JSON.object(["data": .array([])]))
    }

    // MARK: - Logs

    static let runStatuses = ["running", "succeeded", "failed", "stopped", "partial-succeeded", "paused"]

    /// `GET /v1/apps/{app}/workflow-app-logs` (any member; workflow apps): an empty page.
    private func workflowLogs(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        _ = try await appOfMode(req, p, ["workflow"])
        let q = queryAll(req)
        let page = try queryInt(q, "page", 1, 1...99999), limit = try queryInt(q, "limit", 20, 1...100)
        if let s = q["status"]?.last, !s.isEmpty, !Self.runStatuses.contains(s) {
            throw ServerError.badRequest("status must be one of \(Self.runStatuses.joined(separator: ", "))")
        }
        _ = try queryBool(q, "detail")
        for key in ["created_at__before", "created_at__after"] {
            if let s = q[key]?.last, !s.isEmpty,
               s.wholeMatch(of: #/\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([+-]\d{2}:?\d{2}|Z)?)?/#) == nil {
                throw ServerError.badRequest("\(key) must be an ISO 8601 time")
            }
        }
        return try json(JSON.object(["page": .int(page), "limit": .int(limit), "total": 0, "has_more": false, "data": .array([])]))
    }

    static let chatModes = ["chat", "agent-chat", "advanced-chat", "agent"]

    /// `GET /v1/apps/{app}/chat-conversations` (owner, admin, editor; chat apps): an empty page.
    private func chatConversations(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        _ = try await appOfMode(req, p, Self.chatModes)
        let q = queryAll(req)
        let page = try queryInt(q, "page", 1, 1...99999), limit = try queryInt(q, "limit", 20, 1...100)
        if let s = q["annotation_status"]?.last, !s.isEmpty, !["annotated", "not_annotated", "all"].contains(s) {
            throw ServerError.badRequest("annotation_status must be one of annotated, not_annotated, all")
        }
        if let s = q["sort_by"]?.last, !s.isEmpty, !["created_at", "-created_at", "updated_at", "-updated_at"].contains(s) {
            throw ServerError.badRequest("sort_by must be one of created_at, -created_at, updated_at, -updated_at")
        }
        try timeRange(q)
        return try json(JSON.object(["page": .int(page), "limit": .int(limit), "total": 0, "has_more": false, "data": .array([])]))
    }

    /// `GET /v1/apps/{app}/chat-conversations/{conversation}` (owner, admin, editor): no conversations yet -> `404`.
    private func chatConversation(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        _ = try await appOfMode(req, p, Self.chatModes)
        throw ServerError.missing("Conversation Not Exists.")
    }

    /// `GET /v1/apps/{app}/chat-messages?conversation_id` (owner, admin, editor): no conversations yet -> `404`.
    private func chatMessages(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.chatModes)
        guard let id = queryAll(req)["conversation_id"]?.last, !id.isEmpty else { throw ServerError.badRequest("conversation_id is required") }
        guard try await store.chatConversation(doc: a.id, id: id, account: p.id) != nil else { throw ServerError.missing("Conversation Not Exists.") }
        let messages = try await store.chatMessages(doc: a.id, conversation: id, account: p.id)
        return await fileJSONResponse(["data": .array(messages.reversed().map(Self.chatMessageJSON)), "has_more": false, "limit": 500], userId: p.id)
    }

    /// Python's `uuid.UUID(s)` for the usual spellings (hyphenated or 32 hex digits, any case); nil otherwise.
    static func parseUUID(_ s: String) -> UUID? {
        if let u = UUID(uuidString: s) { return u }
        guard s.count == 32, s.allSatisfy(\.isHexDigit) else { return nil }
        let h = Array(s)
        return UUID(uuidString: String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-"
                    + String(h[20...]))
    }

    /// `POST /v1/apps/{app}/feedbacks` `{message_id, rating: "like"|"dislike"|null, content?}` (any member, every mode; Dify's
    /// `MessageFeedbackApi`): the member's (admin) like or dislike of a message in the logs -> `{result: "success"}`.
    private func messageFeedback(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let a = try await liveApp(try appId(req), viewer: p.id)
        let b = try await jsonBody(req)
        guard let raw = b["message_id"]?.string else { throw ServerError.badRequest("message_id is required") }
        guard let message = Self.parseUUID(raw) else { throw ServerError.badRequest("\(raw) is not a valid uuid.") }
        let rating = try optionalString(b, "rating")
        if let rating, rating != "like" && rating != "dislike" { throw ServerError.badRequest("rating must be one of like, dislike or null") }
        let content = try optionalString(b, "content")
        let outcome: AdminFeedbackOutcome
        do { outcome = try await store.setAdminFeedback(a.id, message: message, rating: rating, content: content, account: p.id) } catch {
            throw ServerError.unavailable("\(error)")
        }
        switch outcome {
        case .noMessage: throw ServerError.missing("Message Not Exists.")
        case .nothingToClear: throw ServerError.badRequest("rating cannot be None when feedback not exists")
        case .created, .updated, .deleted: return try json(JSON.object(["result": "success"]))
        }
    }
}

/// Dify's annotation CSV import (`AppAnnotationService.batch_import_app_annotations`, pandas `read_csv` with a header row):
/// the first two columns are question and answer (stripped; rows with an empty or `nan` value are skipped; rows with more
/// fields than the header are skipped, pandas' `on_bad_lines="skip"`), question at most 2000 and answer at most 10000
/// characters. Refusals carry Dify's messages.
enum AnnotationCSV {
    static func parse(_ data: Data, maxRecords: Int, minRecords: Int) -> (rows: [(question: String, answer: String)], error: String?) {
        if !data.prefix(8192).contains(10) { return ([], "The CSV file appears to be empty or invalid.") }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let records = Self.records(text)
        guard let header = records.first, header.count >= 2 else {
            return ([], "Invalid CSV format. The file must contain at least 2 columns (question and answer).")
        }
        var out: [(question: String, answer: String)] = []
        for (i, r) in records.enumerated().dropFirst() {
            if r.count > header.count { continue }
            if out.count >= maxRecords {
                return ([], "The CSV file contains too many records. Maximum \(maxRecords) records allowed per import. "
                            + "Please split your file into smaller batches.")
            }
            let q = r.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let a = r.count > 1 ? r[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if q.isEmpty || a.isEmpty || q.lowercased() == "nan" || a.lowercased() == "nan" { continue }
            let row = i + 1
            if q.count > 2000 { return ([], "Question at row \(row) is too long. Maximum 2000 characters allowed.") }
            if a.count > 10000 { return ([], "Answer at row \(row) is too long. Maximum 10000 characters allowed.") }
            out.append((q, a))
        }
        if out.count < minRecords {
            return ([], "The CSV file must contain at least \(minRecords) valid annotation record(s). Found \(out.count) valid record(s).")
        }
        return (out, nil)
    }

    /// RFC 4180 records: quoted fields (doubled quotes, line breaks inside), `\n` or `\r\n`; blank lines skipped.
    static func records(_ text: String) -> [[String]] {
        var out: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false, any = false
        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty && !any) { out.append(row) }
            row = []
            any = false
        }
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" {
                quoted = true; any = true
            } else if c == "," {
                endField(); any = true
            } else if c == "\n" || c == "\r" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.unicodeScalars.append(c); any = true
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || any { endRow() }
        return out
    }
}

/// A minimal `multipart/form-data` reader (the annotation CSV upload).
enum Multipart {
    struct Part { var name: String; var filename: String?; var data: Data }

    /// The parts of `body` that are files (have a `filename`) or fields, by the boundary in `contentType`.
    static func files(_ body: Data, contentType: String?) -> [Part] {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else { return [] }
        var boundary: String?
        for p in contentType.split(separator: ";").dropFirst() {
            let kv = p.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0].lowercased() == "boundary" { boundary = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        guard let boundary, !boundary.isEmpty else { return [] }
        let delimiter = Data("--\(boundary)".utf8)
        let bytes = [UInt8](body)
        let d = [UInt8](delimiter)
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard needle.count <= bytes.count, from <= bytes.count - needle.count else { return nil }
            var i = from
            while i <= bytes.count - needle.count {
                if bytes[i] == needle[0] && Array(bytes[i..<i + needle.count]) == needle { return i }
                i += 1
            }
            return nil
        }
        var parts: [Part] = []
        guard var at = find(d, from: 0) else { return [] }
        while true {
            var start = at + d.count
            // "--" after the delimiter ends the body.
            if start + 1 < bytes.count, bytes[start] == 45, bytes[start + 1] == 45 { break }
            if start + 1 < bytes.count, bytes[start] == 13, bytes[start + 1] == 10 { start += 2 }
            guard let next = find([13, 10] + d, from: start) else { break }
            let part = Array(bytes[start..<next])
            if let split = find2(part, [13, 10, 13, 10]) {
                let head = String(decoding: part[0..<split], as: UTF8.self)
                let data = Data(part[(split + 4)...])
                var name = "", filename: String?
                for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-disposition") {
                    for item in line.split(separator: ";").dropFirst() {
                        let kv = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                        guard kv.count == 2 else { continue }
                        let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if kv[0].lowercased() == "name" { name = v }
                        if kv[0].lowercased() == "filename" { filename = v }
                    }
                }
                parts.append(Part(name: name, filename: filename, data: data))
            }
            at = next + 2
        }
        return parts.filter { $0.filename != nil }
    }

    private static func find2(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<i + needle.count]) == needle { return i }
        return nil
    }
}
