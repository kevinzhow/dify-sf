import CollabRuntime
import CollabStore
import Foundation

struct PluginDaemonToolRuntime: ToolRuntime {
    let daemon: PluginDaemonClient
    let credential: @Sendable (ToolReference) async throws -> JSONObject

    func declaration(_ tool: ToolReference) async throws -> JSONValue {
        let identity = try PluginDaemonModelRuntime.split(tool.providerID)
        let provider = try await daemon.management("tool", query: [URLQueryItem(name: "plugin_id", value: identity.pluginId), URLQueryItem(name: "provider", value: identity.provider)])
        guard let entity = provider["declaration"]?["tools"]?.array?.first(where: { $0["identity"]?["name"]?.string == tool.name }) else {
            throw NodeError("ToolNotFoundError", "Tool is not installed")
        }
        return entity
    }

    func parameters(_ tool: ToolReference, context: NodeRunContext) async throws -> [JSONValue] {
        let entity = try await declaration(tool)
        // Resolve authorization even for static tools; inaccessible credential IDs never silently fall back.
        let credentials = try await credential(tool)
        if entity["has_runtime_parameters"] != true { return entity["parameters"]?.array ?? [] }
        let identity = try PluginDaemonModelRuntime.split(tool.providerID)
        let body = PluginDaemonWire.dispatchBody(userId: context.userId, appId: context.appId,
            data: ["provider": .string(identity.provider), "tool": .string(tool.name), "credentials": .object(credentials)])
        for try await value in daemon.dispatch("tool/get_runtime_parameters", pluginId: identity.pluginId, body: body) {
            if let parameters = value["parameters"]?.array { return parameters }
        }
        throw NodeError("ToolParameterError", "Tool returned no runtime parameters")
    }

    func invoke(_ tool: ToolReference, parameters: JSONObject, context: NodeRunContext) -> AsyncThrowingStream<ToolRuntimeEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ToolRuntimeEvent, any Error>.makeStream()
        let task = Task {
            do {
                let identity = try PluginDaemonModelRuntime.split(tool.providerID)
                let credentials = try await credential(tool)
                var values = tool.configurations
                for (name, value) in parameters { values[name] = value }
                let body = PluginDaemonWire.dispatchBody(userId: context.userId, appId: context.appId,
                    data: ["provider": .string(identity.provider), "tool": .string(tool.name), "credentials": .object(credentials),
                           "credential_type": "api-key", "tool_parameters": .object(values)])
                for try await value in daemon.dispatch("tool/invoke", pluginId: identity.pluginId, body: body) {
                    if context.isAborted() || Task.isCancelled { throw CancellationError() }
                    continuation.yield(.message(value))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

extension Routes {
    func toolDaemon() -> PluginDaemonClient {
        PluginDaemonClient(baseURL: config.pluginDaemonURL, key: config.pluginDaemonKey,
                           tenant: config.pluginDaemonTenant, timeoutSeconds: config.pluginDaemonTimeoutSeconds)
    }

    func toolCredentials(_ tool: ToolReference, userId: String) async throws -> JSONObject {
        let values = try await store.toolCredentials(provider: tool.providerID, viewer: userId)
        let credential: StoredToolCredential?
        if let id = tool.credentialID, !id.isEmpty {
            guard let value = values.first(where: { $0.id == id }) else { throw NodeError("ToolProviderCredentialError", "Tool credential not found") }
            credential = value
        } else { credential = values.first }
        guard let credential else { return [:] } // Credential-free tools are valid; daemon validates required auth.
        guard let config = credential.config, let value = try JSONValue.parse(Array(config.utf8)).object else {
            throw NodeError("ToolProviderCredentialError", "Tool credentials cannot be decrypted")
        }
        return value
    }
}
