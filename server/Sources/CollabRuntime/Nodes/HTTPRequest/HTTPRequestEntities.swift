// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/http_request/entities.py,
// exc.py, graphon/http/response.py (text decoding). See ../../NOTICE.md.

import Foundation

/// `HttpRequestNodeData`.
public struct HTTPRequestNodeData: Sendable {
    public struct Authorization: Sendable {
        /// `no-auth` or `api-key`.
        public var type: String
        /// `basic`, `bearer` or `custom`; nil for `no-auth`.
        public var config: (type: String, apiKey: String, header: String)?
    }

    public struct BodyData: Sendable {
        public var key = ""
        /// `file` or `text`.
        public var type: String
        public var value = ""
        public var file: [String] = []
    }

    public struct Body: Sendable {
        public var type: String
        public var data: [BodyData]
    }

    public struct Timeout: Sendable {
        public var connect: Int?
        public var read: Int?
        public var write: Int?
    }

    public var base: BaseNodeData
    public var method: String
    public var url: String
    public var authorization: Authorization
    public var headers: String
    public var params: String
    public var body: Body?
    public var timeout: Timeout?
    public var sslVerify: Bool?

    static let methods: Set<String> = ["get", "post", "put", "patch", "delete", "head", "options", "GET", "POST", "PUT", "PATCH", "DELETE",
                                       "HEAD", "OPTIONS"]
    static let bodyTypes: Set<String> = ["none", "form-data", "x-www-form-urlencoded", "raw-text", "json", "binary"]

    public init(_ data: JSONObject) throws {
        base = try BaseNodeData(data)
        guard let m = data["method"]?.string, Self.methods.contains(m) else { throw NodeDataError("method: Input should be a supported HTTP method") }
        method = m
        guard let u = data["url"]?.string else { throw NodeDataError("url: Field required") }
        url = u
        guard let auth = data["authorization"]?.object, let at = auth["type"]?.string, at == "no-auth" || at == "api-key" else {
            throw NodeDataError("authorization.type: Input should be 'no-auth' or 'api-key'")
        }
        if at == "no-auth" {
            authorization = Authorization(type: at, config: nil)
        } else {
            guard case .object(let c)? = auth["config"], !c.isEmpty else { throw NodeDataError("authorization.config: config should be a dict") }
            guard let ct = c["type"]?.string, ["basic", "bearer", "custom"].contains(ct) else {
                throw NodeDataError("authorization.config.type: Input should be 'basic', 'bearer' or 'custom'")
            }
            guard let key = c["api_key"]?.string else { throw NodeDataError("authorization.config.api_key: Field required") }
            authorization = Authorization(type: at, config: (ct, key, c["header"]?.string ?? ""))
        }
        guard let h = data["headers"]?.string else { throw NodeDataError("headers: Field required") }
        headers = h
        guard let p = data["params"]?.string else { throw NodeDataError("params: Field required") }
        params = p
        if case .object(let b)? = data["body"] {
            guard let bt = b["type"]?.string, Self.bodyTypes.contains(bt) else { throw NodeDataError("body.type: Input should be a supported body type") }
            var items: [BodyData] = []
            switch b["data"] {
            case .string(let s)? where !s.isEmpty: items = [BodyData(type: "text", value: s)]
            case .array(let a)? where !a.isEmpty:
                items = try a.map { d in
                    guard let t = d["type"]?.string, t == "file" || t == "text" else { throw NodeDataError("body.data.type: Input should be 'file' or 'text'") }
                    return BodyData(key: d["key"]?.string ?? "", type: t, value: d["value"]?.string ?? "",
                                    file: (d["file"]?.array ?? []).compactMap(\.string))
                }
            default: items = []
            }
            body = Body(type: bt, data: items)
        }
        if case .object(let t)? = data["timeout"] {
            timeout = Timeout(connect: t["connect"]?.int, read: t["read"]?.int, write: t["write"]?.int)
        }
        sslVerify = data["ssl_verify"]?.bool
    }
}

/// `HttpRequestNodeError` and its subclasses (`error_type` is the class name).
public struct HTTPRequestNodeError: Error, CustomStringConvertible, Sendable {
    public var kind: String
    public var message: String
    public init(_ kind: String, _ message: String) {
        self.kind = kind
        self.message = message
    }
    public var description: String { message }

    static func authorization(_ m: String) -> Self { Self("AuthorizationConfigError", m) }
    static func url(_ m: String) -> Self { Self("InvalidURLError", m) }
    static func body(_ m: String) -> Self { Self("RequestBodyError", m) }
}

/// The executor's view of a response (`entities.Response` over graphon's `HttpResponse`).
struct HTTPNodeResponse {
    let status: Int
    /// `dict(httpx.Headers)`: lower-case names, repeated ones joined with ", ".
    let headers: JSONObject
    let content: [UInt8]

    init(_ r: RuntimeHTTPResponse) {
        status = r.status
        var h = JSONObject()
        for (name, value) in r.headers {
            let k = name.lowercased()
            if let existing = h[k]?.string { h[k] = .string(existing + ", " + value) } else { h[k] = .string(value) }
        }
        headers = h
        content = r.body
    }

    var isSuccess: Bool { (200..<300).contains(status) }
    var contentType: String { headers["content-type"]?.string ?? "" }
    var size: Int { content.count }

