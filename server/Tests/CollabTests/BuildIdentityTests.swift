import Foundation
import Testing
@testable import CollabServer

@Suite("Public build identity")
struct BuildIdentityTests {
    @Test func onlyCommitIdentifiersCanBecomePublicReleaseMetadata() throws {
        #expect(BuildIdentity(revision: String(repeating: "A", count: 40)).revision == String(repeating: "a", count: 40))
        for value in ["", "short", "secret://local/value", String(repeating: "b", count: 41)] {
            #expect(BuildIdentity(revision: value).revision == "development")
        }
        let encoded = String(decoding: try JSONEncoder().encode(BuildIdentity(revision: "not-a-public-revision")), as: UTF8.self)
        #expect(!encoded.contains("not-a-public-revision"))
        #expect(encoded.contains("workflow_protocol") && encoded.contains("client_manifest"))
    }
    @Test(.enabled(if: testDbHost != nil)) func actualFeaturesExposeBuildAndActualRolloutSwitchesTogether() async throws {
        var config = ServerConfig.defaults
        config.buildRevision = String(repeating: "9", count: 40)
        try await withServer(config: config) { api, _, _ in
            let response = try await api.get("/v1/system-features")
            #expect(response.status == 200)
            #expect(response.obj("build")["revision"] == .string(String(repeating: "9", count: 40)))
            #expect(response.json["inline_agent"] == .bool(false))
            #expect(response.json["inline_agent_shell"] == .bool(false))
        }
    }
}
