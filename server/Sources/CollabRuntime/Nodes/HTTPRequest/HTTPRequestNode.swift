// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/http_request/node.py,
// executor.py; the request body encoding follows httpx 0.28 (Dify's pin), which graphon hands the parts to.
// See ../../NOTICE.md.
//
// Not ported: `json_repair` (a JSON body must be valid JSON after variable substitution).

import Foundation

/// An insertion-ordered string map (Python's `dict[str, str]`): replacing keeps the position.
struct OrderedStrings: Sequence {
    private(set) var pairs: [(String, String)] = []
    subscript(key: String) -> String? {
        get { pairs.first { $0.0 == key }?.1 }
        set {
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[i].1 = newValue } else { pairs.remove(at: i) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
        }
    }
    var isEmpty: Bool { pairs.isEmpty }
    func makeIterator() -> IndexingIterator<[(String, String)]> { pairs.makeIterator() }
    func containsKey(caseInsensitive key: String) -> Bool { pairs.contains { $0.0.lowercased() == key.lowercased() } }
}

/// graphon's `Executor`: the request built from the node's templates, its log, and the call.
struct HTTPRequestExecutor {
    static let bodyTypeToContentType = ["json": "application/json", "x-www-form-urlencoded": "application/x-www-form-urlencoded",
                                        "form-data": "multipart/form-data", "raw-text": "text/plain"]

    let data: HTTPRequestNodeData
    let pool: VariablePool
    let config: HTTPRequestNodeConfig
    var auth: HTTPRequestNodeData.Authorization
    let timeout: (connect: Int, read: Int, write: Int)
    let sslVerify: Bool

    var url = ""
    var logURL = ""
    var params: [(String, String)]?
    var logParams: [(String, String)]?
    var headers = OrderedStrings()
    var logHeaders = OrderedStrings()
    var binaryContent: [UInt8]?
    var content: String?
    var logContent: String?
    var formData: OrderedStrings?
    var logFormData: OrderedStrings?
    /// (field, filename, content, mime type).
    var files: [(String, String, [UInt8], String)]?
    /// `self.json` (nil = Python's None).
    var json: JSONValue?
    var logJSONText: String?

    /// `SegmentGroup.log`, with secret values obfuscated as graphon's `SecretVariable.log`.
    static func logText(_ g: SegmentGroup) -> String {
        g.value.map { s in
            if s.valueType == .secret, case .string(let token) = s.value {
                if token.isEmpty { return token }
                if token.count <= 8 { return String(repeating: "*", count: 20) }
                return String(token.prefix(6)) + String(repeating: "*", count: 12) + String(token.suffix(2))
            }
            return s.log
        }.joined()
    }

    func convert(_ template: String) -> (text: String, log: String) {
        let g = VariableTemplate.convert(pool, template)
        return (g.text, Self.logText(g))
    }

    init(data: HTTPRequestNodeData, timeout: (connect: Int, read: Int, write: Int), pool: VariablePool, config: HTTPRequestNodeConfig) throws {
        self.data = data
        self.pool = pool
        self.config = config
        self.timeout = timeout
        auth = data.authorization
        if auth.type == "api-key" {
            guard var c = auth.config else { throw HTTPRequestNodeError.authorization("authorization config is required") }
            c.apiKey = VariableTemplate.convert(pool, c.apiKey).text
            if PyStr.strip(c.apiKey).isEmpty {
                throw HTTPRequestNodeError.authorization("API key is required for authorization but was empty. Please provide a valid API key.")
            }
            auth.config = c
        }
        sslVerify = data.sslVerify ?? config.sslVerify
        logURL = data.url
        try initURL()
        initParams()
        initHeaders()
        try initBody()
    }

    mutating func initURL() throws {
        (url, logURL) = convert(data.url)
        if url.isEmpty { throw HTTPRequestNodeError.url("url is required") }
        if !(url.hasPrefix("http://") || url.hasPrefix("https://")) { throw HTTPRequestNodeError.url("url should start with http:// or https://") }
    }

    mutating func initParams() {
        var result: [(String, String)] = [], log: [(String, String)] = []
        for raw in PyStr.splitlines(data.params) {
            let line = PyStr.strip(raw)
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = PyStr.strip(parts[0])
            if key.isEmpty { continue }
            let value = parts.count > 1 ? PyStr.strip(parts[1]) : ""
            let k = convert(key), v = convert(value)
            result.append((k.text, v.text))
            log.append((k.log, v.log))
        }
        if !result.isEmpty {
            params = result
            logParams = log
        }
    }

