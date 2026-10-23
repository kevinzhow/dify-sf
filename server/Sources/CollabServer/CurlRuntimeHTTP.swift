import CollabRuntime
import Foundation
import RuntimeCurl

/// libcurl supplies HTTP forward-proxy and HTTPS CONNECT transport. The existing
/// AsyncHTTPClient proxy API tunnels even clear HTTP, which Squid correctly refuses.
/// No shell, subprocess arguments, temporary request files or credential logging.
struct CurlRuntimeHTTP {
    // Bound blocking native transfers across simultaneous workflows. Queueing
    // counts against the same deadline and cancellation never starts a late call.
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "collab.runtime.http"
        queue.maxConcurrentOperationCount = 16
        queue.qualityOfService = .utility
        return queue
    }()
    private static func token(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }
    private final class CookieSession: @unchecked Sendable {
        let handle: OpaquePointer
        init() throws {
            guard let handle = runtime_curl_session_create() else { throw RuntimeHTTPError.request("Unable to initialize HTTP cookies") }
            self.handle = handle
        }
        deinit { runtime_curl_session_free(handle) }
    }
    private final class Exchange: @unchecked Sendable {
        let handle: OpaquePointer
        let session: CookieSession
        private init(handle: OpaquePointer, session: CookieSession) { self.handle = handle; self.session = session }
        static func make(request: RuntimeHTTPRequest, proxy: String, limit: Int, remaining: Double, session: CookieSession) throws -> Exchange {
            let lengths = request.headers.filter { $0.0.lowercased() == "content-length" }
            let encodings = request.headers.filter { $0.0.lowercased() == "transfer-encoding" }
            guard lengths.count <= 1, encodings.count <= 1, lengths.isEmpty || encodings.isEmpty,
                  lengths.allSatisfy({ Int($0.1.trimmingCharacters(in: .whitespaces)) == (request.body?.count ?? 0) }),
                  encodings.allSatisfy({ $0.1.lowercased().trimmingCharacters(in: .whitespaces) == "chunked" }) else {
                throw RuntimeHTTPError.request("Invalid HTTP body framing headers")
            }
            guard let handle = runtime_curl_create(request.url, proxy, request.method, request.verifySSL ? 1 : 0,
                Int(min(request.connectTimeout, remaining) * 1000), Int(request.readTimeout * 1000),
                Int(request.writeTimeout * 1000), Int(remaining * 1000), limit, session.handle) else {
                throw RuntimeHTTPError.request("Unable to initialize HTTP transport")
            }
            let exchange = Exchange(handle: handle, session: session)
            for (name, value) in request.headers {
                guard CurlRuntimeHTTP.token(name), !value.contains("\0"),
                      !value.contains(where: { $0 == "\r" || $0 == "\n" }),
                      runtime_curl_header(handle, value.isEmpty ? "\(name);" : "\(name): \(value)") != 0 else {
                    throw RuntimeHTTPError.request("Invalid HTTP request header")
                }
            }
            // Suppress libcurl's automatic 100-continue wait; the runtime has
            // already bounded the request. Explicit user headers remain intact.
            if !request.headers.contains(where: { $0.0.lowercased() == "expect" }) {
                _ = runtime_curl_header(handle, "Expect:")
            }
            if let body = request.body ?? (encodings.isEmpty ? nil : []) {
                let ok = body.withUnsafeBytes { runtime_curl_body(handle, $0.baseAddress, $0.count) }
                guard ok != 0 else { throw RuntimeHTTPError.request("Unable to prepare HTTP body") }
            }
            return exchange
        }
        deinit { runtime_curl_free(handle) }
        func cancel() { runtime_curl_cancel(handle) }
        func perform() throws -> RuntimeHTTPResponse {
            let code = runtime_curl_perform(handle)
            if runtime_curl_cancelled(handle) != 0 { throw CancellationError() }
            let status = Int(runtime_curl_status(handle))
            let proxyStatus = Int(runtime_curl_proxy_status(handle))
            // A denied HTTPS CONNECT has no upstream response body/status.
            if proxyStatus == 401 || proxyStatus == 403 { throw RuntimeHTTPError.ssrfBlocked(Self.blocked) }
            if code != 0 && runtime_curl_truncated(handle) == 0 {
                throw RuntimeHTTPError.request(String(cString: runtime_curl_error(code)))
            }
            let headerLength = runtime_curl_headers_length(handle)
            let headerText = runtime_curl_response_headers(handle).map {
                String(decoding: UnsafeBufferPointer(start: $0, count: headerLength), as: UTF8.self)
            } ?? ""
            let headers: [(String, String)] = headerText.components(separatedBy: "\r\n").compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            if (status == 401 || status == 403) && headers.contains(where: { $0.0.lowercased() == "x-squid-error" }) {
                throw RuntimeHTTPError.ssrfBlocked(Self.blocked)
            }
            let bytes = runtime_curl_response_body(handle).map {
                Array(UnsafeBufferPointer(start: $0, count: runtime_curl_response_length(handle)))
            } ?? []
            return RuntimeHTTPResponse(status: status, headers: headers, body: bytes)
        }
        static let blocked = "The request was blocked by SSRF protection: the destination is not allowed by the configured proxy."
    }

    static func send(_ original: RuntimeHTTPRequest, proxy: String, limit: Int) async throws -> RuntimeHTTPResponse {
        guard !original.url.contains("\0"), !proxy.contains("\0"), token(original.method),
              let initial = URL(string: original.url), ["http", "https"].contains(initial.scheme?.lowercased() ?? "") else {
            throw RuntimeHTTPError.request("Only HTTP and HTTPS request URLs are supported")
        }
        if !proxy.isEmpty {
            guard let url = URL(string: proxy), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw RuntimeHTTPError.request("Invalid HTTP proxy configuration")
            }
        }
        let cookies = try CookieSession()
        var request = original
        request.url = initial.absoluteString
        let deadline = ProcessInfo.processInfo.systemUptime + original.connectTimeout + original.readTimeout + original.writeTimeout
        for hop in 0...20 {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw RuntimeHTTPError.request("HTTP request timed out") }
            let exchange = try Exchange.make(request: request, proxy: proxy, limit: limit, remaining: remaining, session: cookies)
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RuntimeHTTPResponse, any Error>) in
                    // Blocking libcurl work stays off Swift's cooperative executor/NIO loops.
                    workers.addOperation {
                        continuation.resume(with: Result { try exchange.perform() })
                    }
                }
            } onCancel: { exchange.cancel() }
            try Task.checkCancellation()
            guard request.followRedirects, [301, 302, 303, 307, 308].contains(response.status),
                  let location = response.headers.first(where: { $0.0.lowercased() == "location" })?.1 else { return response }
            guard hop < 20 else { throw RuntimeHTTPError.request("Too many HTTP redirects") }
            guard let old = URL(string: request.url), let target = URL(string: location, relativeTo: old)?.absoluteURL,
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""), target.host != nil else {
                throw RuntimeHTTPError.request("Unsupported HTTP redirect URL")
            }
            // httpx's redirect method/header policy (Dify's existing HTTP helper).
            let method = request.method.uppercased()
            if method != "HEAD" && (response.status == 302 || response.status == 303 || (response.status == 301 && method == "POST")) {
                request.method = "GET"; request.body = nil
                request.headers.removeAll { ["content-length", "transfer-encoding"].contains($0.0.lowercased()) }
            }
            let sameOrigin = origin(old) == origin(target)
            let secureUpgrade = old.host?.lowercased() == target.host?.lowercased()
                && old.scheme?.lowercased() == "http" && target.scheme?.lowercased() == "https"
                && (old.port ?? 80) == 80 && (target.port ?? 443) == 443
            request.headers.removeAll { header in
                let name = header.0.lowercased()
                return name == "cookie" || (!sameOrigin && name == "host")
                    || (!sameOrigin && !secureUpgrade && name == "authorization")
            }
            request.url = target.absoluteString
        }
        throw RuntimeHTTPError.request("Too many HTTP redirects")
    }
    private static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
}
