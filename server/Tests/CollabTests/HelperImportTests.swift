import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite("Helper DSL URL boundary") struct HelperImportTests {
    @Test func rejectsUnprotectedOrNonHTTPRequestsWithoutSending() async throws {
        for (url, proxy) in [("file:///etc/passwd", "http://proxy"), ("https://user:pass@example.org/a.yaml", "http://proxy"),
                             ("https://example.org/a.yaml", ""), ("https://example.org/a.yaml#x", "http://proxy")] {
            await #expect(throws: RuntimeHTTPError.self) {
                _ = try await DSLURLImport.load(url, proxy: proxy) { _ in
                    Issue.record("Rejected import must not reach transport")
                    return .init(status: 200, headers: [], body: [])
                }
            }
        }
    }
    @Test func rejectsOversizeHTMLInvalidUTF8AndHTTPFailure() async throws {
        for response in [RuntimeHTTPResponse(status: 200, headers: [], body: [UInt8](repeating: 65, count: Routes.dslMaxBytes + 1)),
                         .init(status: 200, headers: [("Content-Type", "text/html")], body: Array("<html>login</html>".utf8)),
                         .init(status: 200, headers: [], body: [0xff]), .init(status: 404, headers: [], body: Array("no".utf8))] {
            await #expect(throws: RuntimeHTTPError.self) {
                _ = try await DSLURLImport.load("https://example.org/a.yml", proxy: "http://proxy") { _ in response }
            }
        }
    }
    @Test func preservesTheDownloadedDSLBOMAndProxyRequestPolicy() async throws {
        let value = try await DSLURLImport.load("https://example.org/a.yml", proxy: "http://proxy") { request in
            #expect(request.method == "GET" && request.followRedirects && request.verifySSL)
            #expect(request.readTimeout == 30 && request.body == nil)
            return .init(status: 200, headers: [("content-type", "application/yaml; charset=utf-8")], body: Array("\u{feff}kind: app\n".utf8))
        }
        #expect(value == "kind: app\n")
    }
}
