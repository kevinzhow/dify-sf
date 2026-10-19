// Ported from Dify 1.17.1 (https://github.com/langgenius/dify, Apache-2.0 with Dify's conditions):
// api/core/helper/code_executor/code_executor.py (CodeExecutor.execute_code: the sandbox call and its errors),
// api/core/helper/ssrf_proxy.py (make_request: proxy, Host header, Squid's refusal), api/configs/feature/__init__.py
// (CODE_EXECUTION_*, CODE_*, TEMPLATE_TRANSFORM_MAX_LENGTH, HTTP_REQUEST_*).

import AsyncHTTPClient
import CollabRuntime
import Configuration
import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import Synchronization

/// Runtime services configuration (protocol 1.14): the code sandbox, the SSRF proxy and Dify's node limits.
public struct RuntimeServicesConfig: Sendable {
    /// Dify's `CODE_EXECUTION_ENDPOINT`, e.g. `http://sandbox:8194` (`COLLAB_SANDBOX_URL`). Empty = no sandbox: code and
    /// template transform nodes (and Jinja2 prompts) cannot run.
    public var sandboxURL: String
    /// `CODE_EXECUTION_API_KEY` (`COLLAB_SANDBOX_KEY`), sent as `X-Api-Key`.
    public var sandboxKey: String
    /// `CODE_EXECUTION_CONNECT_TIMEOUT` / `_READ_` / `_WRITE_` (seconds).
    public var sandboxConnectTimeout: Double
    public var sandboxReadTimeout: Double
    public var sandboxWriteTimeout: Double
    /// Dify's `SSRF_PROXY_ALL_URL` (`COLLAB_SSRF_PROXY_URL`), e.g. `http://ssrf_proxy:3128`: every HTTP request node call goes
    /// through it. Empty = direct requests (no SSRF protection, as Dify without a proxy).
    public var ssrfProxyURL: String
    public var codeLimits: CodeNodeLimits
    public var httpRequest: HTTPRequestNodeConfig

    public init(reader: ConfigReader) {
        sandboxURL = reader.string(forKey: "collab.sandbox.url", default: "").trimmingCharacters(in: .whitespaces)
        sandboxKey = reader.string(forKey: "collab.sandbox.key", isSecret: true, default: "dify-sandbox")
        sandboxConnectTimeout = reader.double(forKey: "collab.sandbox.connectTimeoutSeconds", default: 10)
        sandboxReadTimeout = reader.double(forKey: "collab.sandbox.readTimeoutSeconds", default: 60)
        sandboxWriteTimeout = reader.double(forKey: "collab.sandbox.writeTimeoutSeconds", default: 10)
        ssrfProxyURL = reader.string(forKey: "collab.ssrfProxy.url", default: "").trimmingCharacters(in: .whitespaces)
        let d = CodeNodeLimits.difyDefaults
        codeLimits = CodeNodeLimits(
            maxStringLength: reader.int(forKey: "collab.code.maxStringLength", default: d.maxStringLength),
            maxNumber: reader.int(forKey: "collab.code.maxNumber", default: d.maxNumber),
            minNumber: reader.int(forKey: "collab.code.minNumber", default: d.minNumber),
            maxPrecision: reader.int(forKey: "collab.code.maxPrecision", default: d.maxPrecision),
            maxDepth: reader.int(forKey: "collab.code.maxDepth", default: d.maxDepth),
            maxNumberArrayLength: reader.int(forKey: "collab.code.maxNumberArrayLength", default: d.maxNumberArrayLength),
            maxStringArrayLength: reader.int(forKey: "collab.code.maxStringArrayLength", default: d.maxStringArrayLength),
            maxObjectArrayLength: reader.int(forKey: "collab.code.maxObjectArrayLength", default: d.maxObjectArrayLength),
            templateTransformMaxLength: reader.int(forKey: "collab.templateTransform.maxLength", default: d.templateTransformMaxLength))
        let h = HTTPRequestNodeConfig.difyDefaults
        httpRequest = HTTPRequestNodeConfig(
            maxConnectTimeout: reader.int(forKey: "collab.httpRequest.maxConnectTimeout", default: h.maxConnectTimeout),
            maxReadTimeout: reader.int(forKey: "collab.httpRequest.maxReadTimeout", default: h.maxReadTimeout),
            maxWriteTimeout: reader.int(forKey: "collab.httpRequest.maxWriteTimeout", default: h.maxWriteTimeout),
            maxBinarySize: reader.int(forKey: "collab.httpRequest.maxBinarySize", default: h.maxBinarySize),
            maxTextSize: reader.int(forKey: "collab.httpRequest.maxTextSize", default: h.maxTextSize),
            sslVerify: reader.bool(forKey: "collab.httpRequest.sslVerify", default: h.sslVerify))
    }

