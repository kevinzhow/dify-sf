import CollabModels
import CollabRuntime
import Foundation
import Synchronization
import Testing
@testable import CollabServer

@Suite("Model discovery and provenance") struct ModelDiscoveryTests {
    @Test func rejectsCredentialBearingURLsAndHeaderInjection() throws {
        for url in ["file:///etc/passwd", "https://user:pass@example.org/v1", "https://example.org/v1?key=secret", "https://example.org/v1#secret", "https://example.org/\n"] {
            #expect(throws: ServerError.self) { _ = try ModelDiscovery.Connection(["endpoint_url": .string(url)]) }
        }
        for key in ["bad\r\nAuthorization: other", Credentials.hidden] {
            #expect(throws: ServerError.self) { _ = try ModelDiscovery.Connection(["endpoint_url": "https://example.org/v1", "api_key": .string(key)]) }
        }
    }
    @Test func onlyAllowsMetadataWithKnownMeaningAndConflictsStayUnknown() throws {
        let model = ModelDiscovery.normalize(["name": "Custom", "context_length": 500000, "context_window": 272000,
            "max_output_tokens": 128000, "modalities": ["input": ["text", "image"]], "native_endpoints": ["/v1/responses"],
            "reasoning": true, "pricing": ["prompt": "5"], "api_key": "never-reflect"], id: "custom/alias")
        #expect(model["fields"]?["context_capacity"]?["source"] == "unknown")
        #expect(model["fields"]?["output_capacity"]?["value"] == 128000)
        #expect(model["fields"]?["vision"]?["value"] == true)
        #expect(model["fields"]?["api_type"]?["value"] == "responses")
        #expect(model["fields"]?["tools"]?["source"] == "unknown")
        #expect(!String(decoding: try JSONCoding.encode(model), as: UTF8.self).contains("never-reflect"))
        #expect(model["fields"]?["pricing"] == nil)
        let defaults = ModelDiscovery.defaults(model)
        #expect(defaults["context_size"] == "4096")
        #expect(model["fields"]?["context_capacity"]?["value"] == .null)
    }
    @Test func discoveryIsOneGETWithoutRedirectOrPaidFallback() async throws {
        let connection = try ModelDiscovery.Connection(["endpoint_url": "https://gateway.example/v1/", "api_key": "fixture-key"])
        let result = try await ModelDiscovery.discover(connection) { request in
            #expect(request.url == "https://gateway.example/v1/models")
            #expect(request.method == "GET" && request.body == nil && !request.followRedirects && request.verifySSL)
            #expect(request.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer fixture-key" })
            return .init(status: 200, headers: [], body: Array(#"{"data":[{"id":"m","context_length":10000},{"id":"m"},{"id":""}],"has_more":true,"next":"https://evil.example/steal"}"#.utf8))
        }
        #expect(result["models"]?.array?.count == 1 && result["incomplete"] == true)
        #expect(result["next"] == nil)
        for response in [RuntimeHTTPResponse(status: 302, headers: [("Location", "https://evil.example")], body: []),
                         .init(status: 401, headers: [], body: Array("fixture-key".utf8)),
                         .init(status: 200, headers: [], body: Array("<html>login</html>".utf8)),
                         .init(status: 200, headers: [], body: [UInt8](repeating: 32, count: ModelDiscovery.maxBytes + 1))] {
            await #expect(throws: ServerError.self) { _ = try await ModelDiscovery.discover(connection) { _ in response } }
        }
    }
    @Test func receiptCannotCrossOwnerConnectionOrExpiryAndProbeIsRateLimited() async throws {
        let receipts = ModelDiscoveryReceipts(), now = Date()
        let id = await receipts.put(owner: "a", binding: "connection-a", value: ["models": []], now: now)
        #expect(try await receipts.get(id, owner: "a", binding: "connection-a", now: now) != nil)
        for (owner, binding, at) in [("b", "connection-a", now), ("a", "connection-b", now), ("a", "connection-a", now.addingTimeInterval(1801))] {
            await #expect(throws: ServerError.self) { _ = try await receipts.get(id, owner: owner, binding: binding, now: at) }
        }
        try await receipts.begin("a", probe: true, now: now)
        await #expect(throws: ServerError.self) { try await receipts.begin("a", now: now) }
        await receipts.end("a")
        await #expect(throws: ServerError.self) { try await receipts.begin("a", probe: true, now: now.addingTimeInterval(10)) }
        try await receipts.begin("a", probe: true, now: now.addingTimeInterval(61))
    }
    @Test func acceptedRequestsDoNotProveCapabilitiesAndIgnoredLimitIsRecorded() async throws {
        let count = Mutex(0)
        let connection = try ModelDiscovery.Connection(["endpoint_url": "https://gateway.example/v1"])
        let value = try await ModelCapabilityProbe.run(connection, model: "unlisted", protocolName: "responses") { request in
            count.withLock { $0 += 1 }
            #expect(request.method == "POST" && !request.followRedirects)
            return .init(status: 200, headers: [], body: Array(#"{"output":[{"content":[{"text":"ignored"}]}],"usage":{"output_tokens":24}}"#.utf8))
        }
        #expect(count.withLock { $0 } <= 7)
        #expect(value["fields"]?["tools"]?["source"] == "unknown")
        #expect(value["fields"]?["vision"]?["source"] == "unknown")
        #expect(value["fields"]?["json_schema"]?["source"] == "unknown")
        #expect(value["fields"]?["streaming"]?["source"] == "unknown")
        #expect(value["fields"]?["output_limit"]?["value"] == false)
        #expect(value["observations"]?["output_limit"] == "not_enforced_in_probe")
        #expect(value["fields"]?["context_capacity"] == nil)
    }
    @Test func editsPreserveSecretsOutsideMetadataAndInvalidateChangedConnection() throws {
        let model = ModelDiscovery.normalize(["context_length": 500000], id: "m")
        let defaults = ModelDiscovery.defaults(model)
        var credentials = defaults
        credentials["endpoint_url"] = "https://gateway.example/v1"
        credentials["api_key"] = "fixture-secret"
        credentials["context_size"] = "8000"
        let meta = ModelAutofillMetadata.make(model: model, defaults: defaults, actual: credentials, listed: true, probe: nil)
        #expect(meta["settings"]?["context_size"]?["source"] == "manual")
        #expect(meta["model"]?["fields"]?["context_capacity"]?["value"] == 500000)
        #expect(!String(decoding: try JSONCoding.encode(meta), as: UTF8.self).contains("fixture-secret"))
        var edited = credentials
        edited["api_key"] = "other-fixture-secret"
        let changed = ModelAutofillMetadata.edited(meta, old: credentials, new: edited)
        #expect(changed["model"]?["fields"]?["context_capacity"]?["source"] == "unknown")
        #expect(changed["settings"]?["context_size"]?["source"] == "manual")
    }
}
