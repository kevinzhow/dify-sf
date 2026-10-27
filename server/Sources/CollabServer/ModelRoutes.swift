import CollabModels
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Model providers (docs/protocol.md section 2, "Model providers", protocol 1.9): Dify 1.17.1's console API for the
/// workspace's model providers (`api/controllers/console/workspace/model_providers.py`, `models.py`), under
/// `/v1/workspace/`. The provider id `org/plugin/provider` is three path segments. Reads: any member; writes and credential
/// reads: owner/admin (Dify's `is_admin_or_owner_required`); icons: public (Dify's icon route has no login either).
extension Routes {
    static let modelTypes = ["llm", "text-embedding", "rerank", "speech2text", "moderation", "tts"]

    func registerModels(on r: any RoutesBuilder) {
        let ws = r.grouped("v1", "workspace")
        ws.get("model-providers") { req in await handle(req) { try await providerList(req) } }
        ws.get("model-providers", "summary") { req in await handle(req) { try await providerSummary(req) } }
        ws.get("models", "model-types", ":type") { req in await handle(req) { try await modelsOfType(req) } }
        ws.get("default-model") { req in await handle(req) { try await defaultModel(req) } }
        ws.post("default-model") { req in await handle(req) { try await setDefaultModels(req) } }
        let p = ws.grouped("model-providers", ":org", ":plugin", ":name")
        p.get("models") { req in await handle(req) { try await providerModels(req) } }
        p.post("models", "discover") { req in await handle(req) { try await discoverModels(req) } }
        p.post("models", "probe") { req in await handle(req) { try await probeModelCapabilities(req) } }
        p.post("models", "autofill") { req in await handle(req) { try await saveAutofilledModel(req) } }
        p.post("models") { req in await handle(req) { try await saveModel(req) } }
        p.delete("models") { req in await handle(req) { try await removeModel(req) } }
        p.patch("models", "enable") { req in await handle(req) { try await enableModel(req, true) } }
        p.patch("models", "disable") { req in await handle(req) { try await enableModel(req, false) } }
        p.get("models", "parameter-rules") { req in await handle(req) { try await parameterRules(req) } }
        p.get("credentials") { req in await handle(req) { try await getProviderCredential(req) } }
        p.post("credentials") { req in await handle(req) { try await createProviderCredential(req) } }
        p.put("credentials") { req in await handle(req) { try await updateProviderCredential(req) } }
        p.delete("credentials") { req in await handle(req) { try await deleteProviderCredential(req) } }
        p.post("credentials", "switch") { req in await handle(req) { try await switchProviderCredential(req) } }
        p.post("credentials", "validate") { req in await handle(req) { try await validateProviderCredential(req) } }
        p.get("models", "credentials") { req in await handle(req) { try await getModelCredential(req) } }
        p.post("models", "credentials") { req in await handle(req) { try await createModelCredential(req) } }
        p.put("models", "credentials") { req in await handle(req) { try await updateModelCredential(req) } }
        p.delete("models", "credentials") { req in await handle(req) { try await deleteModelCredential(req) } }
        p.post("models", "credentials", "switch") { req in await handle(req) { try await switchModelCredential(req) } }
        p.post("models", "credentials", "validate") { req in await handle(req) { try await validateModelCredential(req) } }
        p.get(":iconType", ":lang") { req in await handle(req) { try await providerIcon(req) } }
    }

    // MARK: - Plumbing

    func provider(_ req: Request) throws -> ProviderDefinition {
        let id = [req.parameters.get("org"), req.parameters.get("plugin"), req.parameters.get("name")].compactMap { $0 }.joined(separator: "/")
        guard let def = models.catalog.provider(id) else { throw ServerError.missing("Provider \(id) does not exist.") }
        return def
    }

    /// The JSON object body (`400` for anything else).
    func jsonBody(_ req: Request) async throws -> [String: JSON] {
        let data = try await body(req)
        guard let obj = (try? JSONCoding.decode(data))?.object else { throw ServerError.badRequest("body must be a JSON object") }
        return obj
    }

    func modelType(_ v: JSON?) throws -> String {
        guard let t = v?.string, Self.modelTypes.contains(t) else {
            throw ServerError.badRequest("model_type must be one of \(Self.modelTypes.joined(separator: ", "))")
        }
        return t
    }

    func requiredString(_ b: [String: JSON], _ key: String) throws -> String {
        guard let s = b[key]?.string, !s.isEmpty else { throw ServerError.badRequest("\(key) is required") }
        return s
    }

    /// A credential `name`: optional, at most 30 characters (Dify's `Field(max_length=30)`).
    func credentialName(_ b: [String: JSON]) throws -> String? {
        guard let v = b["name"], !v.isNull else { return nil }
        guard let s = v.string else { throw ServerError.badRequest("name must be a string") }
        if s.count > 30 { throw ServerError.badRequest("name must be at most 30 characters") }
        return s.isEmpty ? nil : s
    }