    /// The sandbox client, nil without `COLLAB_SANDBOX_URL`.
    public var codeExecutor: SandboxCodeExecutor? {
        sandboxURL.isEmpty ? nil : SandboxCodeExecutor(baseURL: sandboxURL, key: sandboxKey, connectTimeout: sandboxConnectTimeout,
                                                       readTimeout: sandboxReadTimeout, writeTimeout: sandboxWriteTimeout, limits: codeLimits)
    }

    /// The HTTP request node's client (always available; through the proxy when one is configured).
    public var httpClient: SSRFProxyHTTPClient { SSRFProxyHTTPClient(proxyURL: ssrfProxyURL, requestConfig: httpRequest) }

    /// Everything nodes call outside the runtime: `models` (plugin daemon), the sandbox, Jinja2 through it, HTTP.
    public func services(models: (any ModelRuntime)?) -> RuntimeServices {
        let executor = codeExecutor
        return RuntimeServices(models: models, jinja2: executor.map { SandboxJinja2Renderer(executor: $0) }, codeExecutor: executor,
                               http: httpClient)
    }
}

/// Dify's sandbox client (`CodeExecutor.execute_code`): `POST {url}/v1/sandbox/run` `{language, code, preload,
/// enable_network}` with `X-Api-Key`; answer `{code, message, data: {stdout, error}}`.
public struct SandboxCodeExecutor: CodeExecutor {
    let client: HTTPClient
    public let baseURL: String
    let key: String
    let connectTimeout: Double
    let readTimeout: Double
    let writeTimeout: Double
    public let limits: CodeNodeLimits

    public init(client: HTTPClient = .shared, baseURL: String, key: String, connectTimeout: Double = 10, readTimeout: Double = 60,
                writeTimeout: Double = 10, limits: CodeNodeLimits = .difyDefaults) {
        self.client = client
        var b = baseURL
        while b.hasSuffix("/") { b.removeLast() }
        self.baseURL = b
        self.key = key
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.limits = limits
    }

    /// Answers larger than this are refused (the sandbox caps output far below).
    static let maxAnswer = 64 << 20

    public func run(language: String, code: String, preload: String, enableNetwork: Bool) async throws -> String {
        var req = HTTPClientRequest(url: "\(baseURL)/v1/sandbox/run")
        req.method = .POST
        req.headers.add(name: "X-Api-Key", value: key)
        req.headers.add(name: "Content-Type", value: "application/json")
        let body: JSONValue = ["language": .string(language), "code": .string(code), "preload": .string(preload),
                               "enable_network": .bool(enableNetwork)]
        req.body = .bytes(ByteBuffer(string: body.compactJSON()))
        let bytes: [UInt8]
        do {
            let timeout = TimeAmount.milliseconds(Int64((connectTimeout + readTimeout + writeTimeout) * 1000))
            let res = try await client.execute(req, timeout: timeout)
            if res.status.code == 503 { throw CodeExecutionError("Code execution service is unavailable") }
            if res.status.code != 200 {
                throw Unexpected(text: "Failed to execute code, got status code \(res.status.code), please check if the sandbox service is running")
            }
            let buffer = try await res.body.collect(upTo: Self.maxAnswer)
            bytes = Array(buffer.readableBytesView)
        } catch let e as CodeExecutionError {
            throw e
        } catch {
            throw CodeExecutionError("Failed to execute code, which is likely a network issue, please check if the sandbox service is running."
                                     + " ( Error: \(Self.describe(error)) )")
        }
        guard case .object(let answer)? = try? JSONValue.parse(bytes) else { throw CodeExecutionError("Failed to parse response") }
        let status = answer["code"]
        if status?.int != 0 {
            throw CodeExecutionError("Got error code: \(status.map { PythonText.str($0) } ?? "None"). Got error msg: \(answer["message"].map { PythonText.str($0) } ?? "None")")
        }
        if let error = answer["data"]?["error"]?.string, !error.isEmpty { throw CodeExecutionError(error) }
        return answer["data"]?["stdout"]?.string ?? ""
    }

    struct Unexpected: Error, CustomStringConvertible { var text: String; var description: String { text } }

