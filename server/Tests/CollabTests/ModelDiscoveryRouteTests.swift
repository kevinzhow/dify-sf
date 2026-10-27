import CollabModels
import CollabRuntime
import CollabStore
import Foundation
import PostgresNIO
import Synchronization
import Testing
@testable import CollabServer

private final class NoPaidDiscoveryChecker: CredentialChecker, Sendable {
    let calls = Mutex(0)
    let accepts = Mutex(false)
    func check(_ plan: Validation.Plan) async -> String? {
        calls.withLock { $0 += 1 }
        return accepts.withLock { $0 } ? nil : "Discovery saves must not invoke the credential checker's paid fallback"
    }
}
private func discoveryJSON(_ value: JSON) throws -> String { String(decoding: try JSONCoding.encode(value), as: UTF8.self) }

@Suite("Model discovery console routes", .enabled(if: testDbHost != nil)) struct ModelDiscoveryRouteTests {
    static let path = "/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models"
    @Test func providerReasoningDeclarationReachesSavedModelMenuAndExecution() async throws {
        try await withServerAndRoutes { api, store, routes in
            let token = try await api.setupOwner()
            let ownerID = try #require(try await store.account(email: "owner@example.com")?.id)
            let connection: [String: JSON] = ["endpoint_url": "https://gateway.invalid/v1", "api_key": "fixture-only"]
            let model = ModelDiscovery.normalize(["reasoning_levels": ["max", "vendor-next-level"]], id: "new-model")
            let receipt = await routes.modelDiscoveryReceipts.put(owner: ownerID, binding: try ModelDiscovery.Connection(connection).binding,
                value: ["models": [model]])
            let save = try await api.post(Self.path + "/autofill", discoveryJSON(["model": "new-model", "credentials": .object(connection), "discovery_id": .string(receipt)]), token: token)
            #expect(save.status == 201)
            let rules = try await api.get(Self.path + "/parameter-rules?model=new-model", token: token)
            let effort = try #require(rules.data.first { $0["name"] == "reasoning_effort" })
            #expect(effort["options"] == ["max", "vendor-next-level"])
            #expect(effort["allow_custom_value"] == false && effort["options_source"] == "provider")
            let runtime = try await routes.currentCredentials(provider: ModelDiscovery.provider, model: "new-model", modelType: "llm")
            #expect(runtime[ModelReasoning.levelsKey] == ["max", "vendor-next-level"])
            #expect(runtime[ModelDiscovery.metadataKey] == nil)
            let read = try await api.get(Self.path + "/credentials?model=new-model&model_type=llm", token: token)
            let selected = try await routes.agentCredentials(provider: ModelDiscovery.provider, model: "new-model",
                reference: ["type": "model", "id": .string(try #require(read.j["current_credential_id"]?.string))])
            #expect(selected[ModelReasoning.levelsKey] == ["max", "vendor-next-level"])
        }
    }
    @Test func outboundOperationsAndReceiptsArePrivilegedAndCannotCrossCallers() async throws {
        try await withServerAndRoutes { api, store, routes in
            let owner = try await api.setupOwner()
            let member = try await api.member("member@example.com", role: "normal", inviter: owner).token
            let admin = try await api.member("admin@example.com", role: "admin", inviter: owner).token
            let connection: [String: JSON] = ["endpoint_url": "https://gateway.invalid/v1", "api_key": "fixture-secret"]
            let input: JSON = ["credentials": .object(connection), "model": "m", "api_type": "responses", "consent": true]
            for suffix in ["discover", "probe", "autofill"] {
                #expect(try await api.post(Self.path + "/" + suffix, discoveryJSON(input)).status == 401)
                #expect(try await api.post(Self.path + "/" + suffix, discoveryJSON(input), token: member).status == 403)
            }
            #expect(try await api.post(Self.path + "/autofill", discoveryJSON(input), token: owner).status == 400)
            #expect(try await api.post(Self.path + "/probe", #"{"credentials":{},"model":"m","api_type":"responses"}"#, token: owner).status == 400)
            let ownerID = try #require(try await store.account(email: "owner@example.com")?.id)
            let binding = try ModelDiscovery.Connection(connection).binding
            let receipt = await routes.modelDiscoveryReceipts.put(owner: ownerID, binding: binding, value: ["models": []])
            let save: JSON = ["credentials": .object(connection), "model": "m", "discovery_id": .string(receipt)]
            let crossed = try await api.post(Self.path + "/autofill", discoveryJSON(save), token: admin)
            #expect(crossed.status == 409 && crossed.errorCode == "model_discovery_expired")
            var changed = connection; changed["api_key"] = "different-fixture-key"
            let stale = try await api.post(Self.path + "/autofill", discoveryJSON(["credentials": .object(changed), "model": "m", "discovery_id": .string(receipt)]), token: owner)
            #expect(stale.status == 409)
            #expect(try await store.modelProviderState().modelCredentials.isEmpty)
        }
    }

    @Test func savePersistsTrustedOriginsEncryptedAndTheOldHiddenSecretEditStillWorks() async throws {
        let checker = NoPaidDiscoveryChecker()
        let service = ModelService(catalog: try ModelService.bundledCatalog.get(), checker: checker, validate: true)
        try await withServerAndRoutes(models: service) { api, store, routes in
            let token = try await api.setupOwner(), key = "fixture-secret-0123456789"
            let ownerID = try #require(try await store.account(email: "owner@example.com")?.id)
            let connection: [String: JSON] = ["endpoint_url": "https://gateway.invalid/v1", "api_key": .string(key)]
            let model = ModelDiscovery.normalize(["id": "m", "context_length": 500000, "max_output_tokens": 128000,
                "modalities": ["input": ["text", "image"]], "native_endpoints": ["/v1/responses"], "supports_json_schema": true], id: "m")
            let receipt = await routes.modelDiscoveryReceipts.put(owner: ownerID, binding: try ModelDiscovery.Connection(connection).binding,
                value: ["models": [model]])
            var credentials = connection
            credentials["context_size"] = "8000"
            credentials["api_type"] = "responses"
            credentials[ModelDiscovery.metadataKey] = ["forged": true]
            let save = try await api.post(Self.path + "/autofill", discoveryJSON(["model": "m", "credentials": .object(credentials), "discovery_id": .string(receipt)]), token: token)
            #expect(save.status == 201, "\(save.text)")
            #expect(checker.calls.withLock { $0 } == 0)
            let read = try await api.get(Self.path + "/credentials?model=m&model_type=llm", token: token)
            #expect(read.status == 200 && !read.text.contains(key))
            #expect(read.j["credentials"]?[ModelDiscovery.metadataKey] == nil)
            #expect(read.j["autofill"]?["forged"] == nil)
            #expect(read.j["autofill"]?["model"]?["fields"]?["context_capacity"]?["value"] == 500000)
            #expect(read.j["autofill"]?["settings"]?["context_size"]?["source"] == "manual")
            #expect(read.j["credentials"]?["structured_output_support"] == "supported")
            for try await (stored,) in try await store.client.query("SELECT encrypted_config FROM provider_model_credentials", logger: store.logger).decode((String,).self) {
                #expect(stored.hasPrefix("v1:") && !stored.contains(key) && !stored.contains("gateway.invalid"))
            }
            let credentialID = try #require(read.j["current_credential_id"]?.string)
            var edited = try #require(read.j["credentials"]?.object)
            edited["api_key"] = .string(Credentials.hidden)
            edited["context_size"] = "16000"
            // The ordinary edit path still performs its original validation.
            let refused = try await api.put(Self.path + "/credentials", discoveryJSON(["model": "m", "model_type": "llm",
                "credential_id": .string(credentialID), "credentials": .object(edited)]), token: token)
            #expect(refused.status == 400 && checker.calls.withLock { $0 } == 1)
            checker.accepts.withLock { $0 = true }
            let updated = try await api.put(Self.path + "/credentials", discoveryJSON(["model": "m", "model_type": "llm",
                "credential_id": .string(credentialID), "credentials": .object(edited)]), token: token)
            #expect(updated.status == 200)
            let after = try await api.get(Self.path + "/credentials?model=m&model_type=llm", token: token)
            #expect(after.j["credentials"]?["context_size"] == "16000")
            #expect(after.j["autofill"]?["settings"]?["context_size"]?["source"] == "manual")
            let runtime = try await routes.currentCredentials(provider: ModelDiscovery.provider, model: "m", modelType: "llm")
            #expect(runtime["api_key"]?.string == key && runtime[ModelDiscovery.metadataKey] == nil)
            let selected = try await routes.agentCredentials(provider: ModelDiscovery.provider, model: "m",
                reference: ["type": "model", "id": .string(credentialID)])
            #expect(selected["api_key"]?.string == key && selected[ModelDiscovery.metadataKey] == nil)
            let listed = try await api.get(Self.path, token: token)
            #expect(listed.data.first?["model_properties"]?["context_size"] == 16000)
            #expect(listed.data.first?["model_properties"]?["autofill"]?["model"]?["fields"]?["context_capacity"]?["value"] == 500000)
            var invalid = credentials; invalid["context_size"] = "0"
            #expect(try await api.post(Self.path + "/autofill", discoveryJSON(["model": "bad", "credentials": .object(invalid), "discovery_id": .string(receipt)]), token: token).status == 400)
        }
    }
}