    var readableSize: String {
        if size < 1024 { return "\(size) bytes" }
        if size < 1024 * 1024 { return String(format: "%.2f KB", Double(size) / 1024) }
        return String(format: "%.2f MB", Double(size) / 1024 / 1024)
    }

    /// `HttpResponse.text`: the content-type's charset, else UTF-8 with replacement (httpx's default).
    var text: String {
        let params = contentType.split(separator: ";").dropFirst()
        for p in params {
            let kv = p.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].lowercased() == "charset" else { continue }
            let cs = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            switch cs {
            case "utf-8", "utf8": return String(decoding: content, as: UTF8.self)
            case "latin-1", "latin1", "iso-8859-1", "iso8859-1", "us-ascii", "ascii":
                return String(bytes: content, encoding: .isoLatin1) ?? String(decoding: content, as: UTF8.self)
            case "utf-16": return String(bytes: content, encoding: .utf16) ?? String(decoding: content, as: UTF8.self)
            default: break
            }
        }
        return String(decoding: content, as: UTF8.self)
    }

    /// `parsed_content_disposition`: (type, filename).
    var contentDisposition: (type: String, filename: String?)? {
        guard let cd = headers["content-disposition"]?.string, !cd.isEmpty else { return nil }
        let parts = cd.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var filename: String?
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            var v = kv[1].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if name == "filename*" {
                if let r = v.range(of: "''") { v = String(v[r.upperBound...]) }
                filename = v.removingPercentEncoding ?? v
            } else if name == "filename", filename == nil {
                filename = v
            }
        }
        return ((parts.first ?? "").lowercased(), filename)
    }

    static let binaryMainTypes: Set<String> = ["application", "image", "audio", "video"]
    static let textBasedApplicationTypes = ["json", "xml", "javascript", "x-www-form-urlencoded", "yaml", "graphql"]
    static let textMarkers: [[UInt8]] = ["{", "[", "<", "function", "var ", "const ", "let "].map { Array($0.utf8) }
    /// Content types Python's `mimetypes` knows an extension for, outside image / audio / video (those are binary anyway).
    static let knownApplicationTypes: Set<String> = [
        "application/octet-stream", "application/pdf", "application/zip", "application/gzip", "application/x-gzip", "application/x-tar",
        "application/x-bzip2", "application/x-7z-compressed", "application/x-rar-compressed", "application/msword", "application/rtf",
        "application/vnd.ms-excel", "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/epub+zip", "application/wasm",
        "application/java-archive", "application/x-shockwave-flash", "application/postscript", "application/x-msdownload",
        "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.spreadsheet", "application/x-sqlite3",
        "application/x-python-code", "application/pkcs7-mime", "application/x-pkcs12", "application/x-x509-ca-cert",
        "application/vnd.android.package-archive", "application/x-iso9660-image", "application/mp4", "application/ogg",
    ]

    /// `Response.is_file`.
    var isFile: Bool {
        let ct = (contentType.split(separator: ";").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let cd = contentDisposition, cd.type == "attachment" || cd.filename != nil { return true }
        if ct.hasPrefix("text/") && !ct.contains("csv") { return false }
        if ct.hasPrefix("application/") {
            if Self.textBasedApplicationTypes.contains(where: { ct.contains($0) }) { return false }
            let sample = Array(content.prefix(1024))
            if String(validating: sample, as: UTF8.self) != nil, Self.textMarkers.contains(where: { m in Self.contains(sample, m) }) {
                return false
            }
        }
        let main = ct.split(separator: "/").first.map(String.init) ?? ""
        if ["image", "audio", "video"].contains(main) && ct.contains("/") { return true }
        if Self.knownApplicationTypes.contains(ct) { return true }
        if ct.hasPrefix("text/") { return false }
        return ["image/", "audio/", "video/"].contains { ct.contains($0) }
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= hay.count else { return false }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle { return true }
        return false
    }
}

/// Python string helpers the executor relies on.
enum PyStr {
    /// `str.splitlines()`.
    static func splitlines(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previousCR = false
        for u in s.unicodeScalars {
            if previousCR && u == "\n" { previousCR = false; continue }
            previousCR = false
            switch u.value {
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                out.append(current); current = ""
            case 0x0D:
                out.append(current); current = ""; previousCR = true
            default:
                current.unicodeScalars.append(u)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `urllib.parse.quote_plus` (safe: letters, digits, `_.-~`).
    static func quotePlus(_ s: String) -> String {
        var out = ""
        for b in Array(s.utf8) {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"):
                out.unicodeScalars.append(UnicodeScalar(b))
            case UInt8(ascii: " "): out += "+"
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// `urlencode(list of pairs)`.
    static func urlencode(_ pairs: [(String, String)]) -> String {
        pairs.map { quotePlus($0.0) + "=" + quotePlus($0.1) }.joined(separator: "&")
    }

    /// `urlparse`: (netloc, path, query).
    static func urlparse(_ url: String) -> (netloc: String, path: String, query: String) {
        var rest = Substring(url)
        if let r = rest.range(of: "://") { rest = rest[r.upperBound...] } else { return ("", url, "") }
        if let h = rest.firstIndex(of: "#") { rest = rest[..<h] }
        let netEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        let netloc = String(rest[..<netEnd])
        rest = rest[netEnd...]
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        return (netloc, String(rest), query)
    }
}
