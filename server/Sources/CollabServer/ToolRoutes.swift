// Dify 1.17.1 controllers/console/workspace/tool_providers.py and core/plugin/impl/tool.py.
import CollabModels
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

extension Routes {
    func registerTools(on r: any RoutesBuilder) {
        registerWorkflowTools(on: r)
        let w = r.grouped("v1", "workspaces", "current")
        w.get("tool-providers") { req in await handle(req) { try await toolCatalog(req) } }
        w.get("tools", "builtin") { req in await handle(req) { try await toolCatalog(req) } }
        let p = w.grouped("tool-provider", "builtin", ":org", ":plugin", ":provider")
        p.get("icon", ":theme") { req in await handle(req) {
            let declaration = try await installedToolProvider(toolProviderID(req))["declaration"] ?? .null
            let identity = declaration["identity"] ?? .null
            let dark = req.parameters.get("theme") == "dark"
            let id = (dark ? identity["icon_dark"]?.string.flatMap { $0.isEmpty ? nil : $0 } : nil) ?? identity["icon"]?.string ?? ""
            let bytes = try await toolDaemon().asset(id)
            let type = id.lowercased().hasSuffix(".svg") ? "image/svg+xml" : id.lowercased().hasSuffix(".png") ? "image/png" : "application/octet-stream"
            var headers = HTTPFields()
            headers[.contentType] = type
            headers[.cacheControl] = "public, max-age=300"
            headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
            headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'none'; sandbox"
            return Response(status: .ok, headers: headers, body: .init(data: Data(bytes)))
        } }
        p.get("tools") { req in await handle(req) {
            _ = try await authenticate(req)
            let provider = try await installedToolProvider(toolProviderID(req))
            return try json(JSONValue.array((provider["declaration"]?["tools"]?.array ?? []).map(Self.toolProjection)))
        } }
        p.get("info") { req in await handle(req) {
            _ = try await authenticate(req)
            return try json(try await installedToolProvider(toolProviderID(req))["declaration"] ?? .null)
        } }
        p.get("credentials") { req in await handle(req) {
            let user = try await authenticate(req)
            let values = try await store.toolCredentials(provider: toolProviderID(req), viewer: user.id)
            let schema = runtimeConfigured ? Self.toolCredentialSchema(try await installedToolProvider(toolProviderID(req))["declaration"] ?? .null) : [:]
            return try json(JSONValue.array(try values.map { value in
                var display = JSONObject()
                if value.createdBy == user.id, let config = value.config, let decoded = try JSONValue.parse(Array(config.utf8)).object {
                    for (key, field) in schema {
                        if let item = decoded[key] { display[key] = field["type"] == "secret-input" ? .string(Credentials.hidden) : item }
                    }
                }
                return ["id": .string(value.id), "name": .string(value.name), "is_default": .bool(value.id == values.first?.id),
                 "credential_type": "api-key", "credentials": .object(display), "can_manage": .bool(value.createdBy == user.id), "is_team_authorization": .bool(value.shared)]
            }))
        } }
        p.post("add") { req in await handle(req) { try await saveToolCredential(req, update: false) } }
        p.post("update") { req in await handle(req) { try await saveToolCredential(req, update: true) } }
        p.post("delete") { req in await handle(req) {
            let user = try await authenticate(req, .edit), value = try await toolBody(req)
            guard let id = value["credential_id"]?.string else { throw Self.invalidParam("credential_id is required") }
            try await modelStoreCall { try await store.deleteToolCredential(provider: toolProviderID(req), id: id, userId: user.id) }
            return try ok()
        } }
        p.post("tools", ":tool", "parameters") { req in await handle(req) {
            let user = try await authenticate(req), value = try await toolBody(req)
            guard let name = req.parameters.get("tool") else { throw Self.invalidParam("tool is required") }
            let reference = ToolReference(providerID: toolProviderID(req), providerType: "builtin", name: name,
                                          credentialID: value["credential_id"]?.string)
            let runtime = PluginDaemonToolRuntime(daemon: toolDaemon(), credential: { tool in
                try await self.toolCredentials(tool, userId: user.id)
            })
            let parameters = try await runtime.parameters(reference, context: NodeRunContext(pool: VariablePool(), userId: user.id))
            return try json(JSONValue.array(parameters))
        } }
        p.post("dynamic-options") { req in await handle(req) {
            let user = try await authenticate(req), value = try await toolBody(req), id = toolProviderID(req)
            let parts = try PluginDaemonModelRuntime.split(id)
            guard let name = value["tool"]?.string, let parameter = value["parameter"]?.string else { throw Self.invalidParam("tool and parameter are required") }
            let reference = ToolReference(providerID: id, providerType: "builtin", name: name, credentialID: value["credential_id"]?.string)
            _ = try await installedToolProvider(id)
            let credentials = try await toolCredentials(reference, userId: user.id)
            let body = PluginDaemonWire.dispatchBody(userId: user.id, appId: nil,
                data: ["provider": .string(parts.provider), "credentials": .object(credentials), "credential_type": "api-key",
                       "provider_action": .string(name), "parameter": .string(parameter)])
            for try await response in toolDaemon().dispatch("dynamic_select/fetch_parameter_options", pluginId: parts.pluginId, body: body) {
                return try json(response["options"] ?? .array([]))
            }
            throw ServerError.unavailable("The tool returned no options")
        } }
    }

