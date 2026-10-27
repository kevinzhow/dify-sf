import AsyncHTTPClient
import CollabModels
import CollabRuntime
import CollabStore
import Foundation
import NIOCore
import NIOHTTP1

/// HTTP client of Dify's plugin daemon 0.6.x (protocol 1.13): the dispatch endpoints Dify's api calls
/// (`api/core/plugin/impl/base.py`, `model.py`), which answer a stream of `data: {code, message, data}` lines. Requests
/// and answers are never logged (they carry credentials).
struct PluginDaemonClient: Sendable {
    let client: HTTPClient
    let baseURL: String
    let key: String
    let tenant: String
    let timeout: TimeAmount

    init(client: HTTPClient = .shared, baseURL: String, key: String, tenant: String, timeoutSeconds: Int) {
        self.client = client
        var b = baseURL
        while b.hasSuffix("/") { b.removeLast() }
        self.baseURL = b
        self.key = key
        self.tenant = tenant
        timeout = .seconds(Int64(timeoutSeconds))
    }

    /// Lines longer than this end the stream (a daemon never sends one; a broken peer must not grow memory).
    static let maxLine = 16 << 20

    /// Installed tool declarations, using the same authenticated daemon boundary as model invocations.
    func management(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        var url = URLComponents(string: "\(baseURL)/plugin/\(tenant)/management/\(path)")!
        if !query.isEmpty { url.queryItems = query }
        var req = HTTPClientRequest(url: url.url!.absoluteString)
        req.headers.add(name: "X-Api-Key", value: key)
        let response = try await client.execute(req, timeout: timeout)
        guard response.status.code == 200 else { throw NodeError("PluginDaemonError", "Plugin catalog request failed") }
        let buffer = try await response.body.collect(upTo: Self.maxLine)
        let value = try JSONValue.parse(Array(buffer.readableBytesView))
        guard value["code"]?.int == 0, let data = value["data"] else {
            throw NodeError("PluginDaemonError", value["message"]?.string ?? "Invalid plugin catalog response")
        }
        return data
    }

    /// Installed plugin icons are bounded public assets; never accepts an arbitrary upstream URL.
    func asset(_ id: String) async throws -> [UInt8] {
        guard id.utf8.count <= 160, !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }),
              !id.contains("..") else { throw NodeError("PluginAssetError", "Invalid plugin asset identifier") }
        var req = HTTPClientRequest(url: "\(baseURL)/plugin/\(tenant)/asset/\(id)")
        req.headers.add(name: "X-Api-Key", value: key)
        let response = try await client.execute(req, timeout: timeout)
        guard response.status.code == 200 else { throw NodeError("PluginAssetError", "Plugin icon is unavailable") }
        return Array(try await response.body.collect(upTo: 2 << 20).readableBytesView)
    }

    /// `POST /plugin/{tenant}/dispatch/{path}` with `X-Plugin-ID`: each `data` of the answer's stream, as it comes.
    func dispatch(_ path: String, pluginId: String, body: JSONValue) -> AsyncThrowingStream<JSONValue, any Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        let task = Task {
            do {
                var req = HTTPClientRequest(url: "\(baseURL)/plugin/\(tenant)/dispatch/\(path)")
                req.method = .POST
                req.headers.add(name: "X-Api-Key", value: key)
                req.headers.add(name: "X-Plugin-ID", value: pluginId)
                req.headers.add(name: "Content-Type", value: "application/json")
                req.body = .bytes(ByteBuffer(string: body.compactJSON()))
                let res = try await client.execute(req, timeout: timeout)
                guard res.status.code == 200 else {
                    let message = res.status.code == 404
                        ? "Plugin \(pluginId) is not installed or ready. Open Integrations to install or check the plugin."
                        : "Plugin dispatch HTTP \(res.status.code)"
                    throw PluginDaemonWire.DaemonError(errorType: "PluginDaemonError", message: message, httpStatus: Int(res.status.code))
                }
                var pending: [UInt8] = []
                for try await chunk in res.body {
                    pending.append(contentsOf: chunk.readableBytesView)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[..<nl], as: UTF8.self)
                        pending.removeSubrange(...nl)
                        if let data = try PluginDaemonWire.decodeLine(line) { continuation.yield(data) }
                    }
                    if pending.count > Self.maxLine { throw PluginDaemonWire.DaemonError(errorType: "ValueError", message: "plugin daemon line too long") }
                }
                if !pending.isEmpty, let data = try PluginDaemonWire.decodeLine(String(decoding: pending, as: UTF8.self)) {
                    continuation.yield(data)
                }
                continuation.finish()
            } catch let e as PluginDaemonWire.DaemonError {
                continuation.finish(throwing: e)
            } catch let e as ModelInvokeError {
                continuation.finish(throwing: e)
            } catch {
                // Dify: PluginDaemonInnerError(code=-500, message="Request to Plugin Daemon Service failed").
                continuation.finish(throwing: PluginDaemonWire.DaemonError(errorType: "PluginDaemonInnerError",
                                                                           message: "Request to Plugin Daemon Service failed: \(Self.describe(error))"))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? HTTPClientError {
            switch e {
            case .connectTimeout: return "connection timed out"
            case .deadlineExceeded: return "timed out"
            case .remoteConnectionClosed: return "the connection was closed"
            default: return "\(e)"
            }
        }
        let text = "\(error)"
        return text.count > 200 ? String(text.prefix(200)) : text
    }
}

