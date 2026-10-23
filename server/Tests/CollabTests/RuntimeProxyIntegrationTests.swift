import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

/// Actual Squid + controlled HTTP origin, not an HTTPClient mock.
/// e2e/runtime_services/origin.py supplies the fault endpoints. The isolated proxy
/// allows that fixture host alone; all other private destinations remain denied.
@Suite("Runtime real forward proxy", .enabled(if: ProcessInfo.processInfo.environment["TEST_RUNTIME_PROXY_URL"] != nil))
struct RuntimeProxyIntegrationTests {
    let proxy = ProcessInfo.processInfo.environment["TEST_RUNTIME_PROXY_URL"] ?? ""
    let origin = ProcessInfo.processInfo.environment["TEST_RUNTIME_ORIGIN_URL"] ?? "http://llmstub:8000"
    let other = ProcessInfo.processInfo.environment["TEST_RUNTIME_OTHER_URL"] ?? "http://other-fixture:8000"
    func send(_ request: RuntimeHTTPRequest, limit: Int = 1 << 20) async throws -> RuntimeHTTPResponse {
        try await CurlRuntimeHTTP.send(request, proxy: proxy, limit: limit)
    }
    func json(_ response: RuntimeHTTPResponse) throws -> JSONValue { try JSONValue.parse(response.body) }

    @Test func plainHTTPUsesForwardProxyAndPreservesBytes() async throws {
        let response = try await send(RuntimeHTTPRequest(method: "POST", url: origin + "/http/echo",
            headers: [("Content-Type", "text/plain"), ("X-Probe", "actual-proxy"), ("X-Empty", "")], body: Array("hello\0world".utf8)))
        #expect(response.status == 200)
        let body = try json(response)
        #expect(body["method"] == "POST" && body["body"] == .string("hello\0world"))
        #expect(body["headers"]?["X-Probe"] == "actual-proxy")
        #expect(body["headers"]?["X-Empty"] == "")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNTIME_TLS_URL"] != nil))
    func httpsTunnelsThroughProxyAndHonorsCertificateVerification() async throws {
        let url = ProcessInfo.processInfo.environment["TEST_RUNTIME_TLS_URL"]! + "/http/echo"
        let response = try await send(RuntimeHTTPRequest(method: "GET", url: url, verifySSL: false))
        let value = try json(response)
        #expect(response.status == 200 && value["method"] == "GET")
        do {
            _ = try await send(RuntimeHTTPRequest(method: "GET", url: url, verifySSL: true))
            Issue.record("The self-signed fixture certificate was accepted")
        } catch RuntimeHTTPError.request(let message) { #expect(message.lowercased().contains("certificate")) }
    }
    @Test func ambiguousBodyFramingIsRefusedBeforeSending() async throws {
        do {
            _ = try await send(RuntimeHTTPRequest(method: "POST", url: origin + "/http/echo",
                headers: [("Content-Length", "1")], body: Array("longer body".utf8)))
            Issue.record("Incorrect body framing was sent")
        } catch RuntimeHTTPError.request(let message) { #expect(message.contains("framing")) }
    }
    @Test func upstream403IsNotMistakenForSSRF() async throws {
        let response = try await send(RuntimeHTTPRequest(method: "GET", url: origin + "/http/echo?status=403"))
        #expect(response.status == 403)
        #expect(try json(response)["method"] == "GET")
    }
    @Test(arguments: ["http://127.0.0.1:8080/", "https://127.0.0.1/"])
    func privateDestinationIsDenied(_ url: String) async throws {
        do {
            _ = try await send(RuntimeHTTPRequest(method: "GET", url: url))
            Issue.record("Private destination unexpectedly passed the proxy")
        } catch RuntimeHTTPError.ssrfBlocked(let message) { #expect(message.contains("SSRF")) }
    }
    @Test func redirectsPreserve307AndConvert303WithoutLeakingCredentials() async throws {
        for (status, method) in [(307, "POST"), (303, "GET"), (302, "GET")] {
            let target = other + "/http/echo"
            var parts = URLComponents(string: origin + "/http/redirect")!
            parts.queryItems = [URLQueryItem(name: "status", value: "\(status)"), URLQueryItem(name: "to", value: target)]
            let response = try await send(RuntimeHTTPRequest(method: "POST", url: parts.url!.absoluteString,
                headers: [("Authorization", "Bearer fixture-only"), ("Cookie", "fixture=1")], body: Array("post-body".utf8)))
            let value = try json(response)
            #expect(value["method"] == .string(method))
            #expect(value["body"] == .string(status == 307 ? "post-body" : ""))
            #expect(value["headers"]?["Authorization"] == nil && value["headers"]?["Cookie"] == nil)
        }
    }
    @Test func redirectCookiesStayInTheirOwnOriginAndRequestChain() async throws {
        for (target, expected) in [(origin, "from-origin=1"), (other, "")] {
            var parts = URLComponents(string: origin + "/http/set-cookie")!
            parts.queryItems = [URLQueryItem(name: "to", value: target + "/http/echo")]
            let response = try await send(RuntimeHTTPRequest(method: "GET", url: parts.url!.absoluteString))
            let value = try json(response)
            #expect((value["headers"]?["Cookie"]?.string ?? "") == expected)
        }
        let separateResponse = try await send(RuntimeHTTPRequest(method: "GET", url: origin + "/http/echo"))
        let separate = try json(separateResponse)
        #expect(separate["headers"]?["Cookie"] == nil)
    }
    @Test func redirectedPrivateAddressIsStillDenied() async throws {
        var parts = URLComponents(string: origin + "/http/redirect")!
        parts.queryItems = [URLQueryItem(name: "to", value: "http://127.0.0.1:8080/")]
        do {
            _ = try await send(RuntimeHTTPRequest(method: "GET", url: parts.url!.absoluteString))
            Issue.record("Redirect bypassed the private destination policy")
        } catch RuntimeHTTPError.ssrfBlocked { }
    }
    @Test func responseLimitAndReadTimeoutAreBounded() async throws {
        let large = try await send(RuntimeHTTPRequest(method: "GET", url: origin + "/http/large?size=65536"), limit: 4097)
        #expect(large.status == 200 && large.body.count == 4097)
        let start = ContinuousClock.now
        do {
            _ = try await send(RuntimeHTTPRequest(method: "GET", url: origin + "/http/slow?seconds=8", readTimeout: 1))
            Issue.record("A stalled response did not time out")
        } catch RuntimeHTTPError.request(let message) { #expect(message.lowercased().contains("timed out")) }
        #expect(start.duration(to: .now) < .seconds(5))
    }
    @Test func cancellingTheTaskAbortsActualTransport() async throws {
        let proxy = proxy, origin = origin
        let task = Task { try await CurlRuntimeHTTP.send(RuntimeHTTPRequest(method: "GET", url: origin + "/http/slow?seconds=10"), proxy: proxy, limit: 4096) }
        try await Task.sleep(for: .milliseconds(400))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request returned a response") }
        catch is CancellationError { }
        #expect(start.duration(to: .now) < .seconds(3))
    }
}
