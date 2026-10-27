import AsyncHTTPClient
import CollabModels
import CollabRuntime
import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

struct InstalledProviderPlugins: Sendable {
    var known: Bool
    var rows: [JSONValue]
    static let unknown = Self(known: false, rows: [])
    func plugin(_ id: String) -> JSONValue? { rows.first { $0["plugin_id"]?.string == id } }
}

/// A failed list is unknown, never an authoritative empty installation list.
actor ProviderPluginCache {
    private var cached: (Date, InstalledProviderPlugins)?
    private var pending: Task<InstalledProviderPlugins, Never>?
    private var generation = 0
    func invalidate() { generation += 1; cached = nil; pending?.cancel(); pending = nil }
    func read(force: Bool = false, load: @escaping @Sendable () async throws -> [JSONValue]) async -> InstalledProviderPlugins {
        if !force, let (date, value) = cached, Date().timeIntervalSince(date) < (value.known ? 5 : 1) { return value }
        if let pending { return await pending.value }
        let started = generation
        let task = Task {
            do { return InstalledProviderPlugins(known: true, rows: try await load()) }
            catch { return InstalledProviderPlugins.unknown }
        }
        pending = task
        let value = await task.value
        guard generation == started else { return value }
        pending = nil
        cached = (Date(), value)
        return value
    }
}

protocol ProviderPluginPackageSource: Sendable {
    func package(_ pin: ProviderPlugin) async throws -> Data
}

struct HTTPProviderPluginPackages: ProviderPluginPackageSource {
    func package(_ pin: ProviderPlugin) async throws -> Data {
        var url = URLComponents(string: "https://marketplace.dify.ai/api/v1/plugins/download-url")!
        url.queryItems = [URLQueryItem(name: "unique_identifier", value: pin.uniqueIdentifier)]
        var req = HTTPClientRequest(url: url.url!.absoluteString)
        req.headers.add(name: "User-Agent", value: "Mozilla/5.0 (compatible; dify-sf-provider-manager)")
        req.headers.add(name: "Referer", value: "https://marketplace.dify.ai/")
        let response = try await HTTPClient.shared.execute(req, timeout: .seconds(90))
        guard response.status.code == 200 else { throw ServerError.unavailable("The official plugin package could not be downloaded. Retry later.") }
        return Data(try await response.body.collect(upTo: 32 << 20).readableBytesView)
    }
}

extension PluginDaemonClient {
    func managementPost(_ path: String, value: JSONValue) async throws -> JSONValue {
        try await managementPost(path, bytes: Data(value.compactJSON().utf8), contentType: "application/json")
    }

    func managementPost(_ path: String, bytes: Data, contentType: String) async throws -> JSONValue {
        var req = HTTPClientRequest(url: "\(baseURL)/plugin/\(tenant)/management/\(path)")
        req.method = .POST
        req.headers.add(name: "X-Api-Key", value: key)
        req.headers.add(name: "Content-Type", value: contentType)
        req.body = .bytes(ByteBuffer(bytes: bytes))
        let response = try await client.execute(req, timeout: .seconds(120))
        guard response.status.code == 200 else { throw ServerError.unavailable("The plugin operation failed. Retry or check the plugin service.") }
        let raw = try await response.body.collect(upTo: Self.maxLine)
        let reply = try JSONValue.parse(Array(raw.readableBytesView))
        guard reply["code"]?.int == 0, let data = reply["data"] else {
            // Management errors may include private environment details.
            throw ServerError.unavailable("The plugin service could not complete the operation.")
        }
        return data
    }

