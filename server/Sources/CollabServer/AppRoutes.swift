import CollabCore
import CollabDSL
import CollabModels
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Apps (docs/protocol.md section 2, "Apps", protocol 1.10): Dify 1.17.1's Studio console API
/// (`api/controllers/console/app/app.py`, `app_import.py`) under `/v1/apps`. An app is a document: the app id is the document
/// id. Reads and stars: any member; writes and the export: `owner`, `admin`, `editor` (Dify's `edit_permission_required`);
/// the export with secrets: `owner`, `admin` (protocol 1.8).
extension Routes {
    /// Dify's `AppListMode`.
    static let appListModes = ["completion", "chat", "advanced-chat", "workflow", "agent-chat", "agent", "channel", "all"]
    /// Dify's `CreateAppPayload.mode`.
    static let createAppModes = ["chat", "agent-chat", "advanced-chat", "workflow", "completion"]
    /// What dify-sf can create and run.
    static let supportedAppModes = ["workflow", "advanced-chat"]
    static let iconTypes = ["emoji", "image", "link"]
    /// Dify's `DSL_MAX_SIZE`.
    static let dslMaxBytes = 10 << 20

    /// Dify's legacy per-app permission keys of a role (`rbac_service.py`, `_LEGACY_APP_*_KEYS`, used while RBAC is off).
    static func appPermissionKeys(_ role: Role) -> [String] {
        switch role {
        case .owner, .admin:
            return ["app.acl.preview", "app.acl.view_layout", "app.acl.test_and_run", "app.acl.edit", "app.acl.import_export_dsl",
                    "app.acl.delete", "app.acl.release_and_version", "app.acl.monitor", "app.acl.access_config",
                    "app.acl.tracing_config", "app.acl.log_and_annotation", "app.acl.access_point_manage", "app.acl.access_point_view"]
        case .editor:
            return ["app.acl.preview", "app.acl.view_layout", "app.acl.test_and_run", "app.acl.edit", "app.acl.import_export_dsl",
                    "app.acl.delete", "app.acl.release_and_version", "app.acl.monitor", "app.acl.log_and_annotation",
                    "app.acl.access_config", "app.acl.access_point_manage", "app.acl.access_point_view"]
        case .normal: return ["app.acl.monitor", "app.acl.access_point_view"]
        case .datasetOperator: return ["app.acl.access_point_view"]
        }
    }

    func registerApps(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.get { req in await handle(req) { try await listApps(req, starred: false) } }
        apps.post { req in await handle(req) { try await createApp(req) } }
        apps.get("starred") { req in await handle(req) { try await listApps(req, starred: true) } }
        apps.post("imports") { req in await handle(req) { try await importApp(req) } }
        apps.post("imports", ":import", "confirm") { req in await handle(req) { try await confirmImport(req) } }
        apps.get(":app") { req in await handle(req) { try await getApp(req) } }
        apps.put(":app") { req in await handle(req) { try await updateApp(req) } }
        apps.delete(":app") { req in await handle(req) { try await deleteApp(req) } }
        apps.post(":app", "copy") { req in await handle(req) { try await copyApp(req) } }
        apps.get(":app", "export") { req in await handle(req) { try await exportApp(req) } }
        apps.post(":app", "star") { req in await handle(req) { try await starApp(req, true) } }
        apps.delete(":app", "star") { req in await handle(req) { try await starApp(req, false) } }
    }

    // MARK: - Plumbing

    func appId(_ req: Request) throws -> String {
        guard let id = req.parameters.get("app"), Self.validDocId(id) else { throw ServerError.missing("App not found") }
        return id
    }