    func credentialsBody(_ b: [String: JSON]) throws -> [String: JSON] {
        guard let c = b["credentials"]?.object else { throw ServerError.badRequest("credentials must be an object") }
        return c
    }

    func state() async throws -> ModelProviderState {
        do { return try await store.modelProviderState() } catch { throw ServerError.unavailable("\(error)") }
    }

    /// Store errors as answers: `404`, `409 credential_name_exists`, `400`, `503 secrets_key_missing`.
    func modelStoreCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as ModelStoreError {
            switch e {
            case .notFound(let m): throw ServerError.missing(m)
            case .nameTaken(let m): throw ServerError.http(status: 409, code: "credential_name_exists", message: m)
            case .invalid(let m): throw ServerError.badRequest(m)
            }
        } catch is SecretsKeyMissing {
            throw Self.secretsKeyMissing
        } catch let e as ServerError {
            throw e
        } catch {
            throw ServerError.unavailable("\(error)")
        }
    }

    static let secretsKeyMissing = ServerError.http(
        status: 503, code: "secrets_key_missing",
        message: "the server has no secrets key (COLLAB_SECRETS_KEY), so it cannot store secrets")

    func requireSecretsKey() throws {
        if store.cipher == nil { throw Self.secretsKeyMissing }
    }

    static func decodeConfig(_ text: String?) -> [String: JSON]? {
        guard let text, let obj = (try? JSONCoding.decode(Data(text.utf8)))?.object else { return nil }
        return obj
    }

    static func encodeConfig(_ c: [String: JSON]) throws -> String {
        String(decoding: try JSONCoding.encode(JSON.object(c)), as: UTF8.self)
    }

    func ok(_ status: HTTPResponse.Status = .ok) throws -> Response { try json(JSON.object(["result": "success"]), status: status) }

    func noContent() -> Response { Response(status: .noContent) }

    /// Validation and filtering of submitted credentials, then the provider check (unless switched off). Throws `400
    /// bad_request` for a form error and `400 credential_validation_failed` when the provider refuses them.
    func checkedCredentials(_ def: ProviderDefinition, model: String?, modelType: String?, _ input: [String: JSON], checkProvider: Bool = true) async throws -> [String: JSON] {
        let filtered = try filtered(def, modelType: modelType, input)
        if runtimeConfigured {
            let installed = await installedProviderPlugins(force: true)
            if installed.known && installed.plugin(def.id.pluginId) == nil {
                throw ServerError.http(status: 503, code: "plugin_not_installed", message: "Install the \(def.id.pluginId) plugin in Integrations before configuring this provider.")
            }
            if let model, let modelType {
                let resolved = await resolvedModelSchema(def, name: model, type: modelType, credentials: filtered, credentialId: nil)
                guard resolved.schema != nil && resolved.status == "ready" else {
                    throw modelSchemaError(resolved, def: def, model: model)
                }
            }
        }
        if checkProvider, let reason = await providerCheck(def, model: model, modelType: modelType, filtered) {
            throw ServerError.http(status: 400, code: "credential_validation_failed", message: reason)
        }
        return filtered
    }

    func filtered(_ def: ProviderDefinition, modelType: String?, _ input: [String: JSON]) throws -> [String: JSON] {
        let schemas: [JSON]
        if modelType != nil {
            guard def.modelCredentialSchema != nil else { throw ServerError.badRequest("Provider \(def.id) does not have model_credential_schema") }
            schemas = def.modelFormSchemas
        } else {
            guard def.providerCredentialSchema != nil else { throw ServerError.badRequest("Provider \(def.id) does not have provider_credential_schema") }
            schemas = def.providerFormSchemas
        }
        do { return try Credentials.validateAndFilter(schemas, input, modelType: modelType) } catch let e as Credentials.SchemaError {
            throw ServerError.badRequest(e.description)
        }
    }

    /// Nil = accepted (or not checked: validation off, or no check for this provider).
    func providerCheck(_ def: ProviderDefinition, model: String?, modelType: String?, _ c: [String: JSON]) async -> String? {
        guard models.validate, let plan = Validation.plan(provider: def, model: model, modelType: modelType, credentials: c) else { return nil }
        return await models.checker.check(plan)
    }

    // MARK: - Views (Dify's provider configurations)

    /// One provider's configuration as Dify's `ProviderConfiguration` sees it.
    struct ProviderView: Sendable {
        let def: ProviderDefinition
        let credentials: [StoredModelCredential]
        let hasRecord: Bool
        let currentId: String?
        let current: StoredModelCredential?
        /// The current credential's values; nil when there is none or it cannot be decrypted.
        let currentConfig: [String: JSON]?
        let customModels: [CustomModelView]
        let settings: [ModelKey: Bool]
        let hasCustomModels: Bool

        var currentUnreadable: Bool { current != nil && currentConfig == nil }
    }

    struct CustomModelView: Sendable {
        let key: ModelKey
        let credentials: [StoredModelCredential]
        let currentId: String?
        let current: StoredModelCredential?
        let config: [String: JSON]?
        let unadded: Bool
    }

    func view(_ def: ProviderDefinition, _ s: ModelProviderState) -> ProviderView {
        let pid = def.id.description
        let creds = s.providerCredentials[pid] ?? []
        let currentId = s.currentCredential[pid]
        let current = currentId.flatMap { id in creds.first { $0.id == id } }
        var custom: [CustomModelView] = []
        for key in s.customModelOrder where key.provider == pid {
            let mc = s.modelCredentials[key] ?? []
            let cid = s.customModelCredential[key]
            let cur = cid.flatMap { id in mc.first { $0.id == id } }
            custom.append(CustomModelView(key: key, credentials: mc, currentId: cid, current: cur, config: Self.decodeConfig(cur?.config), unadded: false))
        }
        for (key, mc) in s.modelCredentials.sorted(by: { ($0.key.model, $0.key.modelType) < ($1.key.model, $1.key.modelType) })
        where key.provider == pid && !s.customModelOrder.contains(key) {
            custom.append(CustomModelView(key: key, credentials: mc, currentId: nil, current: nil, config: nil, unadded: true))
        }
        return ProviderView(def: def, credentials: creds, hasRecord: s.configuredProviders.contains(pid), currentId: currentId, current: current,
                            currentConfig: Self.decodeConfig(current?.config).flatMap { $0.isEmpty ? nil : $0 },
                            customModels: custom, settings: s.modelSettings.filter { $0.key.provider == pid },
                            hasCustomModels: !custom.isEmpty)
    }

    struct ModelEntry: Sendable {
        let schema: ModelSchema
        let status: String
        var schemaStatus: String = "ready"
        var schemaError: String? = nil
    }

    /// Dify's `get_provider_models` (custom provider type): predefined models (active with a usable provider credential,
    /// else `no-configure`; dify-sf: `credential-removed` when the current credential cannot be decrypted), then the custom
    /// models of the model list with a schema; `disabled` by setting; de-duplicated, sorted by (model type, position).
    func modelEntries(_ v: ProviderView, type: String? = nil) async -> [ModelEntry] {
        let types = type.map { [$0] } ?? v.def.supportedModelTypes
        let plugins = await installedProviderPlugins()
        let pluginMissing = runtimeConfigured && plugins.known && plugins.plugin(v.def.id.pluginId) == nil
        var out: [ModelEntry] = []
        for t in types where v.def.supportedModelTypes.contains(t) {
            for m in v.def.models where m.modelType == t {
                var status = v.currentConfig != nil ? "active" : (v.currentUnreadable ? "credential-removed" : "no-configure")
                if pluginMissing && status == "active" { status = "no-configure" }
                if v.settings[ModelKey(provider: v.def.id.description, model: m.model, modelType: t)] == false { status = "disabled" }
                out.append(ModelEntry(schema: m.schema, status: status, schemaStatus: pluginMissing ? "unavailable" : "ready", schemaError: pluginMissing ? "plugin_not_installed" : nil))
            }
        }
        let custom = v.customModels.filter { !$0.unadded && types.contains($0.key.modelType) }
        let resolved = await withTaskGroup(of: (Int, ResolvedModelSchema).self, returning: [Int: ResolvedModelSchema].self) { group in
            for (index, model) in custom.enumerated() {
                group.addTask { (index, await customModelSchema(v.def, model)) }
            }
            var values: [Int: ResolvedModelSchema] = [:]
            for await (index, value) in group { values[index] = value }
            return values
        }
        for (index, c) in custom.enumerated() {
            let resolved = resolved[index] ?? .unknown
            let schema = resolved.schema ?? ModelSchema(model: c.key.model,
                label: ["en_US": .string(c.key.model), "zh_Hans": .string(c.key.model)], modelType: c.key.modelType,
                features: nil, fetchFrom: "customizable-model", modelProperties: [:], deprecated: false, parameterRules: [])
            var status = resolved.schema == nil ? "no-configure" : "active"
            if v.settings[c.key] == false { status = "disabled" }
            if !c.credentials.isEmpty && (c.config?.isEmpty ?? true) { status = "credential-removed" }
            out.append(ModelEntry(schema: schema, status: status, schemaStatus: resolved.status, schemaError: resolved.error))
        }
        // Python's {(model, type, fetch_from): m}: first position, last value.
        var order: [String] = []
        var byKey: [String: ModelEntry] = [:]
        for e in out {
            let k = "\(e.schema.model)\u{0}\(e.schema.modelType)\u{0}\(e.schema.fetchFrom)"
            if byKey[k] == nil { order.append(k) }
            byKey[k] = e
        }
        let deduped = order.map { byKey[$0]! }
        // Positions are keyed by the YAML's type keys (`text_embedding`) and looked up by the type value (`text-embedding`),
        // exactly as Dify does: only types without a hyphen are ordered by `_position.yaml`.
        func position(_ e: ModelEntry) -> Int {
            let positions = v.def.positions[e.schema.modelType] ?? []
            return positions.firstIndex(of: e.schema.model) ?? positions.count
        }
        return deduped.enumerated().sorted { a, b in
            let ka = (a.element.schema.modelType, position(a.element)), kb = (b.element.schema.modelType, position(b.element))
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    /// Resolve independent providers together so an unavailable daemon costs
    /// one metadata timeout rather than one timeout per provider and model.
    func modelEntries(_ views: [ProviderView], type: String) async -> [[ModelEntry]] {
        await withTaskGroup(of: (Int, [ModelEntry]).self, returning: [[ModelEntry]].self) { group in
            for (index, value) in views.enumerated() {
                group.addTask { (index, await modelEntries(value, type: type)) }
            }
            var values = Array(repeating: [ModelEntry](), count: views.count)
            for await (index, value) in group { values[index] = value }
            return values
        }
    }

    // MARK: - JSON shapes

    func iconURLs(_ def: ProviderDefinition, _ type: String, present: Bool) -> JSON {
        guard present else { return .null }
        let prefix = "/v1/workspace/model-providers/\(def.id)/\(type)"
        return ["en_US": .string("\(prefix)/en_US"), "zh_Hans": .string("\(prefix)/zh_Hans")]
    }

    func iconSmall(_ def: ProviderDefinition) -> JSON { iconURLs(def, "icon_small", present: def.iconSmall != nil) }
    func iconSmallDark(_ def: ProviderDefinition) -> JSON { iconURLs(def, "icon_small_dark", present: def.iconSmallDark != nil) }

    static func credentialRefs(_ creds: [StoredModelCredential]) -> JSON {
        .array(creds.map { ["credential_id": .string($0.id), "credential_name": .string($0.name)] })
    }

    func modelJSON(_ e: ModelEntry, provider: ProviderDefinition? = nil, defaultProvider: Bool = false) -> JSON {
        var m: [String: JSON] = [
            "model": .string(e.schema.model),
            "label": e.schema.label,
            "model_type": .string(e.schema.modelType),
            "features": e.schema.features.map { .array($0.map(JSON.string)) } ?? .null,
            "fetch_from": .string(e.schema.fetchFrom),
            "model_properties": .object(e.schema.modelProperties),
            "deprecated": .bool(e.schema.deprecated),
            "status": .string(e.status),
            "load_balancing_enabled": false,
            "has_invalid_load_balancing_configs": false,
        ]
        if e.schemaStatus != "ready" { m["schema_status"] = .string(e.schemaStatus) }
        if let error = e.schemaError { m["schema_error"] = .string(error) }
        if let provider { m["provider"] = simpleProvider(provider) }
        return .object(m)
    }

    /// Dify's `SimpleProviderEntityResponse`.
    func simpleProvider(_ def: ProviderDefinition, dark: Bool = true) -> JSON {
        [
            "provider": .string(def.id.description),
            "provider_name": "",
            "label": def.label,
            "icon_small": iconSmall(def),
            "icon_small_dark": dark ? iconSmallDark(def) : .null,
            "supported_model_types": .array(def.supportedModelTypes.map(JSON.string)),
            "models": [],
        ]
    }

    // MARK: - Reads

    /// `GET /v1/workspace/model-providers/summary`: Dify's `ModelProviderSummaryResponse` list (`plugins` is `{}`).
    private func providerSummary(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let s = try await state()
        let data: [JSON] = models.catalog.providers.map { def in
            let v = view(def, s)
            let configured = (v.hasRecord && !v.credentials.isEmpty) || v.hasCustomModels
            return [
                "provider": .string(def.id.description),
                "plugin_id": .string(def.id.pluginId),
                "label": def.label,
                "description": def.description ?? .null,
                "icon_small": iconSmall(def),
                "icon_small_dark": iconSmallDark(def),
                "supported_model_types": .array(def.supportedModelTypes.map(JSON.string)),
                "configurate_methods": .array(def.configurateMethods.map(JSON.string)),
                "preferred_provider_type": "custom",
                "is_configured": .bool(configured),
                "custom_configuration": [
                    "status": configured ? "active" : "no-configure",
                    "has_custom_models": .bool(v.hasCustomModels),
                    "available_credentials": Self.credentialRefs(v.credentials),
                    "current_credential_id": v.currentId.map(JSON.string) ?? .null,
                    "current_credential_name": v.current.map { .string($0.name) } ?? .null,
                    "current_credential_usable": .bool(v.current != nil && !v.currentUnreadable),
                ],
                "system_configuration": ["enabled": false],
            ]
        }
        return try json(JSON.object(["data": .array(data), "plugins": [:]]))
    }

    /// `GET /v1/workspace/model-providers[?model_type=]`: Dify's `ProviderResponse` list.
    private func providerList(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let filter = query(req)["model_type"].flatMap { $0.isEmpty ? nil : $0 }
        if let filter { _ = try modelType(.string(filter)) }
        let s = try await state()
        let data: [JSON] = models.catalog.providers.compactMap { def in
            if let filter, !def.supportedModelTypes.contains(filter) { return nil }
            let v = view(def, s)
            let available = (v.hasRecord && !v.credentials.isEmpty) || !v.customModels.isEmpty
            let customModels: [JSON] = v.customModels.map { c in
                [
                    "model": .string(c.key.model),
                    "model_type": .string(c.key.modelType),
                    "credentials": .null,
                    "current_credential_id": c.currentId.map(JSON.string) ?? .null,
                    "current_credential_name": c.current.map { .string($0.name) } ?? .null,
                    "available_model_credentials": Self.credentialRefs(c.credentials),
                    "unadded_to_model_list": .bool(c.unadded),
                ]
            }
            let canAdd: [JSON] = v.customModels.filter(\.unadded).map { ["model": .string($0.key.model), "model_type": .string($0.key.modelType)] }
            return [
                "provider": .string(def.id.description),
                "label": def.label,
                "description": def.description ?? .null,
                "icon_small": iconSmall(def),
                "icon_small_dark": iconSmallDark(def),
                "background": def.background.map(JSON.string) ?? .null,
                "help": def.help ?? .null,
                "supported_model_types": .array(def.supportedModelTypes.map(JSON.string)),
                "configurate_methods": .array(def.configurateMethods.map(JSON.string)),
                "provider_credential_schema": def.providerCredentialSchema ?? .null,
                "model_credential_schema": def.modelCredentialSchema ?? .null,
                "preferred_provider_type": "custom",
                "custom_configuration": [
                    "status": available ? "active" : "no-configure",
                    "current_credential_id": v.hasRecord ? (v.currentId.map(JSON.string) ?? .null) : .null,
                    "current_credential_name": v.current.map { .string($0.name) } ?? .null,
                    "available_credentials": v.hasRecord ? Self.credentialRefs(v.credentials) : [],
                    "custom_models": .array(customModels),
                    "can_added_models": .array(canAdd),
                ],
                "system_configuration": ["enabled": false, "current_quota_type": .null, "quota_configurations": []],
            ]
        }
        return try json(JSON.object(["data": .array(data)]))
    }

    /// `GET /v1/workspace/models/model-types/{type}`: active, non-deprecated models grouped by provider.
    private func modelsOfType(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let type = try modelType(req.parameters.get("type").map(JSON.string))
        let s = try await state()
        var data: [JSON] = []
        let lists = await modelEntries(models.catalog.providers.map { view($0, s) }, type: type)
        for (def, entries) in zip(models.catalog.providers, lists) {
            let list = entries.filter { $0.status == "active" && !$0.schema.deprecated }
            guard !list.isEmpty else { continue }
            data.append([
                "provider": .string(def.id.description),
                "label": def.label,
                "icon_small": iconSmall(def),
                "icon_small_dark": iconSmallDark(def),
                "status": "active",
                "models": .array(list.map { modelJSON($0) }),
            ])
        }
        return try json(JSON.object(["data": .array(data)]))
    }

    /// `GET .../{provider}/models`: every model of the provider with its status.
    private func providerModels(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let def = try provider(req)
        let s = try await state()
        let list = await modelEntries(view(def, s))
        return try json(JSON.object(["data": .array(list.map { modelJSON($0, provider: def) })]))
    }

    /// `GET /v1/workspace/default-model?model_type=`: Dify's `get_default_model`: without a stored default, the first active
    /// model of the type (providers in catalog order) becomes the default and is stored.
    private func defaultModel(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let type = try modelType(query(req)["model_type"].map(JSON.string))
        let s = try await state()
        var chosen = s.defaults[type]
        if chosen == nil {
            let lists = await modelEntries(models.catalog.providers.map { view($0, s) }, type: type)
            for (def, entries) in zip(models.catalog.providers, lists) {
                if let first = entries.first(where: { $0.status == "active" }) {
                    chosen = try await modelStoreCall { try await store.defaultModelIfAbsent(type: type, provider: def.id.description, model: first.schema.model) }
                    break
                }
            }
        }
        guard let chosen, let def = models.catalog.provider(chosen.provider) else { return try json(JSON.object(["data": .null])) }
        return try json(JSON.object(["data": [
            "model": .string(chosen.model),
            "model_type": .string(type),
            "provider": simpleProvider(def, dark: false),
        ]]))
    }

    /// `GET .../{provider}/models/parameter-rules?model=`: Dify's `get_model_parameter_rules` (LLM only).
    private func parameterRules(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let def = try provider(req)
        guard let model = query(req)["model"], !model.isEmpty else { throw ServerError.badRequest("model is required") }
        let s = try await state()
        let v = view(def, s)
        let key = ModelKey(provider: def.id.description, model: model, modelType: "llm")
        if v.settings[key] == false { throw ServerError.badRequest("Model \(model) is disabled.") }
        let custom = v.customModels.first { !$0.unadded && $0.key == key && !($0.config?.isEmpty ?? true) }
        let credentials = custom?.config ?? v.currentConfig
        var rules: [JSON] = []
        if let credentials {
            if runtimeConfigured {
                let resolved = await resolvedModelSchema(def, name: model, type: "llm", credentials: credentials,
                    credentialId: custom?.currentId ?? v.currentId)
                guard let schema = resolved.schema else { throw modelSchemaError(resolved, def: def, model: model) }
                rules = schema.parameterRules
            } else if let m = def.model(model, type: "llm") {
                rules = m.parameterRules
            } else if let custom {
                let resolved = await customModelSchema(def, custom)
                guard let schema = resolved.schema else {
                    throw modelSchemaError(resolved, def: def, model: model)
                }
                rules = schema.parameterRules
            }
        }
        return try json(JSON.object(["data": .array(rules)]))
    }

    func modelSchemaError(_ resolved: ResolvedModelSchema, def: ProviderDefinition, model: String) -> ServerError {
        let message: String
        if resolved.error == "plugin_not_installed" {
            message = "Install the \(def.id.pluginId) plugin in Integrations to use this model."
        } else if resolved.error == "model_schema_missing" && def.id.description == "langgenius/openai/openai" {
            message = "The OpenAI plugin does not recognize model \(model). Update the plugin, or use the OpenAI-compatible provider for a custom endpoint and model name."
        } else {
            message = "Model metadata is unavailable for \(def.id)/\(model). Verify the model name, plugin and provider configuration."
        }
        return ServerError.http(status: resolved.error == "model_schema_missing" ? 400 : 503,
            code: resolved.error ?? "model_schema_unavailable", message: message)
    }

    /// `GET .../{provider}/{icon_type}/{lang}` (public).
    private func providerIcon(_ req: Request) async throws -> Response {
        let def = try provider(req)
        guard let icon = def.icon(type: req.parameters.get("iconType") ?? "", lang: req.parameters.get("lang") ?? "") else {
            throw ServerError.missing("icon not found for provider \(def.id)")
        }
        var headers = HTTPFields()
        headers[.contentType] = icon.contentType
        headers[.cacheControl] = "public, max-age=3600"
        return Response(status: .ok, headers: headers, body: .init(data: icon.data))
    }

    // MARK: - Default models, model list

    /// `POST /v1/workspace/default-model` `{model_settings: [{model_type, provider?, model?}]}`.
    private func setDefaultModels(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let b = try await jsonBody(req)
        guard let settings = b["model_settings"]?.array else { throw ServerError.badRequest("model_settings must be a list") }
        let parsed: [(type: String, provider: String?, model: String?)] = try settings.map { s in
            (try modelType(s["model_type"]), s["provider"]?.string, s["model"]?.string)
        }
        var s = try await state()
        for setting in parsed {
            guard let providerId = setting.provider else { continue }
            guard let def = models.catalog.provider(providerId) else { throw ServerError.badRequest("Provider \(providerId) does not exist.") }
            // Dify checks the model name among the active models of the type (of every provider).
            let lists = await modelEntries(models.catalog.providers.map { view($0, s) }, type: setting.type)
            let active = lists.flatMap { $0 }.filter { $0.status == "active" }
            guard let model = setting.model, active.contains(where: { $0.schema.model == model }) else {
                throw ServerError.badRequest("Model \(setting.model ?? "") does not exist.")
            }
            try await modelStoreCall { try await store.setDefaultModel(type: setting.type, provider: def.id.description, model: model) }
            s.defaults[setting.type] = (def.id.description, model)
        }
        return try ok()
    }

    private func enableModel(_ req: Request, _ enabled: Bool) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = ModelKey(provider: def.id.description, model: try requiredString(b, "model"), modelType: try modelType(b["model_type"]))
        try await modelStoreCall { try await store.setModelEnabled(key, enabled) }
        return try ok()
    }

    /// `POST .../models` `{model, model_type, config_from?, credential_id?, load_balancing?}`: with `config_from:
    /// custom-model`, makes `credential_id` the model's current credential. Load balancing is not supported (ignored).
    private func saveModel(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = ModelKey(provider: def.id.description, model: try requiredString(b, "model"), modelType: try modelType(b["model_type"]))
        if b["config_from"]?.string == "custom-model" {
            guard let id = b["credential_id"]?.string, !id.isEmpty else {
                throw ServerError.badRequest("credential_id is required when configuring a custom-model")
            }
            try await modelStoreCall { try await store.switchCustomModelCredential(key, id: id) }
        }
        return try ok()
    }

    private func removeModel(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = ModelKey(provider: def.id.description, model: try requiredString(b, "model"), modelType: try modelType(b["model_type"]))
        try await modelStoreCall { try await store.deleteCustomModel(key) }
        return noContent()
    }

    // MARK: - Provider credentials

    private func getProviderCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let secrets = def.secretVariables(forModel: false)
        var values: [String: JSON] = [:]
        if let id = query(req)["credential_id"], !id.isEmpty {
            let c = try await modelStoreCall { try await store.providerCredential(provider: def.id.description, id: id) }
            values = Self.decodeConfig(c.config) ?? [:]
        } else {
            values = view(def, try await state()).currentConfig ?? [:]
        }
        return try json(JSON.object(["credentials": .object(Credentials.masked(values, secrets: secrets))]))
    }

    private func createProviderCredential(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let name = try credentialName(b)
        let input = try credentialsBody(b)
        try requireSecretsKey()
        if let name, (try await state()).providerCredentials[def.id.description]?.contains(where: { $0.name == name }) == true {
            throw ServerError.http(status: 409, code: "credential_name_exists", message: "Credential with name '\(name)' already exists.")
        }
        let checked = try await checkedCredentials(def, model: nil, modelType: nil, input)
        let config = try Self.encodeConfig(checked)
        _ = try await modelStoreCall { try await store.createProviderCredential(provider: def.id.description, name: name, config: config, createdBy: p.id) }
        return try ok(.created)
    }

    private func updateProviderCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let id = try requiredString(b, "credential_id")
        let name = try credentialName(b)
        let input = try credentialsBody(b)
        try requireSecretsKey()
        let stored = try await modelStoreCall { try await store.providerCredential(provider: def.id.description, id: id) }
        if let name, (try await state()).providerCredentials[def.id.description]?.contains(where: { $0.name == name && $0.id != id }) == true {
            throw ServerError.http(status: 409, code: "credential_name_exists", message: "Credential with name '\(name)' already exists.")
        }
        let restored = try restoreHidden(input, stored: stored, secrets: def.secretVariables(forModel: false))
        let checked = try await checkedCredentials(def, model: nil, modelType: nil, restored)
        let config = try Self.encodeConfig(checked)
        try await modelStoreCall { try await store.updateProviderCredential(provider: def.id.description, id: id, name: name, config: config) }
        return try ok()
    }

    /// `[__HIDDEN__]` -> the stored secret; `400` if a hidden secret cannot be restored (the stored credential cannot be
    /// decrypted with this server's key).
    func restoreHidden(_ input: [String: JSON], stored: StoredModelCredential, secrets: Set<String>) throws -> [String: JSON] {
        let usesHidden = input.contains { secrets.contains($0.key) && $0.value == .string(Credentials.hidden) }
        guard usesHidden else { return input }
        guard let config = Self.decodeConfig(stored.config) else {
            throw ServerError.badRequest("the stored credential cannot be decrypted with this server's secrets key; enter the secret again")
        }
        return Credentials.restoringHidden(input, stored: config, secrets: secrets)
    }

    private func deleteProviderCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let id = try requiredString(try await jsonBody(req), "credential_id")
        try await modelStoreCall { try await store.deleteProviderCredential(provider: def.id.description, id: id) }
        return noContent()
    }

    private func switchProviderCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let id = try requiredString(try await jsonBody(req), "credential_id")
        try await modelStoreCall { try await store.switchProviderCredential(provider: def.id.description, id: id) }
        return try ok()
    }

    /// `POST .../credentials/validate` `{credentials}`: `{"result":"success"}` or `{"result":"error","error"}` (form errors
    /// are `400`). Owner/admin only (Dify lets every member validate; dify-sf keeps outbound requests to the privileged roles).
    private func validateProviderCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let input = try credentialsBody(try await jsonBody(req))
        let filtered = try filtered(def, modelType: nil, input)
        return try validationAnswer(await providerCheck(def, model: nil, modelType: nil, filtered))
    }

    func validationAnswer(_ reason: String?) throws -> Response {
        guard let reason else { return try json(JSON.object(["result": "success"])) }
        return try json(JSON.object(["result": "error", "error": .string(reason.isEmpty ? "Unknown error" : reason)]))
    }

    // MARK: - Custom model credentials

    func modelKey(_ def: ProviderDefinition, _ b: [String: JSON]) throws -> ModelKey {
        ModelKey(provider: def.id.description, model: try requiredString(b, "model"), modelType: try modelType(b["model_type"]))
    }

    private func getModelCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let q = query(req)
        let key = try modelKey(def, ["model": q["model"].map(JSON.string) ?? .null, "model_type": q["model_type"].map(JSON.string) ?? .null])
        let secrets = def.secretVariables(forModel: true)
        let s = try await state()
        var credentials: [String: JSON] = [:]
        var currentId: String?, currentName: String?
        if let id = q["credential_id"], !id.isEmpty {
            let c = try await modelStoreCall { try await store.modelCredential(key, id: id) }
            credentials = Self.decodeConfig(c.config) ?? [:]
            currentId = c.id
            currentName = c.name
        } else if let c = view(def, s).customModels.first(where: { !$0.unadded && $0.key == key }), let config = c.config, !config.isEmpty {
            credentials = config
            currentId = c.currentId
            currentName = c.current?.name
        }
        let available = q["config_from"] == "predefined-model"
            ? (s.providerCredentials[def.id.description] ?? [])
            : (s.modelCredentials[key] ?? [])
        return try json(JSON.object([
            "credentials": .object(Credentials.masked(credentials.filter { $0.key != ModelDiscovery.metadataKey }, secrets: secrets)),
            "autofill": credentials[ModelDiscovery.metadataKey] ?? .null,
            "current_credential_id": currentId.map(JSON.string) ?? .null,
            "current_credential_name": currentName.map(JSON.string) ?? .null,
            "load_balancing": ["enabled": false, "configs": []],
            "available_credentials": Self.credentialRefs(available),
        ]))
    }

    private func createModelCredential(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = try modelKey(def, b)
        let name = try credentialName(b)
        let input = try credentialsBody(b)
        try requireSecretsKey()
        if let name, (try await state()).modelCredentials[key]?.contains(where: { $0.name == name }) == true {
            throw ServerError.http(status: 409, code: "credential_name_exists", message: "Model credential with name '\(name)' already exists for \(key.model).")
        }
        let checked = try await checkedCredentials(def, model: key.model, modelType: key.modelType, input)
        let config = try Self.encodeConfig(checked)
        _ = try await modelStoreCall { try await store.createModelCredential(key, name: name, config: config, createdBy: p.id) }
        return try ok(.created)
    }

    private func updateModelCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = try modelKey(def, b)
        let id = try requiredString(b, "credential_id")
        let name = try credentialName(b)
        let input = try credentialsBody(b)
        try requireSecretsKey()
        let stored = try await modelStoreCall { try await store.modelCredential(key, id: id) }
        if let name, (try await state()).modelCredentials[key]?.contains(where: { $0.name == name && $0.id != id }) == true {
            throw ServerError.http(status: 409, code: "credential_name_exists", message: "Model credential with name '\(name)' already exists for \(key.model).")
        }
        let restored = try restoreHidden(input, stored: stored, secrets: def.secretVariables(forModel: true))
        let checked = try await checkedCredentials(def, model: key.model, modelType: key.modelType, restored)
        var updated = checked
        if let old = Self.decodeConfig(stored.config), let metadata = old[ModelDiscovery.metadataKey] {
            updated[ModelDiscovery.metadataKey] = ModelAutofillMetadata.edited(metadata, old: old, new: checked)
        }
        let config = try Self.encodeConfig(updated)
        try await modelStoreCall { try await store.updateModelCredential(key, id: id, name: name, config: config) }
        return try ok()
    }

    private func deleteModelCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = try modelKey(def, b)
        let id = try requiredString(b, "credential_id")
        try await modelStoreCall { try await store.deleteModelCredential(key, id: id) }
        return noContent()
    }

    private func switchModelCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = try modelKey(def, b)
        let id = try requiredString(b, "credential_id")
        try await modelStoreCall { try await store.addModelCredentialToModel(key, id: id) }
        return try ok()
    }

    private func validateModelCredential(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        let def = try provider(req)
        let b = try await jsonBody(req)
        let key = try modelKey(def, b)
        let filtered = try filtered(def, modelType: key.modelType, try credentialsBody(b))
        return try validationAnswer(await providerCheck(def, model: key.model, modelType: key.modelType, filtered))
    }
}