    /// `_parse_header_string`.
    static func parseHeaders(_ s: String) -> OrderedStrings {
        var out = OrderedStrings()
        for line in PyStr.splitlines(s) where !PyStr.strip(line).isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            out[PyStr.strip(parts[0])] = parts.count > 1 ? PyStr.strip(parts[1]) : ""
        }
        return out
    }

    mutating func initHeaders() {
        let g = VariableTemplate.convert(pool, data.headers)
        headers = Self.parseHeaders(g.text)
        logHeaders = Self.parseHeaders(Self.logText(g))
    }

    static func single(_ items: [HTTPRequestNodeData.BodyData], _ type: String) throws -> HTTPRequestNodeData.BodyData {
        guard items.count == 1 else { throw HTTPRequestNodeError.body("\(type) body type should have exactly one item") }
        return items[0]
    }

    mutating func initBody() throws {
        guard let body = data.body else { return }
        switch body.type {
        case "none":
            content = ""
        case "raw-text":
            (content, logContent) = convert(try Self.single(body.data, "raw-text").value)
        case "json":
            let (text, log) = convert(try Self.single(body.data, "json").value)
            logJSONText = log
            guard let parsed = try? JSONValue.parse(text) else { throw HTTPRequestNodeError.body("Failed to parse JSON: \(text)") }
            json = parsed == .null ? nil : parsed
        case "binary":
            _ = try Self.single(body.data, "binary") // File bytes are loaded asynchronously before invocation.
        case "x-www-form-urlencoded":
            (formData, logFormData) = convertKV(body.data, textOnly: false)
        case "form-data":
            (formData, logFormData) = convertKV(body.data, textOnly: true)
            // Keep graphon's placeholder when there are no selected file values.
            files = [("__multipart_placeholder__", "", [], "application/octet-stream")]
        default:
            break
        }
    }

    mutating func loadFileBodies(_ runtime: (any RuntimeFiles)?) async throws {
        guard let body = data.body else { return }
        if body.type == "binary" {
            let item = try Self.single(body.data, "binary")
            guard let selected = pool.get(item.file), selected.valueType == .file, let runtime else {
                throw HTTPRequestNodeError("FileFetchError", "cannot fetch file with selector \(PythonText.repr(.array(item.file.map(JSONValue.string))))")
            }
            let file = try await runtime.resolve(selected.value, config: nil)
            guard file.size <= config.maxBinarySize else { throw HTTPRequestNodeError.body("Binary file size exceeded") }
            binaryContent = try await runtime.bytes(file.json)
        } else if body.type == "form-data" {
            var parts: [(String, String, [UInt8], String)] = []
            var total = 0
            for item in body.data where item.type == "file" {
                guard let selected = pool.get(item.file) else { continue }
                let values = selected.valueType == .file ? [selected.value] : selected.valueType == .arrayFile ? (selected.value.array ?? []) : []
                for value in values {
                    guard let runtime else { throw HTTPRequestNodeError("FileFetchError", "File storage is not configured") }
                    let file = try await runtime.resolve(value, config: nil)
                    total += file.size
                    guard total <= config.maxBinarySize else { throw HTTPRequestNodeError.body("Multipart file size exceeded") }
                    parts.append((convert(item.key).text, file.filename, try await runtime.bytes(file.json), file.mimeType))
                }
            }
            if !parts.isEmpty { files = parts }
        }
    }

    func convertKV(_ items: [HTTPRequestNodeData.BodyData], textOnly: Bool) -> (OrderedStrings, OrderedStrings) {
        var real = OrderedStrings(), log = OrderedStrings()
        for item in items where !(textOnly && item.type != "text") {
            let k = convert(item.key), v = convert(item.value)
            real[k.text] = v.text
            log[k.log] = v.log
        }
        return (real, log)
    }

    // MARK: Headers

    func authorizationHeaders() -> [(String, String)] {
        guard auth.type == "api-key", let c = auth.config else { return [] }
        let header = c.header.isEmpty ? "Authorization" : c.header
        let key = c.apiKey
        switch c.type {
        case "bearer" where !key.isEmpty: return [(header, "Bearer \(key)")]
        case "basic" where !key.isEmpty:
            let encoded = key.contains(":") ? Data(key.utf8).base64EncodedString() : key
            return [(header, "Basic \(encoded)")]
        case "custom" where !header.isEmpty && !key.isEmpty: return [(header, key)]
        default: return []
        }
    }

    /// `_assembling_headers`: the given headers, the authorization header, the body's content type.
    func assembleHeaders(_ source: OrderedStrings) -> OrderedStrings {
        var h = source
        for (k, v) in authorizationHeaders() { h[k] = v }
        guard let body = data.body else { return h }
        if body.type == "form-data" {
            if let files, !files.isEmpty {
                var out = OrderedStrings()
                for (k, v) in h where k.lowercased() != "content-type" { out[k] = v }
                return out
            }
            if !h.containsKey(caseInsensitive: "content-type") { h["Content-Type"] = "multipart/form-data" }
            return h
        }
        if let ct = Self.bodyTypeToContentType[body.type], !h.containsKey(caseInsensitive: "content-type") { h["Content-Type"] = ct }
        return h
    }

    // MARK: The request (httpx's encoding)

    /// The URL with `params` merged into its query (httpx `copy_merge_params`: the new keys replace existing ones).
    func requestURL() -> String {
        guard let params else { return url }
        var base = url, fragment = ""
        if let h = base.firstIndex(of: "#") { fragment = String(base[h...]); base = String(base[..<h]) }
        var existing: [(String, String)] = []
        if let q = base.firstIndex(of: "?") {
            let query = String(base[base.index(after: q)...])
            base = String(base[..<q])
            for pair in query.split(separator: "&") where !pair.isEmpty {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                existing.append((kv[0], kv.count > 1 ? kv[1] : ""))
            }
        }
        let newKeys = Set(params.map(\.0))
        let merged = existing.filter { !newKeys.contains($0.0) } + params
        return base + "?" + PyStr.urlencode(merged) + fragment
    }

    static func formParam(_ name: String, _ value: String) -> String {
        name + "=\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "%22") + "\""
    }

    /// httpx `encode_request(content, data, files, json)` -> (body, default headers).
    func encodedBody() -> ([UInt8]?, [(String, String)]) {
        if let binaryContent { return (binaryContent, []) }
        if let content { return (Array(content.utf8), []) }
        if let files, !files.isEmpty {
            let boundary = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            var out: [UInt8] = []
            for (k, v) in formData ?? OrderedStrings() {
                out += Array("--\(boundary)\r\nContent-Disposition: form-data; \(Self.formParam("name", k))\r\n\r\n".utf8)
                out += Array(v.utf8) + Array("\r\n".utf8)
            }
            for (field, filename, bytes, mime) in files {
                var head = "--\(boundary)\r\nContent-Disposition: form-data; \(Self.formParam("name", field))"
                if !filename.isEmpty { head += "; " + Self.formParam("filename", filename) }
                head += "\r\nContent-Type: \(mime)\r\n\r\n"
                out += Array(head.utf8) + bytes + Array("\r\n".utf8)
            }
            out += Array("--\(boundary)--\r\n".utf8)
            return (out, [("Content-Type", "multipart/form-data; boundary=\(boundary)")])
        }
        if let formData, !formData.isEmpty {
            return (Array(PyStr.urlencode(formData.pairs).utf8), [("Content-Type", "application/x-www-form-urlencoded")])
        }
        if let json { return (Array(json.compactJSON().utf8), [("Content-Type", "application/json")]) }
        return (nil, [])
    }

    func buildRequest() throws -> RuntimeHTTPRequest {
        let method = data.method.lowercased()
        guard ["get", "head", "post", "put", "delete", "patch"].contains(method) else {
            throw HTTPRequestNodeError("InvalidHttpMethodError", "Invalid http method \(data.method)")
        }
        var headers = assembleHeaders(headers)
        let (body, defaults) = encodedBody()
        for (k, v) in defaults where !headers.containsKey(caseInsensitive: k) { headers[k] = v }
        return RuntimeHTTPRequest(method: method.uppercased(), url: requestURL(), headers: headers.pairs.map { ($0.0, $0.1) }, body: body,
                                  connectTimeout: Double(timeout.connect), readTimeout: Double(timeout.read),
                                  writeTimeout: Double(timeout.write), followRedirects: true, verifySSL: sslVerify)
    }

    /// `invoke`: one call (no executor retries: the engine retries the node), then the size check.
    func invoke(_ client: any RuntimeHTTPClient) async throws -> HTTPNodeResponse {
        let request = try buildRequest()
        let raw: RuntimeHTTPResponse
        do {
            raw = try await client.send(request)
        } catch RuntimeHTTPError.request(let message) {
            throw HTTPRequestNodeError("HttpRequestNodeError", message)
        }
        let response = HTTPNodeResponse(raw)
        let threshold = response.isFile ? config.maxBinarySize : config.maxTextSize
        if response.size > threshold {
            throw HTTPRequestNodeError("ResponseSizeError", "\(response.isFile ? "File" : "Text") size is too large, max size is "
                                       + String(format: "%.2f", Double(threshold) / 1024 / 1024)
                                       + " MB, but current size is \(response.readableSize).")
        }
        return response
    }

    // MARK: The log (`to_log`)

    func toLog() -> String {
        let parts = PyStr.urlparse(logURL)
        var path = parts.path.isEmpty ? "/" : parts.path
        if let logParams { path += "?" + PyStr.urlencode(logParams) } else if !parts.query.isEmpty { path += "?" + parts.query }
        var raw = "\(data.method.uppercased()) \(path) HTTP/1.1\r\n"
        raw += "Host: \(parts.netloc)\r\n"
        let boundary = "----WebKitFormBoundary" + String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
        var headers = assembleHeaders(logHeaders)
        if let body = data.body {
            if !logHeaders.containsKey(caseInsensitive: "content-type"), let ct = Self.bodyTypeToContentType[body.type] { headers["Content-Type"] = ct }
            if body.type == "form-data" { headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)" }
        }
        let authHeader = (auth.config?.header).flatMap { $0.isEmpty ? nil : $0 } ?? "Authorization"
        for (k, v) in headers {
            let masked = auth.type == "api-key" && k.lowercased() == authHeader.lowercased() ? String(repeating: "*", count: v.unicodeScalars.count) : v
            raw += "\(k): \(masked)\r\n"
        }
        let bodyString = logBody(boundary)
        if !bodyString.isEmpty { raw += "Content-Length: \(bodyString.unicodeScalars.count)\r\n" }
        raw += "\r\n"
        raw += bodyString
        return raw
    }

    func logBody(_ boundary: String) -> String {
        if let files, !files.allSatisfy({ $0.0 == "__multipart_placeholder__" }) {
            var s = ""
            for (key, filename, bytes, mime) in files {
                s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n"
                s += "<file_content_binary: '\(filename.isEmpty ? "unknown" : filename)', type='\(mime)', size=\(bytes.count) bytes>\r\n"
            }
            return s + "--\(boundary)--\r\n"
        }
        guard let body = data.body else { return "" }
        if let content, !content.isEmpty { return logContent ?? "" }
        if let formData, !formData.isEmpty, body.type == "x-www-form-urlencoded" { return PyStr.urlencode(logFormData?.pairs ?? []) }
        if let formData, !formData.isEmpty, body.type == "form-data" {
            var s = ""
            for (k, v) in logFormData ?? OrderedStrings() { s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n" }
            return s + "--\(boundary)--\r\n"
        }
        if let json, json.isTruthy { return logJSONText ?? "" }
        if body.type == "raw-text" { return logContent ?? "" }
        return ""
    }
}