/// The runtime's models (protocol 1.13): credentials from the workspace's model provider settings (protocol 1.9, decrypted
/// with the secrets key), schemas and invocations through the plugin daemon.
struct PluginDaemonModelRuntime: ModelRuntime {
    let daemon: PluginDaemonClient
    /// The workspace's current credentials of an LLM (Dify's `DifyCredentialsProvider.fetch`).
    let credentialsOf: @Sendable (_ provider: String, _ model: String, _ modelType: String) async throws -> JSONObject
    let appId: String?

    func credentials(provider: String, model: String, modelType: String) async throws -> JSONObject {
        try await credentialsOf(provider, model, modelType)
    }

    static func split(_ provider: String) throws -> (pluginId: String, provider: String) {
        guard let id = ProviderID(provider) else { throw NodeError("ValueError", "Invalid provider \(provider)") }
        return (id.pluginId, id.provider)
    }

    func modelSchema(provider: String, model: String, modelType: String, credentials: JSONObject) async throws -> AIModelEntity? {
        let (pluginId, name) = try Self.split(provider)
        let body = PluginDaemonWire.dispatchBody(userId: nil, appId: nil,
                                                 data: PluginDaemonWire.modelSchemaData(provider: name, modelType: modelType, model: model,
                                                                                        credentials: credentials))
        for try await data in daemon.dispatch("model/schema", pluginId: pluginId, body: body) {
            guard let schema = data["model_schema"], schema != .null else { return nil }
            return AIModelEntity(json: schema)
        }
        return nil
    }

    func numTokens(_ instance: ModelInstance, promptMessages: [PromptMessage]) async throws -> Int {
        let (pluginId, name) = try Self.split(instance.provider)
        var data = PluginDaemonWire.llmInvokeData(provider: name, model: instance.modelName, credentials: instance.credentials,
            promptMessages: promptMessages, parameters: [:], tools: [], stop: [], stream: false)
        data["model_type"] = "llm"
        for try await result in daemon.dispatch("llm/num_tokens", pluginId: pluginId,
            body: PluginDaemonWire.dispatchBody(userId: nil, appId: appId, data: data)) {
            guard let count = result["num_tokens"]?.int, count >= 0 else {
                throw NodeError("TokenCountError", "The model returned an invalid token count")
            }
            return count
        }
        throw NodeError("TokenCountError", "The model returned no token count")
    }

    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, stop: [String],
                   user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        invokeLLM(instance, promptMessages: promptMessages, parameters: parameters, tools: [], stop: stop, stream: true, user: user)
    }

    func invokeLLM(_ instance: ModelInstance, promptMessages: [PromptMessage], parameters: JSONObject, tools: [PromptMessageTool],
                   stop: [String], stream streamFlag: Bool, user: String?) -> AsyncThrowingStream<LLMResultChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LLMResultChunk, any Error>.makeStream()
        let task = Task {
            do {
                let (pluginId, name) = try Self.split(instance.provider)
                let data = PluginDaemonWire.llmInvokeData(provider: name, model: instance.modelName, credentials: instance.credentials,
                                                          promptMessages: promptMessages, parameters: parameters, tools: tools,
                                                          stop: stop, stream: streamFlag)
                let body = PluginDaemonWire.dispatchBody(userId: user, appId: appId, data: data)
                for try await chunk in daemon.dispatch("llm/invoke", pluginId: pluginId, body: body) {
                    continuation.yield(LLMResultChunk(json: chunk))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
