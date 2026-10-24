import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Published application identities", .enabled(if: testDbHost != nil))
struct PublicIdentityTests {
    @Test func identityNamespacesAndRevocationUseDurableState() async throws {
        try await withServerAndRoutes { api, store, _ in
            let owner = try await api.setupOwner()
            let ownerId = try await api.get("/v1/account", token: owner).str("id")
            let imported = try await api.post("/v1/apps/imports", JSONValue.object([
                "mode": "yaml-content", "yaml_content": .string(ToolRouteTests.childYAML)
            ]).compactJSON(), token: owner)
            let app = try #require(imported.j["app_id"]?.string)
            let site = try #require(try await store.siteJSON(app))
            let code = try #require(try JSONValue.parse(site)["code"]?.string)
            let found = try #require(try await store.publicSiteApp(code: code))
            #expect(found.appId == app && found.owner == ownerId)
            let first = try await store.endUser(appId: app, source: "api", namespace: "key-a", externalId: "same-user")
            let same = try await store.endUser(appId: app, source: "api", namespace: "key-a", externalId: "same-user")
            let otherKey = try await store.endUser(appId: app, source: "api", namespace: "key-b", externalId: "same-user")
            let otherUser = try await store.endUser(appId: app, source: "api", namespace: "key-a", externalId: "another-user")
            #expect(first.id == same.id && first.id != otherKey.id && first.id != otherUser.id)
            let browser = try await store.endUser(appId: app, source: "web-app", namespace: code, externalId: UUID().uuidString)
            let at = Date()
            try await store.createPublicSession(tokenHash: "fixture-public-hash", endUser: browser.id, siteCode: code, expiresAt: at.addingTimeInterval(60))
            #expect(try await store.publicSession(tokenHash: "fixture-public-hash", at: at)?.endUser.id == browser.id)
            #expect(try await store.publicSession(tokenHash: "fixture-public-hash", at: at.addingTimeInterval(120)) == nil)
            #expect(try await store.publicSession(tokenHash: owner, at: at) == nil)
            #expect(try await api.post("/v1/apps/\(app)/site-enable", #"{"enable_site":false}"#, token: owner).status == 200)
            #expect(try await store.publicSession(tokenHash: "fixture-public-hash", at: at) == nil)
            #expect(try await store.publicSiteApp(code: code) == nil)
            #expect(try await api.post("/v1/apps/\(app)/site-enable", #"{"enable_site":true}"#, token: owner).status == 200)
            #expect(try await store.publicSession(tokenHash: "fixture-public-hash", at: at) != nil)
            #expect(try await api.post("/v1/apps/\(app)/site/access-token-reset", "{}", token: owner).status == 200)
            #expect(try await store.publicSession(tokenHash: "fixture-public-hash", at: at) == nil)
            #expect(try await store.publicSiteApp(code: code) == nil)
            #expect(try await store.endUser(id: browser.id) != nil) // revocation keeps historical identity
        }
    }
}
