// Dify 1.17.1 app_dsl_service.py / remote_fetcher: bounded URL import through the existing SSRF boundary.
import CollabRuntime
import Foundation

enum DSLURLImport {
    static func load(_ url: String, proxy: String,
                     send: (@Sendable (RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse)? = nil) async throws -> String {
        guard url.utf8.count <= 8192, let parsed = URLComponents(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil,
              parsed.fragment == nil else { throw RuntimeHTTPError.request("A valid HTTP(S) URL without credentials is required") }
        // No direct-network fallback when the deployment has not configured SSRF protection.
        guard !proxy.isEmpty else { throw RuntimeHTTPError.request("Configure the SSRF proxy before URL import") }
        let request = RuntimeHTTPRequest(method: "GET", url: url, headers: [("Accept", "application/yaml, text/yaml, text/plain, application/octet-stream")],
                                         connectTimeout: 10, readTimeout: 30, writeTimeout: 10)
        let response: RuntimeHTTPResponse
        if let send { response = try await send(request) }
        else { response = try await CurlRuntimeHTTP.send(request, proxy: proxy, limit: Routes.dslMaxBytes + 1) }
        guard response.status == 200 else { throw RuntimeHTTPError.request("Download returned HTTP \(response.status)") }
        guard response.body.count <= Routes.dslMaxBytes else { throw RuntimeHTTPError.request("File size exceeds the limit of 10MB") }
        if let raw = response.headers.first(where: { $0.0.lowercased() == "content-type" })?.1 {
            let type = raw.lowercased().split(separator: ";").first.map(String.init) ?? ""
            guard ["application/yaml", "application/x-yaml", "text/yaml", "text/x-yaml", "text/plain", "application/octet-stream"].contains(type) else {
                throw RuntimeHTTPError.request("The URL must return a YAML or text file")
            }
        }
        guard let yaml = String(bytes: response.body, encoding: .utf8), !yaml.isEmpty else {
            throw RuntimeHTTPError.request("The DSL must be nonempty UTF-8 text")
        }
        return yaml.hasPrefix("\u{feff}") ? String(yaml.dropFirst()) : yaml
    }
}