    /// The daemon exposes normalized credentials_schema[], rather than a plugin YAML dictionary.
    static func toolCredentialSchema(_ declaration: JSONValue) -> JSONObject {
        if let values = declaration["credentials_schema"]?.array {
            return JSONObject(values.compactMap { field in field["name"]?.string.map { ($0, field) } })
        }
        return declaration["credentials_for_provider"]?.object ?? [:]
    }

    static func toolProjection(_ declaration: JSONValue) -> JSONValue {
        var value = declaration.object ?? [:]
        for (key, item) in declaration["identity"]?.object ?? [:] { value[key] = item }
        value["description"] = declaration["description"]?["human"] ?? declaration["description"] ?? .object([:])
        return .object(value)
    }

    func toolProviderID(_ req: Request) -> String {
        ["org", "plugin", "provider"].compactMap { req.parameters.get($0) }.joined(separator: "/")
    }

    func toolBody(_ req: Request) async throws -> JSONObject {
        guard let value = try JSONValue.parse(try await body(req)).object else { throw Self.invalidParam("body must be an object") }
        return value
    }

    func installedToolProvider(_ id: String) async throws -> JSONValue {
        guard runtimeConfigured else { throw ServerError.unavailable("The plugin daemon is not configured") }
        let parts = try PluginDaemonModelRuntime.split(id)
        return try await toolDaemon().management("tool", query: [URLQueryItem(name: "plugin_id", value: parts.pluginId), URLQueryItem(name: "provider", value: parts.provider)])
    }