    static func describe(_ error: any Error) -> String {
        if let e = error as? Unexpected { return e.text }
        if let e = error as? HTTPClientError {
            switch e {
            case .connectTimeout: return "connection timed out"
            case .deadlineExceeded: return "timed out"
            case .remoteConnectionClosed: return "the connection was closed"
            default: return "\(e)"
            }
        }
        return "\(error)"
    }
}

/// The HTTP request node's client (Dify's `ssrf_proxy.make_request` with `max_retries=0`): through the SSRF proxy (Squid)
/// when configured, the node's timeouts and SSL setting, redirects followed, the user's `Host` header kept; a 401/403 from
/// Squid is Dify's "blocked by SSRF protection" error.
public struct SSRFProxyHTTPClient: RuntimeHTTPClient {
    public let proxyURL: String
    public let requestConfig: HTTPRequestNodeConfig

    public init(proxyURL: String, requestConfig: HTTPRequestNodeConfig = .difyDefaults) {
        self.proxyURL = proxyURL
        self.requestConfig = requestConfig
    }

    struct ClientKey: Hashable {
        var proxy: String
        var verify: Bool
        var connect: Int64
        var read: Int64
    }

    /// One long-lived client per (proxy, SSL verification, timeouts): AsyncHTTPClient's timeouts are per client.
    static let clients = Mutex<[ClientKey: HTTPClient]>([:])

    static func client(_ key: ClientKey) -> HTTPClient {
        clients.withLock { cache in
            if let c = cache[key] { return c }
            var tls = TLSConfiguration.makeClientConfiguration()
            if !key.verify { tls.certificateVerification = .none }
            var config = HTTPClient.Configuration(tlsConfiguration: tls, redirectConfiguration: .follow(max: 20, allowCycles: false),
                                                  timeout: .init(connect: .milliseconds(key.connect), read: .milliseconds(key.read)))
            if let (host, port) = Self.hostPort(key.proxy) { config.proxy = .server(host: host, port: port) }
            config.decompression = .enabled(limit: .none)
            let c = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
            cache[key] = c
            return c
        }
    }

    static func hostPort(_ url: String) -> (String, Int)? {
        guard !url.isEmpty, let u = URL(string: url), let host = u.host else { return nil }
        return (host, u.port ?? (u.scheme == "https" ? 443 : 80))
    }

    public func send(_ request: RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse {
        let key = ClientKey(proxy: proxyURL, verify: request.verifySSL, connect: Int64(request.connectTimeout * 1000),
                            read: Int64(request.readTimeout * 1000))
        let client = Self.client(key)
        var req = HTTPClientRequest(url: request.url)
        req.method = HTTPMethod(rawValue: request.method)
        var userHost: String?
        for (name, value) in request.headers {
            if name.lowercased() == "host" { userHost = value; continue }
            req.headers.add(name: name, value: value)
        }
        if let userHost { req.headers.add(name: "host", value: userHost) }
        if let body = request.body { req.body = .bytes(ByteBuffer(bytes: body)) }
        let limit = max(requestConfig.maxBinarySize, requestConfig.maxTextSize) + 1
        do {
            let total = TimeAmount.milliseconds(Int64((request.connectTimeout + request.readTimeout + request.writeTimeout) * 1000))
            let res = try await client.execute(req, timeout: total)
            let headers = res.headers.map { ($0.name, $0.value) }
            if res.status.code == 401 || res.status.code == 403 {
                let server = (res.headers.first(name: "server") ?? "").lowercased()
                let via = (res.headers.first(name: "via") ?? "").lowercased()
                if server.contains("squid") || via.contains("squid") {
                    throw RuntimeHTTPError.ssrfBlocked(
                        "Access to '\(request.url)' was blocked by SSRF protection (e.g. SSRF_PROXY_ALLOW_PRIVATE_IPS=172.21.0.0/16 to "
                            + "allow 172.21.0.0/16). The URL resolves to a private, loopback, link-local, or otherwise non-public network "
                            + "address. See https://github.com/langgenius/dify/issues/38443.")
                }
            }
            // Read at most one byte past the node's largest limit: the node reports the size error.
            var body: [UInt8] = []
            for try await chunk in res.body {
                body.append(contentsOf: chunk.readableBytesView.prefix(limit - body.count))
                if body.count >= limit { break }
            }
            return RuntimeHTTPResponse(status: Int(res.status.code), headers: headers, body: body)
        } catch let e as RuntimeHTTPError {
            throw e
        } catch {
            throw RuntimeHTTPError.request(SandboxCodeExecutor.describe(error))
        }
    }
}