    /// Every query parameter with all its values (`creator_ids=a&creator_ids=b`, Flask's `getlist`); `+` is a space.
    func queryAll(_ req: Request) -> [String: [String]] {
        var out: [String: [String]] = [:]
        guard let q = req.url.query else { return out }
        func decode(_ s: Substring) -> String {
            let plus = s.replacingOccurrences(of: "+", with: " ")
            return plus.removingPercentEncoding ?? plus
        }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            out[decode(k), default: []].append(kv.count > 1 ? decode(kv[1]) : "")
        }
        return out
    }

    /// The app of `id` as the caller sees it: `404 not_found` if unknown, `404 app_deleted` if deleted.
    func liveApp(_ id: String, viewer: String) async throws -> StoredApp {
        let a: StoredApp?
        do { a = try await store.app(id, viewer: viewer) } catch { throw ServerError.unavailable("\(error)") }
        guard let a else { throw ServerError.missing("App not found") }
        if a.deleted { throw ServerError.appDeleted }
        return a
    }

    /// The document's Dify metadata with the app row's name, description and icon (the row is their source of truth).
    func currentMetadata(_ id: String, viewer: String) async throws -> Value {
        let meta: Value?, app: StoredApp?
        do {
            meta = try await store.documentMetadata(id)
            app = try await store.app(id, viewer: viewer)
        } catch { throw ServerError.unavailable("\(error)") }
        let metadata = meta ?? DifyDSL.defaultMetadata(name: id)
        guard let app else { return metadata }
        return Self.overlayingAppRow(metadata, app, fallbackName: id)
    }

    /// `metadata` with the app row's name, description and icon. Only members where the row differs from what the file
    /// implies are written, so that an untouched imported app still exports to the file it came from (members it lacked stay
    /// absent, its own spelling of a default stays).
    static func overlayingAppRow(_ metadata: Value, _ app: StoredApp, fallbackName: String) -> Value {
        func opt(_ s: String?) -> Value { s.map { .string($0) } ?? .null }
        let implied = NewApp.from(metadata: metadata, fallbackName: fallbackName, createdBy: nil)
        var fields: [String: Value] = [:]
        func put(_ key: String, _ value: Value, _ impliedValue: Value) {
            if value != impliedValue { fields[key] = value }
        }
        put("name", .string(app.name), .string(implied.name))
        put("description", .string(app.description), .string(implied.description))
        put("icon_type", opt(app.iconType), opt(implied.iconType))
        put("icon", opt(app.icon), opt(implied.icon))
        put("icon_background", opt(app.iconBackground), opt(implied.iconBackground))
        put("use_icon_as_answer_icon", .bool(app.useIconAsAnswerIcon), .bool(implied.useIconAsAnswerIcon))
        return DifyDSL.overlayingApp(metadata, fields)
    }

    /// What an export needs: the document at head, its metadata (with the app row) and, with `includeSecret`, its secrets.
    func exportParts(_ id: String, viewer: String, includeSecret: Bool) async throws -> (Snapshot, Value, [String: String]?) {
        let s = try await registry.sequencer(id).currentSnapshot()
        let metadata = try await currentMetadata(id, viewer: viewer)
        var secrets: [String: String]?
        if includeSecret {
            do { secrets = try await store.secrets(id) } catch { throw ServerError.unavailable("\(error)") }
        }
        return (s, metadata, secrets)
    }

    /// After an overwrite import (`POST /replace`): the app takes the file's name, description and icon, as in Dify's
    /// `_create_or_update_app`. Members the file lacks stay.
    func adoptAppSection(_ doc: String, of root: Value, by account: String) async throws {
        guard case .map(let top) = root, case .map(let app)? = top["app"] else { return }
        func str(_ k: String) -> String? { if case .string(let s)? = app[k] { return s }; return nil }
        let name = str("name").flatMap { $0.isEmpty ? nil : $0 }
        let iconType = str("icon_type").flatMap { Self.iconTypes.contains($0) ? $0 : nil }
        let ok: Bool
        do {
            ok = try await store.updateApp(doc, name: name, description: str("description"), iconType: iconType, icon: str("icon"),
                                           iconBackground: str("icon_background"), useIconAsAnswerIcon: nil, maxActiveRequests: nil,
                                           by: account)
        } catch { throw ServerError.unavailable("\(error)") }
        if ok { await announceAppChanged(doc) }
    }

    /// `event: app` (section 5) to the streams of app `id`'s document on this process, after a change to what
    /// `GET /v1/apps/{app}` answers. Best-effort; a document without a sequencer here is not loaded for it.
    func announceAppChanged(_ id: String) async {
        guard let s = await registry.existing(id) else { return }
        await s.announceApp(AppEvent())
    }

    static func seconds(_ d: Date) -> Int { Int(d.timeIntervalSince1970.rounded(.down)) }

    /// Dify's `AppPartial` and `AppDetailWithSite` members in one object (see the protocol for what dify-sf fills).
    func appJSON(_ a: StoredApp, role: Role, req: Request) -> JSON {
        func opt(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
        let created = Self.seconds(a.createdAt), updated = Self.seconds(a.updatedAt)
        return .object([
            "id": .string(a.id), "name": .string(a.name), "description": .string(a.description), "mode": .string(a.mode),
            "icon_type": opt(a.iconType), "icon": opt(a.icon), "icon_background": opt(a.iconBackground), "icon_url": .null,
            "use_icon_as_answer_icon": .bool(a.useIconAsAnswerIcon), "max_active_requests": a.maxActiveRequests.map { .int($0) } ?? .null,
            "model_config": .null,
            "workflow": .object(["id": .string(a.id), "created_by": opt(a.createdBy), "created_at": .int(created),
                                 "updated_by": opt(a.updatedBy), "updated_at": .int(updated)]),
            "created_by": opt(a.createdBy), "created_at": .int(created), "updated_by": opt(a.updatedBy), "updated_at": .int(updated),
            "tags": .array([]), "access_mode": .null, "create_user_name": opt(a.authorName), "author_name": opt(a.authorName),
            "has_draft_trigger": .bool(false), "permission_keys": .array(Self.appPermissionKeys(role).map { .string($0) }),
            "is_starred": .bool(a.isStarred), "maintainer": .null, "bound_agent_id": .null,
            "enable_site": .bool(a.enableSite), "enable_api": .bool(a.enableApi), "site": siteJSON(a, req: req),
            "api_base_url": .string(apiBaseURL(req)), "deleted_tools": .array([]),
            "tracing": .null,
        ])
    }

    func appDetail(_ id: String, _ p: Principal, _ req: Request, status: HTTPResponse.Status = .ok) async throws -> Response {
        try json(appJSON(try await liveApp(id, viewer: p.id), role: p.role, req: req), status: status)
    }

    /// An optional string member: absent or null = nil; anything else but a string = `400`.
    func optionalString(_ b: [String: JSON], _ key: String) throws -> String? {
        guard let v = b[key], !v.isNull else { return nil }
        guard let s = v.string else { throw ServerError.badRequest("\(key) must be a string") }
        return s
    }

    func appName(_ b: [String: JSON], required: Bool) throws -> String? {
        guard let s = try optionalString(b, "name") else {
            if required { throw ServerError.badRequest("name is required") }
            return nil
        }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw ServerError.badRequest("name must not be empty") }
        return t
    }

    func appDescription(_ b: [String: JSON]) throws -> String? {
        let d = try optionalString(b, "description")
        if let d, d.count > 400 { throw ServerError.badRequest("description must be at most 400 characters") }
        return d
    }

    func appIconType(_ b: [String: JSON]) throws -> String? {
        let t = try optionalString(b, "icon_type")
        if let t, !Self.iconTypes.contains(t) { throw ServerError.badRequest("icon_type must be one of emoji, image, link") }
        return t
    }

    // MARK: - List, get, star

    private func listApps(_ req: Request, starred: Bool) async throws -> Response {
        let p = try await authenticate(req)
        let q = queryAll(req)
        func int(_ k: String, _ def: Int, _ range: ClosedRange<Int>) throws -> Int {
            guard let s = q[k]?.last, !s.isEmpty else { return def }
            guard let n = Int(s), range.contains(n) else {
                throw ServerError.badRequest("\(k) must be an integer in \(range.lowerBound)-\(range.upperBound)")
            }
            return n
        }
        let page = try int("page", 1, 1...99999), limit = try int("limit", 20, 1...100)
        let mode = q["mode"]?.last.flatMap { $0.isEmpty ? nil : $0 } ?? "all"
        guard Self.appListModes.contains(mode) else { throw ServerError.badRequest("mode must be one of \(Self.appListModes.joined(separator: ", "))") }
        let sortText = q["sort_by"]?.last.flatMap { $0.isEmpty ? nil : $0 } ?? "last_modified"
        guard let sort = AppListQuery.Sort(rawValue: sortText) else {
            throw ServerError.badRequest("sort_by must be one of last_modified, recently_created, earliest_created")
        }
        // Dify matches the first 30 characters of the search text.
        let name = q["name"]?.last.flatMap { $0.isEmpty ? nil : String(String.UnicodeScalarView($0.unicodeScalars.prefix(30))) }
        let creators = (q["creator_ids"] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var mine = false
        if let s = q["is_created_by_me"]?.last, !s.isEmpty {
            switch s.lowercased() {
            case "true", "1", "yes", "on", "t", "y": mine = true
            case "false", "0", "no", "off", "f", "n": mine = false
            default: throw ServerError.badRequest("is_created_by_me must be a boolean")
            }
        }
        // `tag_ids` are accepted and ignored: dify-sf has no tags yet.
        let query = AppListQuery(page: page, limit: limit, mode: mode == "all" ? nil : mode, name: name, sort: sort,
                                 creatorIds: creators, createdBy: mine ? p.id : nil, starredBy: starred ? p.id : nil)
        let result: (total: Int, apps: [StoredApp])
        do { result = try await store.listApps(query, viewer: p.id) } catch { throw ServerError.unavailable("\(error)") }
        return try json(JSON.object([
            "page": .int(page), "limit": .int(limit), "total": .int(result.total), "has_more": .bool(page * limit < result.total),
            "data": .array(result.apps.map { appJSON($0, role: p.role, req: req) }),
        ]))
    }

    private func getApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        return try await appDetail(try appId(req), p, req)
    }

    private func starApp(_ req: Request, _ star: Bool) async throws -> Response {
        let p = try await authenticate(req)
        let id = try appId(req)
        let ok: Bool
        do { ok = star ? try await store.starApp(id, account: p.id) : try await store.unstarApp(id, account: p.id) } catch {
            throw ServerError.unavailable("\(error)")
        }
        if !ok { _ = try await liveApp(id, viewer: p.id) }
        return try json(JSON.object(["result": "success"]))
    }

    // MARK: - Create, update, copy, delete, export

    private func createApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let b = try await jsonBody(req)
        let name = try appName(b, required: true)!
        let description = try appDescription(b) ?? ""
        guard let mode = b["mode"]?.string, Self.createAppModes.contains(mode) else {
            throw ServerError.badRequest("mode must be one of \(Self.createAppModes.joined(separator: ", "))")
        }
        guard Self.supportedAppModes.contains(mode) else {
            throw ServerError.http(status: 400, code: "unsupported_app_mode",
                                   message: "dify-sf only has workflow and chatflow (advanced-chat) apps, not \(mode)")
        }
        let iconType = try appIconType(b) ?? NewApp.defaultIconType
        let icon = try optionalString(b, "icon") ?? NewApp.defaultIcon
        let background = try optionalString(b, "icon_background") ?? NewApp.defaultIconBackground
        let seed = DifyDSL.blankApp(mode: mode, name: name, description: description, iconType: iconType, icon: icon, iconBackground: background)
        let imported: DifyDSL.Imported
        do { imported = try DifyDSL.importValue(seed) } catch { throw ServerError.internalError("blank app seed: \(error)") }
        let id = UUID().uuidString.lowercased()
        do {
            _ = try await store.createDocument(id: id, initial: imported.document, metadata: imported.metadata, app: NewApp(
                name: name, description: description, mode: mode, iconType: iconType, icon: icon, iconBackground: background, createdBy: p.id))
        } catch { throw ServerError.unavailable("\(error)") }
        return try await appDetail(id, p, req, status: .created)
    }

    private func updateApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let id = try appId(req)
        let b = try await jsonBody(req)
        let name = try appName(b, required: true)
        let description = try appDescription(b)
        let iconType = try appIconType(b)
        var answerIcon: Bool?
        if let v = b["use_icon_as_answer_icon"], !v.isNull {
            guard let x = v.bool else { throw ServerError.badRequest("use_icon_as_answer_icon must be a boolean") }
            answerIcon = x
        }
        var maxActive: Int?
        if let v = b["max_active_requests"], !v.isNull {
            guard let n = v.int, n >= 0 else { throw ServerError.badRequest("max_active_requests must be a non-negative integer") }
            maxActive = n
        }
        let ok: Bool
        do {
            ok = try await store.updateApp(id, name: name, description: description, iconType: iconType, icon: try optionalString(b, "icon"),
                                           iconBackground: try optionalString(b, "icon_background"), useIconAsAnswerIcon: answerIcon,
                                           maxActiveRequests: maxActive, by: p.id)
        } catch let e as ServerError { throw e } catch { throw ServerError.unavailable("\(error)") }
        if !ok { _ = try await liveApp(id, viewer: p.id) } else { await announceAppChanged(id) }
        return try await appDetail(id, p, req)
    }

    /// Dify's copy: the app exported with its secrets and imported as a new app (so the copy's secrets get new references,
    /// sealed for the new document id).
    private func copyApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let src = try await liveApp(try appId(req), viewer: p.id)
        let data = try await body(req)
        var b: [String: JSON] = [:]
        if !data.isEmpty {
            guard let obj = (try? JSONCoding.decode(data))?.object else { throw ServerError.badRequest("body must be a JSON object") }
            b = obj
        }
        let name = try appName(b, required: false) ?? src.name
        let description = try appDescription(b) ?? src.description
        let iconType = try appIconType(b) ?? src.iconType
        let icon = try optionalString(b, "icon") ?? src.icon
        let background = try optionalString(b, "icon_background") ?? src.iconBackground
        if store.cipher == nil {
            let n: Int
            do { n = try await store.secretCount(src.id) } catch { throw ServerError.unavailable("\(error)") }
            if n > 0 { throw Self.secretsKeyMissing }
        }
        let (s, metadata, secrets) = try await exportParts(src.id, viewer: p.id, includeSecret: true)
        let imported: DifyDSL.Imported
        do { imported = try DifyDSL.importValue(try DifyDSL.exportValue(s.doc, metadata: metadata, secrets: secrets)) } catch {
            throw ServerError.internalError("copy: \(error)")
        }
        let id = UUID().uuidString.lowercased()
        do {
            _ = try await store.createDocument(id: id, initial: imported.document, metadata: imported.metadata, secrets: imported.secrets,
                                               app: NewApp(name: name, description: description, mode: src.mode, iconType: iconType, icon: icon,
                                                           iconBackground: background, useIconAsAnswerIcon: src.useIconAsAnswerIcon,
                                                           maxActiveRequests: src.maxActiveRequests, createdBy: p.id))
        } catch is SecretsKeyMissing { throw Self.secretsKeyMissing } catch { throw ServerError.unavailable("\(error)") }
        return try await appDetail(id, p, req, status: .created)
    }

    private func deleteApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let id = try appId(req)
        let ok: Bool
        do { ok = try await store.deleteApp(id) } catch { throw ServerError.unavailable("\(error)") }
        if !ok { _ = try await liveApp(id, viewer: p.id) }
        await registry.evict(id)
        // A run of the deleted app that is waiting on human input must not stay answerable: close its pause and forms.
        if let paused = try? await store.pausedRuns(ofDocument: id) {
            for run in paused {
                try? await store.stopPausedRun(workflowRunId: run, error: "The app was deleted", at: Date())
            }
        }
        return Response(status: .noContent)
    }

    private func exportApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let id = try appId(req)
        let flag = queryAll(req)["include_secret"]?.last?.lowercased()
        let includeSecret = flag == "true" || flag == "1"
        if includeSecret { try authorize(p, .privileged) }
        let app = try await liveApp(id, viewer: p.id)
        // Protocol 1.11: `workflow_id` exports a published version (Dify's `export_dsl(workflow_id=...)`); the app id = the draft.
        if let w = queryAll(req)["workflow_id"]?.last, !w.isEmpty, w != id {
            guard Self.validDocId(w), let yaml = try await versionExportYAML(app, versionId: w, includeSecret: includeSecret) else {
                throw ServerError.missing("Workflow not found")
            }
            return try json(JSON.object(["data": .string(yaml)]))
        }
        let (s, metadata, secrets) = try await exportParts(id, viewer: p.id, includeSecret: includeSecret)
        let yaml = try DifyDSL.exportYAML(s.doc, metadata: metadata, secrets: secrets)
        return try json(JSON.object(["data": .string(yaml)]))
    }

    // MARK: - DSL import (Dify's /apps/imports)

    private func importApp(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let data = try await req.body.collect(max: .specified(ByteCount(value: Self.maxImportBytes))) ?? Data()
        guard let b = (try? JSONCoding.decode(data))?.object else { throw ServerError.badRequest("body must be a JSON object") }
        let importId = UUID().uuidString.lowercased()
        func failed(_ error: String) throws -> Response { try importAnswer(importId, status: "failed", error: error) }
        let mode = b["mode"]?.string ?? ""
        if let a = b["app_id"], !a.isNull {
            return try failed("dify-sf overwrites an existing app from its editor (POST /v1/docs/{id}/replace), not with app_id")
        }
        switch mode {
        case "yaml-content": break
        case "yaml-url": return try failed("yaml-url is not supported: dify-sf does not fetch files from URLs, upload the file instead")
        default: return try failed("Invalid import_mode: \(mode)")
        }
        guard let yaml = b["yaml_content"]?.string, !yaml.isEmpty else {
            return try failed("yaml_content is required when import_mode is yaml-content")
        }
        if yaml.utf8.count > Self.dslMaxBytes { return try failed("File size exceeds the limit of 10MB") }
        var overrides: [String: JSON] = [:]
        if let n = try optionalString(b, "name"), !n.isEmpty { overrides["name"] = .string(n) }
        if let d = try optionalString(b, "description") { overrides["description"] = .string(d) }
        if let t = try optionalString(b, "icon_type") { overrides["icon_type"] = .string(t) }
        if let i = try optionalString(b, "icon"), !i.isEmpty { overrides["icon"] = .string(i) }
        if let g = try optionalString(b, "icon_background"), !g.isEmpty { overrides["icon_background"] = .string(g) }
        return try await runImport(importId, yaml: yaml, overrides: overrides, account: p.id, confirm: false)
    }

    private func confirmImport(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        guard let id = req.parameters.get("import"), Self.validDocId(id) else { throw ServerError.missing("Import information expired or does not exist") }
        let pending: PendingImport?
        do { pending = try await store.takePendingImport(id, account: p.id) } catch { throw ServerError.unavailable("\(error)") }
        guard let pending else { throw ServerError.missing("Import information expired or does not exist") }
        let overrides = (try? JSONCoding.decode(Data(pending.overrides.utf8)))?.object ?? [:]
        return try await runImport(id, yaml: pending.yaml, overrides: overrides, account: p.id, confirm: true)
    }

    /// Dify's `Import` answer: `200` completed, `202` pending, `400` failed.
    func importAnswer(_ id: String, status: String, appId: String? = nil, appMode: String? = nil, imported: String = "",
                      error: String = "") throws -> Response {
        let code: HTTPResponse.Status = status == "failed" ? .badRequest : status == "pending" ? .accepted : .ok
        return try json(JSON.object([
            "id": .string(id), "status": .string(status), "app_id": appId.map { .string($0) } ?? .null,
            "app_mode": appMode.map { .string($0) } ?? .null, "current_dsl_version": .string(DifyDSL.currentDSLVersion),
            "imported_dsl_version": .string(imported), "error": .string(error), "warnings": .array([]),
        ]), status: code)
    }

    private func runImport(_ importId: String, yaml: String, overrides: [String: JSON], account: String, confirm: Bool) async throws -> Response {
        let root: Value
        do { root = try DifyDSL.parseYAML(yaml) } catch {
            return try importAnswer(importId, status: "failed", error: "Invalid YAML format: \(error)")
        }
        var fileVersion = ""
        var fileMode = "workflow"
        if case .map(let top) = root {
            if case .string(let v)? = top["version"] { fileVersion = v }
            if case .map(let app)? = top["app"], case .string(let m)? = app["mode"] { fileMode = m }
        }
        let checked: (version: String, status: DifyDSL.VersionStatus)
        do { checked = try DifyDSL.checkReplacement(root, appMode: fileMode, confirm: confirm, newApp: true) } catch {
            if let v = error.pendingVersion {
                let overridesText = String(decoding: try JSONCoding.encode(JSON.object(overrides)), as: UTF8.self)
                do { try await store.storePendingImport(importId, account: account, PendingImport(yaml: yaml, overrides: overridesText)) } catch {
                    throw ServerError.unavailable("\(error)")
                }
                return try importAnswer(importId, status: "pending", imported: v)
            }
            return try importAnswer(importId, status: "failed", imported: fileVersion, error: error.message)
        }
        let imported: DifyDSL.Imported
        do { imported = try DifyDSL.importValue(root) } catch {
            return try importAnswer(importId, status: "failed", imported: checked.version, error: "\(error)")
        }
        if !imported.secrets.isEmpty { try requireSecretsKey() }
        var app = NewApp.from(metadata: imported.metadata, fallbackName: "", createdBy: account)
        if let n = overrides["name"]?.string { app.name = n }
        if let d = overrides["description"]?.string { app.description = d }
        if let t = overrides["icon_type"]?.string, Self.iconTypes.contains(t) { app.iconType = t }
        if let i = overrides["icon"]?.string { app.icon = i }
        if let g = overrides["icon_background"]?.string { app.iconBackground = g }
        let id = UUID().uuidString.lowercased()
        do {
            _ = try await store.createDocument(id: id, initial: imported.document, metadata: imported.metadata, secrets: imported.secrets, app: app)
        } catch is SecretsKeyMissing { throw Self.secretsKeyMissing } catch { throw ServerError.unavailable("\(error)") }
        // A confirmed pending import is completed (Dify's `confirm_import`).
        let status = checked.status == .pending ? DifyDSL.VersionStatus.completed : checked.status
        return try importAnswer(importId, status: status.rawValue, appId: id, appMode: app.mode, imported: checked.version)
    }
}