    func toolCatalog(_ req: Request) async throws -> Response {
        let user = try await authenticate(req)
        if !runtimeConfigured { return try json(JSONValue.array([])) }
        let credentials = try await store.toolCredentials(viewer: user.id)
        var result: [JSONValue] = []
        // Dify's daemon list is paged. Read all pages, with a bound against a broken daemon repeating a page.
        for page in 1...100 {
            let rows = try await toolDaemon().management("tools", query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page_size", value: "256")]).array ?? []
            for row in rows {
                guard let plugin = row["plugin_id"]?.string, let declaration = row["declaration"],
                      let name = declaration["identity"]?["name"]?.string else { continue }
                let id = plugin + "/" + name
                var value = declaration["identity"]?.object ?? [:]
                let iconPath = "/v1/workspaces/current/tool-provider/builtin/" + id
                value["icon"] = .string(iconPath + "/icon/light")
                value["icon_dark"] = .string(iconPath + "/icon/dark")
                value["id"] = .string(id); value["name"] = .string(name); value["type"] = "builtin"
                value["plugin_id"] = .string(plugin); value["plugin_unique_identifier"] = row["plugin_unique_identifier"] ?? .null
                value["tools"] = .array((declaration["tools"]?.array ?? []).map(Self.toolProjection))
                value["allow_delete"] = .bool(!Self.toolCredentialSchema(declaration).isEmpty)
                value["credentials_schema"] = .object(Self.toolCredentialSchema(declaration))
                value["is_team_authorization"] = .bool((Self.toolCredentialSchema(declaration).isEmpty && (declaration["oauth_schema"] == nil || declaration["oauth_schema"] == .null)) || credentials.contains { $0.provider == id })
                result.append(.object(value))
            }
            if rows.count < 256 { break }
            if page == 100 { throw ServerError.unavailable("Plugin catalog exceeds the supported page limit") }
        }
        return try json(JSONValue.array(result))
    }

    func saveToolCredential(_ req: Request, update: Bool) async throws -> Response {
        let user = try await authenticate(req, .edit), value = try await toolBody(req), id = toolProviderID(req)
        try requireSecretsKey()
        guard let credentials = value["credentials"]?.object else { throw Self.invalidParam("credentials must be an object") }
        let provider = try await installedToolProvider(id)
        let schema = Self.toolCredentialSchema(provider["declaration"] ?? .null)
        let existing = update ? value["credential_id"]?.string : nil
        if update && existing == nil { throw Self.invalidParam("credential_id is required") }
        var input = credentials
        if let existing {
            guard let old = try await store.toolCredentials(provider: id, viewer: user.id).first(where: { $0.id == existing && $0.createdBy == user.id }) else { throw ServerError.notFound }
            for (key, field) in schema where field["type"] == "secret-input" && input[key] == .string(Credentials.hidden) {
                guard let config = old.config, let secret = try JSONValue.parse(Array(config.utf8))[key] else {
                    throw Self.invalidParam("Stored credential cannot be decrypted; enter the secret again")
                }
                input[key] = secret
            }
        }
        let schemas = try schema.map { name, field -> JSON in
            var item = field.object ?? [:]; item["variable"] = .string(name)
            return try JSONCoding.decode(Data(JSONValue.object(item).compactJSON().utf8))
        }
        let filtered: JSONObject
        do {
            let checked = try Credentials.validateAndFilter(schemas, try JSONCoding.decode(Data(JSONValue.object(input).compactJSON().utf8)).object ?? [:])
            filtered = try JSONValue.parse(Array(JSONCoding.encode(JSON.object(checked)))).object ?? [:]
        } catch let error as Credentials.SchemaError { throw Self.invalidParam(error.description) }
        let parts = try PluginDaemonModelRuntime.split(id)
        var validated = false
        do {
            for try await result in toolDaemon().dispatch("tool/validate_credentials", pluginId: parts.pluginId,
                body: PluginDaemonWire.dispatchBody(userId: user.id, appId: nil, data: ["provider": .string(parts.provider), "credentials": .object(filtered)])) {
                validated = result["result"] == true
            }
        } catch is ModelInvokeError {
            // Validation errors must not echo a provider's credential-bearing response.
            throw ServerError.http(status: 400, code: "credential_validation_failed", message: "Tool credentials were rejected")
        } catch {
            throw ServerError.unavailable("Tool credential validation service is unavailable")
        }
        guard validated else { throw ServerError.http(status: 400, code: "credential_validation_failed", message: "Tool credentials were rejected") }
        let name = value["name"]?.string ?? "API KEY"
        guard !name.isEmpty, name.count <= 30 else { throw Self.invalidParam("Credential name must be 1–30 characters") }
        let shared = value["is_team_authorization"] == true || value["visibility"] == "all_members"
        if shared && !user.role.isPrivileged { throw ServerError.http(status: 403, code: "forbidden", message: "Only workspace administrators can share tool credentials") }
        let saved = try await modelStoreCall {
            try await store.saveToolCredential(provider: id, id: existing, name: name, config: JSONValue.object(filtered).compactJSON(), userId: user.id, shared: shared)
        }
        return try json(JSONValue.object(["result": "success", "id": .string(saved)]))
    }
}