/// The HTTP request node: one request through the SSRF proxy; outputs `status_code`, `body`, `headers`, `files`.
public struct HTTPRequestNode: RuntimeNode {
    public let id: String
    public let data: HTTPRequestNodeData
    let client: any RuntimeHTTPClient
    let config: HTTPRequestNodeConfig
    let fileRuntime: (any RuntimeFiles)?

    public var nodeType: String { NodeType.httpRequest }
    public var base: BaseNodeData { data.base }
    public var retryEnabled: Bool { data.base.retryConfig.retryEnabled }

    /// A file response requires configured storage; unsupported configuration must not look like an empty success.
    static let fileResponseError = "File storage is not configured for HTTP file responses"

    public init(id: String, data: JSONObject, client: any RuntimeHTTPClient, files: (any RuntimeFiles)? = nil) throws {
        self.id = id
        self.data = try HTTPRequestNodeData(data)
        self.client = client
        config = client.requestConfig
        fileRuntime = files
    }

    /// `_get_request_timeout`: the node's timeouts, 0 / missing ones the configured maxima.
    var requestTimeout: (connect: Int, read: Int, write: Int) {
        let t = data.timeout
        func pick(_ v: Int?, _ d: Int) -> Int { (v ?? 0) != 0 ? v! : d }
        return (pick(t?.connect, config.maxConnectTimeout), pick(t?.read, config.maxReadTimeout), pick(t?.write, config.maxWriteTimeout))
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var processData = JSONObject()
        do {
            var executor = try HTTPRequestExecutor(data: data, timeout: requestTimeout, pool: context.pool, config: config)
            try await executor.loadFileBodies(fileRuntime)
            processData["request"] = .string(executor.toLog())
            let response = try await executor.invoke(client)
            var responseFiles: [JSONValue] = []
            if response.isFile {
                guard let fileRuntime else {
                    await emit(.completed(NodeRunResult(status: .failed, processData: ["request": .string(executor.toLog())],
                                                        error: Self.fileResponseError, errorType: "HttpRequestNodeError")))
                    return
                }
                let suggested = response.contentDisposition?.filename ?? URL(string: executor.url)?.lastPathComponent ?? ""
                let ext = (suggested as NSString).pathExtension
                let mime = response.contentType.components(separatedBy: ";")[0]
                let suffix = ext.isEmpty ? (["image/png": "png", "image/jpeg": "jpg", "application/pdf": "pdf", "text/plain": "txt"][mime] ?? "bin") : ext
                let file = try await fileRuntime.save(bytes: response.content, filename: UUIDHex.make() + "." + suffix,
                                                     mimeType: mime, sourceURL: nil)
                responseFiles = [file.json]
            }
            let outputs: JSONObject = ["status_code": .int(response.status), "body": .string(response.isFile ? "" : response.text),
                                       "headers": .object(response.headers), "files": .array(responseFiles)]
            if !response.isSuccess && (base.errorStrategy != nil || retryEnabled) {
                await emit(.completed(NodeRunResult(status: .failed, processData: ["request": .string(executor.toLog())], outputs: outputs,
                                                    error: "Request failed with status code \(response.status)",
                                                    errorType: "HTTPResponseCodeError")))
                return
            }
            var result = NodeRunResult(status: .succeeded, processData: ["request": .string(executor.toLog())], outputs: outputs)
            result.outputTypes["files"] = .arrayFile
            await emit(.completed(result))
        } catch let e as HTTPRequestNodeError {
            await emit(.completed(NodeRunResult(status: .failed, processData: processData, error: e.message, errorType: e.kind)))
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var keys: [String] = []
        func templates(_ ts: String...) { for t in ts { keys += VariableTemplate.matches(in: t).map(\.key) } }
        templates(data.url, data.headers, data.params)
        if let body = data.body {
            switch body.type {
            case "binary": if body.data.count == 1 { keys.append("#" + body.data[0].file.joined(separator: ".") + "#") }
            case "json", "raw-text": if body.data.count == 1 { templates(body.data[0].key, body.data[0].value) }
            case "x-www-form-urlencoded": for item in body.data { templates(item.key, item.value) }
            case "form-data":
                for item in body.data {
                    templates(item.key)
                    if item.type == "text" { templates(item.value) } else { keys.append("#" + item.file.joined(separator: ".") + "#") }
                }
            default: break
            }
        }
        var out: [(String, [String])] = []
        for key in keys {
            let selector = String(key.dropFirst().dropLast()).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let k = id + "." + key
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1 = selector } else { out.append((k, selector)) }
        }
        return out
    }
}

extension BuiltinNodeFactory {
    /// Dify's factory: the SSRF-proxied client (`graphon_ssrf_proxy`) and `HTTP_REQUEST_*`.
    func makeHTTPRequest(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        guard let http = services.http else { throw ServiceNotConfigured(service: .http) }
        return try HTTPRequestNode(id: config.id, data: config.data, client: http, files: services.files)
    }
}