    func uploadVerifiedProvider(_ bytes: Data) async throws -> JSONValue {
        let boundary = "DifySF" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"verify_signature\"\r\n\r\ntrue\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"dify_pkg\"; filename=\"provider.difypkg\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await managementPost("install/upload/package", bytes: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}

extension Routes {
    func providerPluginDaemon() -> PluginDaemonClient {
        PluginDaemonClient(baseURL: config.pluginDaemonURL, key: config.pluginDaemonKey, tenant: config.pluginDaemonTenant,
                           timeoutSeconds: min(15, max(1, config.pluginDaemonTimeoutSeconds)))
    }

    func installedProviderPlugins(force: Bool = false) async -> InstalledProviderPlugins {
        guard runtimeConfigured else { return .unknown }
        let daemon = providerPluginDaemon()
        return await models.plugins.read(force: force) {
            var all: [JSONValue] = []
            for page in 1...100 {
                let value = try await daemon.management("list", query: [URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page_size", value: "256"), URLQueryItem(name: "response_type", value: "paged")])
                guard let rows = value["list"]?.array ?? value.array else { throw ServerError.unavailable("Invalid plugin catalog") }
                all += rows
                if rows.count < 256 { return all }
            }
            throw ServerError.unavailable("Plugin catalog exceeds the supported page limit")
        }
    }

    func registerProviderPlugins(on r: any RoutesBuilder) {
        let p = r.grouped("v1", "workspace", "model-provider-plugins")
        p.get { req in await handle(req) { try await providerPluginList(req) } }
        p.get("tasks", ":task") { req in await handle(req) { try await providerPluginTask(req) } }
        p.post(":org", ":plugin", "install") { req in await handle(req) { try await installProviderPlugin(req) } }
        p.post(":org", ":plugin", "uninstall") { req in await handle(req) { try await uninstallProviderPlugin(req) } }
    }

    func managedProviderPin(_ req: Request) throws -> ProviderPlugin {
        let id = [req.parameters.get("org"), req.parameters.get("plugin")].compactMap { $0 }.joined(separator: "/")
        guard let pin = try ProviderPlugin.bundled().first(where: { $0.id == id }), models.catalog.providers.contains(where: { $0.id.pluginId == id }) else {
            throw ServerError.badRequest("This provider plugin is not in the server's supported catalog.")
        }
        return pin
    }

    func requireProviderPluginRuntime() throws {
        guard runtimeConfigured else { throw ServerError.unavailable("The model plugin service is not configured on this server.") }
    }

    func providerPluginList(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let installed = await installedProviderPlugins(force: true)
        let pins = try ProviderPlugin.bundled()
        let data: [JSONValue] = models.catalog.providers.map { def in
            let pin = pins.first { $0.id == def.id.pluginId }
            let row = installed.plugin(def.id.pluginId)
            return ["provider": .string(def.id.description), "plugin_id": .string(def.id.pluginId),
                "status": .string(!runtimeConfigured ? "unavailable" : !installed.known ? "unknown" : row == nil ? "missing" : "installed"),
                "installation_id": row?["id"] ?? .null,
                "installed_identifier": row?["plugin_unique_identifier"] ?? .null,
                "installed_version": row?["declaration"]?["version"] ?? .null,
                "available_version": pin.map { .string($0.version) } ?? .null,
                "available_identifier": pin.map { .string($0.uniqueIdentifier) } ?? .null]
        }
        return try json(JSONValue.object(["data": .array(data), "runtime_configured": .bool(runtimeConfigured)]))
    }

    func installProviderPlugin(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        try requireProviderPluginRuntime()
        let pin = try managedProviderPin(req)
        let installed = await installedProviderPlugins(force: true)
        guard installed.known else { throw ServerError.unavailable("Plugin installation status could not be read. Retry before installing.") }
        let current = installed.plugin(pin.id)
        if current?["plugin_unique_identifier"]?.string == pin.uniqueIdentifier {
            await models.schemas.invalidate()
            return try json(JSONValue.object(["all_installed": true]))
        }
        let bytes = try await models.packages.package(pin)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == pin.sha256 else {
            throw ServerError.unavailable("The plugin package does not match the verified version.")
        }
        let daemon = providerPluginDaemon()
        let upload = try await daemon.uploadVerifiedProvider(bytes)
        guard upload["unique_identifier"]?.string == pin.uniqueIdentifier else {
            throw ServerError.unavailable("The plugin service returned an unexpected package identity.")
        }
        let result: JSONValue
        if let original = current?["plugin_unique_identifier"]?.string {
            result = try await daemon.managementPost("install/upgrade", value: ["original_plugin_unique_identifier": .string(original),
                "new_plugin_unique_identifier": .string(pin.uniqueIdentifier), "source": "package", "meta": [:]])
        } else {
            result = try await daemon.managementPost("install/identifiers", value: ["plugin_unique_identifiers": [.string(pin.uniqueIdentifier)], "source": "package", "metas": [[:]]])
        }
        await models.plugins.invalidate()
        await models.schemas.invalidate()
        return try json(result)
    }

    func providerPluginTask(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        try requireProviderPluginRuntime()
        guard let task = req.parameters.get("task"), UUID(uuidString: task) != nil else { throw ServerError.badRequest("Invalid plugin task id") }
        let value: JSONValue
        do { value = try await providerPluginDaemon().management("install/tasks/\(task)") }
        catch { throw ServerError.unavailable("The plugin task could not be read. Refresh the plugin status before trying again.") }
        let status = value["status"]?.string ?? "unknown"
        if status == "success" { await models.plugins.invalidate(); await models.schemas.invalidate() }
        // The daemon's raw task errors can quote private runtime settings.
        return try json(JSONValue.object(["status": .string(status), "error": status == "failed" ? "Plugin installation failed. Retry or check the plugin service." : .null]))
    }

    func uninstallProviderPlugin(_ req: Request) async throws -> Response {
        _ = try await authenticate(req, .privileged)
        try requireProviderPluginRuntime()
        let pin = try managedProviderPin(req)
        let installed = await installedProviderPlugins(force: true)
        guard installed.known else { throw ServerError.unavailable("Plugin installation status could not be read. Retry before removing it.") }
        guard let row = installed.plugin(pin.id), let id = row["id"]?.string else { return try ok() }
        let body = try await jsonBody(req)
        guard body["installation_id"]?.string == id else {
            throw ServerError.http(status: 409, code: "plugin_installation_changed", message: "The installed plugin changed. Refresh before removing it.")
        }
        let value = try await providerPluginDaemon().managementPost("uninstall", value: ["plugin_installation_id": .string(id)])
        guard value == true else { throw ServerError.unavailable("The plugin could not be removed.") }
        await models.plugins.invalidate()
        await models.schemas.invalidate()
        // Credentials and workflow documents are deliberately retained.
        return try ok()
    }
}
