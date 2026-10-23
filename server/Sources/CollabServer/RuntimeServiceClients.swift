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

    public func send(_ request: RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse {
        try await CurlRuntimeHTTP.send(request, proxy: proxyURL,
                                       limit: max(1, max(requestConfig.maxBinarySize, requestConfig.maxTextSize) + 1))
    }
}
