// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/http (HttpClientProtocol,
// HttpResponse), graphon/nodes/http_request/config.py (HttpRequestNodeConfig); Dify 1.17.1 (Apache-2.0 with Dify's
// conditions): api/core/helper/ssrf_proxy.py, api/configs/feature/__init__.py (HTTP_REQUEST_*). See ../NOTICE.md.

/// HTTP for the HTTP request node (Dify: `ssrf_proxy.make_request`, through the SSRF proxy). The server implements it;
/// tests use fakes. One request, no retries (the engine retries the node), redirects as the request says.
public protocol RuntimeHTTPClient: Sendable {
    /// Throws `RuntimeHTTPError`.
    func send(_ request: RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse

    /// Dify's HTTP request node limits (`HTTP_REQUEST_*`).
    var requestConfig: HTTPRequestNodeConfig { get }
}

extension RuntimeHTTPClient {
    public var requestConfig: HTTPRequestNodeConfig { .difyDefaults }
}

/// What can go wrong sending a request.
public enum RuntimeHTTPError: Error, CustomStringConvertible, Sendable {
    /// httpx's `RequestError` (connect, timeout, protocol): the node fails with this text (`HttpRequestNodeError`).
    case request(String)
    /// Dify's `ToolSSRFError`: the SSRF proxy refused the destination (the node fails with it as an unexpected error).
    case ssrfBlocked(String)

    public var description: String {
        switch self {
        case .request(let m), .ssrfBlocked(let m): return m
        }
    }
}

/// `HttpRequestNodeConfig` (`build_http_request_config`).
public struct HTTPRequestNodeConfig: Sendable, Hashable {
    /// Seconds.
    public var maxConnectTimeout: Int
    public var maxReadTimeout: Int
    public var maxWriteTimeout: Int
    /// Bytes.
    public var maxBinarySize: Int
    public var maxTextSize: Int
    public var sslVerify: Bool

    public init(maxConnectTimeout: Int = 10, maxReadTimeout: Int = 600, maxWriteTimeout: Int = 600, maxBinarySize: Int = 10 * 1024 * 1024,
                maxTextSize: Int = 1024 * 1024, sslVerify: Bool = true) {
        self.maxConnectTimeout = maxConnectTimeout
        self.maxReadTimeout = maxReadTimeout
        self.maxWriteTimeout = maxWriteTimeout
        self.maxBinarySize = maxBinarySize
        self.maxTextSize = maxTextSize
        self.sslVerify = sslVerify
    }

    public static let difyDefaults = HTTPRequestNodeConfig()
}

public struct RuntimeHTTPRequest: Sendable {
    public var method: String
    /// The full URL (query included).
    public var url: String
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]?
    /// Seconds.
    public var connectTimeout: Double
    public var readTimeout: Double
    public var writeTimeout: Double
    public var followRedirects: Bool
    public var verifySSL: Bool

    public init(method: String, url: String, headers: [(name: String, value: String)] = [], body: [UInt8]? = nil, connectTimeout: Double = 10,
                readTimeout: Double = 60, writeTimeout: Double = 20, followRedirects: Bool = true, verifySSL: Bool = true) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.followRedirects = followRedirects
        self.verifySSL = verifySSL
    }
}

public struct RuntimeHTTPResponse: Sendable {
    public var status: Int
    /// As received (names as sent; repeated names repeated).
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]
    public init(status: Int, headers: [(name: String, value: String)], body: [UInt8]) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
