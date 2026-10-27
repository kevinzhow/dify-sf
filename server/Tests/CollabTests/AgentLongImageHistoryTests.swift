import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent append-only image normalization", .enabled(if: testDbHost != nil))
struct AgentLongImageHistoryTests {
    @Test func previouslyViewedImagesRemainByteStableAndAggregateFilesAreBounded() async throws {
        try await withFakeDaemon(maxBodyBytes: 32 << 20) { daemon, log in
            var config = AgentModelGatewayRouteTests.config(daemon)
            config.files.directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-history-" + UUID().uuidString).path
            config.files.signingKey = String(repeating: "fixture-signing-only-", count: 3)
            config.files.externalURL = "http://files.example.test"
            let frozen = config
            defer { try? FileManager.default.removeItem(atPath: frozen.files.directory) }
            try await withServerAndRoutes(config: frozen) { api, store, routes in
                let (initial, initialToken) = try await AgentModelGatewayRouteTests.fixture(api, store, routes)
                _ = await routes.agentModelScopes.revoke(token: initialToken)
                let bytes = [UInt8](repeating: 42, count: 7 << 20)
                let files = ServerWorkflowFiles(routes: routes, userId: initial.userID)
                let file = try await files.save(bytes: bytes, filename: "synthetic-history.png", mimeType: "image/png", sourceURL: nil)
                var scope = initial; scope.inputFileIDs = [file.recordId]
                let token = try await routes.agentModelScopes.activate(scope)
                let first: JSONValue = ["role": "user", "content": [
                    ["type": "image", "url": .string("dify-sf-file:" + file.recordId), "mime_type": "image/png"],
                    ["type": "text", "data": "fixture history"]]]
                func body(_ call: Int, _ messages: [JSONValue]) throws -> String {
                    var value = try #require(try JSONValue.parse(AgentModelGatewayRouteTests.body(scope, call: call)).object)
                    var target = try #require(value["target"]?.object)
                    target["prompt_messages"] = .array(messages); value["target"] = .object(target)
                    return JSONValue.object(value).compactJSON()
                }
                for call in 1...2 {
                    let messages = [first] + (call == 2 ? [["role": "user", "content": "next step"]] : [])
                    let answer = try await api.send(.post, AgentModelGatewayRouteTests.path, body(call, messages),
                        token: AgentModelGatewayRouteTests.serviceKey, headers: [("X-Agent-Run-Token", token)])
                    #expect(answer.status == 200, "\(answer.status)")
                }
                let requests = log.requests.filter { $0.path.hasSuffix("/dispatch/llm/invoke") }
                #expect(requests.count == 2)
                let firstNormalized = requests[0].body["data"]?["prompt_messages"]?.array?.first
                #expect(firstNormalized == requests[1].body["data"]?["prompt_messages"]?.array?.first)
                let encoded = try #require(firstNormalized?["content"]?.array?.first?["base64_data"]?.string)
                #expect(Tokens.sha256(encoded) == Tokens.sha256(Data(bytes).base64EncodedString()))
                // The same image counts at each position in the actual provider payload.
                let rejected = try await api.send(.post, AgentModelGatewayRouteTests.path, body(3, [first, first, first]),
                    token: AgentModelGatewayRouteTests.serviceKey, headers: [("X-Agent-Run-Token", token)])
                #expect(rejected.status == 413)
                #expect(log.requests.filter { $0.path.hasSuffix("/dispatch/llm/invoke") }.count == 2)
                _ = await routes.agentModelScopes.revoke(token: token)
            }
        }
    }
}
