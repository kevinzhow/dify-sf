import CollabModels
import CollabStore
import Foundation
import HTTPTypes
import PostgresNIO
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

extension API.Answer {
    /// The body as model-provider JSON.
    var j: JSON { (try? JSONCoding.decode(Data(text.utf8))) ?? .null }
    var data: [JSON] { j["data"]?.array ?? [] }
}

/// What the stub provider received.
final class StubLog: Sendable {
    private let state = Mutex<[(path: String, key: String?)]>([])
    func add(_ path: String, _ key: String?) { state.withLock { $0.append((path, key)) } }
    var requests: [(path: String, key: String?)] { state.withLock { $0 } }
    var keys: [String] { requests.compactMap(\.key) }
    func reset() { state.withLock { $0 = [] } }
}

/// A local stand-in for the model providers (never the real ones): accepts keys starting with `sk-good`, refuses others
/// with an OpenAI-style error that quotes the key (so the tests can check it is redacted).
///   GET  /v1/models                 OpenAI style (Bearer) and Anthropic (x-api-key)
///   GET  /oaic/models               404 (an OpenAI-compatible server without a model list)
///   POST /oaic/chat/completions     the 1-token fallback
///   POST /api/show                  Ollama: knows `llama3`
func withStubProvider(_ body: @Sendable @escaping (String, StubLog) async throws -> Void) async throws {
    let log = StubLog()
    @Sendable func key(_ req: Request) -> String? {
        if let k = req.headers[HTTPField.Name("x-api-key")!] { return k }
        if let a = req.headers[.authorization], a.hasPrefix("Bearer ") { return String(a.dropFirst(7)) }
        return nil
    }
    @Sendable func answer(_ status: Int, _ body: String) -> Response {
        var h = HTTPFields()
        h[.contentType] = "application/json"
        return Response(status: HTTPResponse.Status(code: status), headers: h, body: .init(string: body))
    }
    @Sendable func checked(_ req: Request, _ path: String) async -> Response {
        let k = key(req)
        log.add(path, k)
        guard let k, k.hasPrefix("sk-good") else {
            return answer(401, #"{"error":{"message":"Incorrect API key provided: \#(k ?? "none").","type":"invalid_request_error"}}"#)
        }
        return answer(200, #"{"object":"list","data":[]}"#)
    }
    try await withApp(configure: { app in
        app.get("v1", "models") { req async -> Response in await checked(req, "/v1/models") }
        app.get("oaic", "models") { req async -> Response in
            log.add("/oaic/models", key(req))
            return answer(404, #"{"detail":"Not Found"}"#)
        }
        app.post("oaic", "chat", "completions") { req async -> Response in await checked(req, "/oaic/chat/completions") }
        app.post("api", "show") { req async -> Response in
            log.add("/api/show", key(req))
            let data = (try? await req.body.collect(max: .specified(ByteCount(value: 1 << 16)))) ?? Data()
            let model = (try? JSONCoding.decode(data))?["model"]?.string ?? ""
            return model == "llama3" ? answer(200, #"{"modelfile":""}"#) : answer(404, #"{"error":"model '\#(model)' not found"}"#)
        }
    }) { app in
        try await app.testing(.running) { client in
            guard let port = client.port else { Issue.record("the stub has no port"); return }
            try await body("http://127.0.0.1:\(port)", log)
        }
    }
}

private let openai = "/v1/workspace/model-providers/langgenius/openai/openai"
private let anthropic = "/v1/workspace/model-providers/langgenius/anthropic/anthropic"
private let oaic = "/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible"
private let ollama = "/v1/workspace/model-providers/langgenius/ollama/ollama"

private func json(_ v: JSON) -> String { String(decoding: try! JSONCoding.encode(v), as: UTF8.self) }

/// The first model of `type` the way Dify orders a provider's models (position, then file order).
private func firstModel(_ provider: String, _ type: String = "llm") throws -> String {
    let def = try #require(try ModelService.bundledCatalog.get().provider(provider))
    let positions = def.positions[type] ?? []
    let models = def.models.filter { $0.modelType == type && !$0.deprecated }
    return models.enumerated().min { a, b in
        let pa = positions.firstIndex(of: a.element.model) ?? positions.count, pb = positions.firstIndex(of: b.element.model) ?? positions.count
        return pa != pb ? pa < pb : a.offset < b.offset
    }!.element.model
}

private func noValidation() -> ServerConfig {
    var c = ServerConfig.defaults
    c.modelsValidate = false
    return c
}

/// Model providers against Postgres and the real routes (protocol 1.9), each test on a fresh database; credential checks
/// go to a local stub provider.
@Suite("Model provider routes", .enabled(if: testDbHost != nil))
struct ModelRouteTests {
    @Test func readsNeedASignInAndWritesTheOwnerOrAnAdmin() async throws {
        try await withServer(config: noValidation()) { api, _, _ in
            let owner = try await api.setupOwner()
            let admin = try await api.member("admin@example.com", role: "admin", inviter: owner).token
            let editor = try await api.member("editor@example.com", role: "editor", inviter: owner).token
            let normal = try await api.member("normal@example.com", role: "normal", inviter: owner).token
            #expect(try await api.get("/v1/workspace/model-providers/summary").status == 401)
            #expect(try await api.get("/v1/workspace/models/model-types/llm").status == 401)
            let body = json(["credentials": ["openai_api_key": "sk-good-0123456789"]])
            for token in [editor, normal] {
                #expect(try await api.get("/v1/workspace/model-providers/summary", token: token).status == 200)
                #expect(try await api.get("/v1/workspace/model-providers", token: token).status == 200)
                #expect(try await api.get("/v1/workspace/models/model-types/llm", token: token).status == 200)
                #expect(try await api.get("/v1/workspace/default-model?model_type=llm", token: token).status == 200)
                #expect(try await api.get("\(openai)/models", token: token).status == 200)
                #expect(try await api.get("\(openai)/models/parameter-rules?model=gpt-4o", token: token).status == 200)
                let forbidden: [API.Answer] = [
                    try await api.post("\(openai)/credentials", body, token: token),
                    try await api.get("\(openai)/credentials", token: token),
                    try await api.post("\(openai)/credentials/validate", body, token: token),
                    try await api.patch("\(openai)/models/disable", #"{"model":"gpt-4o","model_type":"llm"}"#, token: token),
                    try await api.post("/v1/workspace/default-model", #"{"model_settings":[]}"#, token: token),
                    try await api.get("\(oaic)/models/credentials?model=m&model_type=llm", token: token),
                    try await api.delete("\(oaic)/models", #"{"model":"m","model_type":"llm"}"#, token: token),
                ]
                #expect(forbidden.allSatisfy { $0.status == 403 && $0.errorCode == "forbidden" }, "\(forbidden.map(\.status))")
            }
            #expect(try await api.post("\(openai)/credentials", body, token: admin).status == 201)
            #expect(try await api.get("\(openai)/credentials", token: admin).status == 200)
            // Icons are public (Dify's icon route has no login either); SVG.
            let icon = try await api.send(.get, "\(openai)/icon_small/en_US")
            #expect(icon.status == 200 && icon.text.contains("<svg"))
            #expect(try await api.get("\(openai)/icon_small_dark/zh_Hans").status == 200)
            #expect(try await api.get("\(anthropic)/icon_small_dark/en_US").status == 404)  // anthropic has no dark icon
            #expect(try await api.get("/v1/workspace/model-providers/nobody/x/y/models", token: owner).status == 404)
        }
    }

    @Test func theCatalogWithoutCredentials() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let summary = try await api.get("/v1/workspace/model-providers/summary", token: owner)
            #expect(summary.status == 200 && summary.data.count == 10 && summary.j["plugins"] == [:])
            let first = try #require(summary.data.first)
            #expect(first["provider"] == "langgenius/openai/openai" && first["plugin_id"] == "langgenius/openai")
            #expect(first["is_configured"] == false && first["preferred_provider_type"] == "custom")
            #expect(first["custom_configuration"]?["status"] == "no-configure" && first["system_configuration"] == ["enabled": false])
            #expect(first["icon_small"] == ["en_US": "\(openai)/icon_small/en_US", "zh_Hans": "\(openai)/icon_small/zh_Hans"])
            let providers = try await api.get("/v1/workspace/model-providers", token: owner)
            #expect(providers.data.count == 10)
            #expect(providers.data[0]["provider_credential_schema"]?["credential_form_schemas"]?.array?.isEmpty == false)
            #expect(try await api.get("/v1/workspace/model-providers?model_type=rerank", token: owner).data.map { $0["provider"]?.string ?? "" }
                == ["langgenius/tongyi/tongyi", "langgenius/ollama/ollama", "langgenius/openai_api_compatible/openai_api_compatible"])
            #expect(try await api.get("/v1/workspace/model-providers?model_type=poems", token: owner).status == 400)
            #expect(try await api.get("/v1/workspace/models/model-types/llm", token: owner).data.isEmpty)
            #expect(try await api.get("/v1/workspace/models/model-types/poems", token: owner).status == 400)
            #expect(try await api.get("/v1/workspace/default-model?model_type=llm", token: owner).j == ["data": .null])
            #expect(try await store.modelProviderState().defaults.isEmpty)
            let models = try await api.get("\(openai)/models", token: owner).data
            #expect(!models.isEmpty && models.allSatisfy { $0["status"] == "no-configure" && $0["provider"]?["provider"] == "langgenius/openai/openai" })
            // Sorted by model type, then position.
            let types = models.compactMap { $0["model_type"]?.string }
            #expect(types == types.sorted())
            #expect(try await api.get("\(openai)/models/parameter-rules?model=gpt-4o", token: owner).j == ["data": []])
        }
    }

    @Test func credentialsAreEncryptedAtRestMaskedAndHiddenRoundTrips() async throws {
        try await withStubProvider { base, log in
            try await withServer { api, store, _ in
                let owner = try await api.setupOwner()
                let key = "sk-good-0123456789abcdef"
                let created = try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": .string(key), "openai_api_base": .string(base)]]),
                                                 token: owner)
                #expect(created.status == 201 && created.j == ["result": "success"], "\(created.text)")
                #expect(log.keys == [key])
                // At rest: sealed, no trace of the key.
                var rows: [String] = []
                for try await (c,) in try await store.client.query("SELECT encrypted_config FROM provider_credentials", logger: store.logger).decode((String,).self) {
                    rows.append(c)
                }
                #expect(rows.count == 1 && rows[0].hasPrefix("v1:") && !rows[0].contains("sk-good") && !rows[0].contains(base))
                // On read: masked; the summary shows it configured.
                let read = try await api.get("\(openai)/credentials", token: owner)
                #expect(read.j["credentials"]?["openai_api_key"] == "sk-goo************ef" && read.j["credentials"]?["openai_api_base"] == .string(base))
                #expect(read.j["credentials"]?["api_protocol"] == "responses")  // the form default was filled in
                let summary = try await api.get("/v1/workspace/model-providers/summary", token: owner).data[0]
                let id = try #require(summary["custom_configuration"]?["current_credential_id"]?.string)
                #expect(summary["is_configured"] == true && summary["custom_configuration"]?["current_credential_name"] == "API KEY 1")
                #expect(summary["custom_configuration"]?["current_credential_usable"] == true)
                #expect(try await api.get("\(openai)/credentials?credential_id=\(id)", token: owner).j["credentials"]?["openai_api_key"] == "sk-goo************ef")
                // [__HIDDEN__] keeps the stored secret (the provider is asked with it again) while other fields change.
                log.reset()
                let updated = try await api.put("\(openai)/credentials", json([
                    "credential_id": .string(id), "name": "Main key",
                    "credentials": ["openai_api_key": "[__HIDDEN__]", "openai_api_base": .string(base), "openai_organization": "org-7"],
                ]), token: owner)
                #expect(updated.status == 200, "\(updated.text)")
                #expect(log.keys == [key])
                let stored = try await store.providerCredential(provider: "langgenius/openai/openai", id: id)
                let config = try JSONCoding.decode(Data(stored.config!.utf8))
                #expect(stored.name == "Main key" && config["openai_api_key"] == .string(key) && config["openai_organization"] == "org-7")
                // Every model of the provider is active now.
                let llm = try await api.get("/v1/workspace/models/model-types/llm", token: owner).data
                #expect(llm.map { $0["provider"] } == ["langgenius/openai/openai"])
                #expect(llm[0]["models"]?.array?.allSatisfy { $0["status"] == "active" && $0["deprecated"] == false } == true)
            }
        }
    }

    @Test func aCredentialThatCannotBeDecryptedIsNotUsable() async throws {
        try await withStubProvider { base, _ in
            try await withServer { api, store, registry in
                let owner = try await api.setupOwner()
                #expect(try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-good-1", "openai_api_base": .string(base)]]),
                                           token: owner).status == 201)
                // The same database through a server with another key (a lost or changed COLLAB_SECRETS_KEY).
                let other = PostgresStore(client: store.client, logger: store.logger, cipher: SecretsKey.random())
                try await withApp(configure: { app in
                    try Routes(registry: registry, store: other, config: .defaults, logger: store.logger).register(on: app)
                }) { app in
                    try await app.testing { client in
                        let api2 = API(client: client)
                        let summary = try await api2.get("/v1/workspace/model-providers/summary", token: owner).data[0]
                        #expect(summary["custom_configuration"]?["current_credential_usable"] == false)
                        let models = try await api2.get("\(openai)/models", token: owner).data
                        #expect(models.allSatisfy { $0["status"] == "credential-removed" })
                        #expect(try await api2.get("/v1/workspace/models/model-types/llm", token: owner).data.isEmpty)
                        #expect(try await api2.get("\(openai)/credentials", token: owner).j == ["credentials": [:]])
                        // Updating with [__HIDDEN__] cannot restore the secret: the admin has to enter it again.
                        let id = summary["custom_configuration"]?["current_credential_id"]?.string ?? ""
                        let put = try await api2.put("\(openai)/credentials", json(["credential_id": .string(id),
                                                                                     "credentials": ["openai_api_key": "[__HIDDEN__]"]]), token: owner)
                        #expect(put.status == 400)
                    }
                }
            }
        }
    }

    @Test func savingChecksTheCredentialsWithTheProvider() async throws {
        try await withStubProvider { base, log in
            try await withServer { api, store, _ in
                let owner = try await api.setupOwner()
                let bad = try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-bad-0123456789", "openai_api_base": .string(base)]]),
                                             token: owner)
                #expect(bad.status == 400 && bad.errorCode == "credential_validation_failed")
                #expect(bad.text.contains("Incorrect API key provided") && !bad.text.contains("sk-bad-0123456789"), "\(bad.text)")
                #expect(try await store.modelProviderState().providerCredentials.isEmpty)
                // Form errors are 400 before anything is sent.
                log.reset()
                let missing = try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_base": .string(base)]]), token: owner)
                #expect(missing.status == 400 && missing.errorCode == "bad_request" && missing.text.contains("openai_api_key is required"))
                #expect(log.requests.isEmpty)
                // validate answers Dify's {result} shape.
                let failed = try await api.post("\(openai)/credentials/validate", json(["credentials": ["openai_api_key": "sk-bad-xyz12345", "openai_api_base": .string(base)]]),
                                                token: owner)
                #expect(failed.status == 200 && failed.j["result"] == "error" && failed.j["error"]?.string?.contains("Incorrect API key") == true)
                let passed = try await api.post("\(openai)/credentials/validate", json(["credentials": ["openai_api_key": "sk-good-xyz", "openai_api_base": .string(base)]]),
                                                token: owner)
                #expect(passed.j == ["result": "success"])
                #expect(try await store.modelProviderState().providerCredentials.isEmpty)  // validate stores nothing
                // Anthropic's dialect: x-api-key.
                log.reset()
                #expect(try await api.post("\(anthropic)/credentials", json(["credentials": ["anthropic_api_key": "sk-good-ant", "anthropic_api_url": .string(base)]]),
                                           token: owner).status == 201)
                #expect(log.requests.map(\.path) == ["/v1/models"] && log.keys == ["sk-good-ant"])
                // An unreachable provider is a validation failure too.
                let down = try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-good-1", "openai_api_base": "http://127.0.0.1:9"]]),
                                              token: owner)
                #expect(down.status == 400 && down.errorCode == "credential_validation_failed" && down.text.contains("127.0.0.1"), "\(down.text)")
                let notHTTP = try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-good-1", "openai_api_base": "file:///etc"]]),
                                                 token: owner)
                #expect(notHTTP.status == 400 && notHTTP.text.contains("Invalid base URL"))
            }
            // Validation switched off (COLLAB_MODELS_VALIDATE=false): saved without asking the provider.
            log.reset()
            try await withServer(config: noValidation()) { api, _, _ in
                let owner = try await api.setupOwner()
                #expect(try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-bad-1", "openai_api_base": .string(base)]]),
                                           token: owner).status == 201)
                #expect(try await api.post("\(openai)/credentials/validate", json(["credentials": ["openai_api_key": "sk-bad-1"]]), token: owner).j == ["result": "success"])
            }
            #expect(log.requests.isEmpty)
        }
    }

    @Test func withoutASecretsKeyNothingSecretIsStored() async throws {
        try await withServer(config: noValidation(), secretsKey: false) { api, store, _ in
            let owner = try await api.setupOwner()
            let refused = try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-good-1"]]), token: owner)
            #expect(refused.status == 503 && refused.errorCode == "secrets_key_missing")
            #expect(try await api.post("\(oaic)/models/credentials", json(["model": "m", "model_type": "llm",
                                                                           "credentials": ["endpoint_url": "http://x", "mode": "chat"]]),
                                       token: owner).errorCode == "secrets_key_missing")
            #expect(try await store.modelProviderState().providerCredentials.isEmpty)
            // The catalog still works, every provider unconfigured.
            #expect(try await api.get("/v1/workspace/model-providers/summary", token: owner).data.count == 10)
            // Secret environment variables (1.7) are refused as well.
            #expect(try await api.put("/v1/docs/d1", #"{"template":"empty"}"#, token: owner).status == 201)
            let secret = try await api.post("/v1/docs/d1/secrets", #"{"value":"s3cret-value"}"#, token: owner)
            #expect(secret.status == 503 && secret.errorCode == "secrets_key_missing")
            let dsl = """
                app: {mode: workflow, name: s}
                kind: app
                version: 0.3.1
                workflow:
                  environment_variables:
                  - {id: v1, name: k, value: s3cret, value_type: secret}
                  graph: {nodes: [{id: s, data: {type: start, title: Start, variables: []}}], edges: []}
                """
            #expect(try await api.post("/v1/docs/import", dsl, token: owner).errorCode == "secrets_key_missing")
            var plaintext = 0
            for try await (n,) in try await store.client.query("SELECT count(*)::bigint FROM secrets", logger: store.logger).decode((Int,).self) { plaintext = n }
            #expect(plaintext == 0)
        }
    }

    @Test func multipleCredentialsAndSwitching() async throws {
        try await withServer(config: noValidation()) { api, _, _ in
            let owner = try await api.setupOwner()
            for k in ["sk-1-aaaaaaaaaa", "sk-2-bbbbbbbbbb"] {
                #expect(try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": .string(k)]]), token: owner).status == 201)
            }
            func config() async throws -> JSON { try await api.get("/v1/workspace/model-providers", token: owner).data[0]["custom_configuration"]! }
            var c = try await config()
            let available = c["available_credentials"]?.array ?? []
            #expect(available.map { $0["credential_name"] } == ["API KEY 2", "API KEY 1"])  // newest first
            let first = available[1]["credential_id"]!.string!, second = available[0]["credential_id"]!.string!
            #expect(c["current_credential_id"] == .string(first) && c["status"] == "active")  // the first one became current
            let dup = try await api.post("\(openai)/credentials", json(["name": "API KEY 1", "credentials": ["openai_api_key": "sk-3"]]), token: owner)
            #expect(dup.status == 409 && dup.errorCode == "credential_name_exists")
            #expect(try await api.post("\(openai)/credentials", json(["name": .string(String(repeating: "n", count: 31)),
                                                                      "credentials": ["openai_api_key": "sk-3"]]), token: owner).status == 400)
            #expect(try await api.post("\(openai)/credentials/switch", json(["credential_id": .string(second)]), token: owner).j == ["result": "success"])
            c = try await config()
            #expect(c["current_credential_id"] == .string(second) && c["current_credential_name"] == "API KEY 2")
            #expect(try await api.post("\(openai)/credentials/switch", #"{"credential_id":"nope"}"#, token: owner).status == 404)
            // Deleting the current one leaves none current: models unconfigured, the provider still has credentials.
            #expect(try await api.delete("\(openai)/credentials", json(["credential_id": .string(second)]), token: owner).status == 204)
            c = try await config()
            #expect(c["current_credential_id"] == .null && c["status"] == "active" && c["available_credentials"]?.array?.count == 1)
            let summary = try await api.get("/v1/workspace/model-providers/summary", token: owner).data[0]
            #expect(summary["custom_configuration"]?["current_credential_usable"] == false && summary["is_configured"] == true)
            #expect(try await api.get("\(openai)/models", token: owner).data.allSatisfy { $0["status"] == "no-configure" })
            #expect(try await api.get("\(openai)/credentials", token: owner).j == ["credentials": [:]])
            #expect(try await api.post("\(openai)/credentials/switch", json(["credential_id": .string(first)]), token: owner).status == 200)
            #expect(try await api.get("\(openai)/models", token: owner).data.allSatisfy { $0["status"] == "active" })
            // The last one takes the provider's configuration with it.
            #expect(try await api.delete("\(openai)/credentials", json(["credential_id": .string(first)]), token: owner).status == 204)
            c = try await config()
            #expect(c["status"] == "no-configure" && c["available_credentials"] == [] && c["current_credential_id"] == .null)
            #expect(try await api.delete("\(openai)/credentials", json(["credential_id": .string(first)]), token: owner).status == 404)
        }
    }

    @Test func theDefaultModelIsTheFirstActiveOneAndStaysUntilChanged() async throws {
        try await withServer(config: noValidation()) { api, store, _ in
            let owner = try await api.setupOwner()
            #expect(try await api.get("/v1/workspace/default-model?model_type=llm", token: owner).j == ["data": .null])
            #expect(try await api.get("/v1/workspace/default-model", token: owner).status == 400)
            #expect(try await api.post("\(anthropic)/credentials", json(["credentials": ["anthropic_api_key": "sk-ant-1"]]), token: owner).status == 201)
            let picked = try await api.get("/v1/workspace/default-model?model_type=llm", token: owner).j["data"]!
            let expected = try firstModel("anthropic")
            #expect(picked["model"] == .string(expected) && picked["model_type"] == "llm")
            #expect(picked["provider"]?["provider"] == "langgenius/anthropic/anthropic" && picked["provider"]?["icon_small_dark"] == .null)
            #expect(picked["provider"]?["models"] == [] && picked["provider"]?["provider_name"] == "")
            #expect(try await store.modelProviderState().defaults["llm"]?.model == expected)  // stored, as Dify does
            // A provider configured later does not take over.
            #expect(try await api.post("\(openai)/credentials", json(["credentials": ["openai_api_key": "sk-openai-1"]]), token: owner).status == 201)
            #expect(try await api.get("/v1/workspace/default-model?model_type=llm", token: owner).j["data"]?["model"] == .string(expected))
            // The system model selector's Save.
            let gpt = try firstModel("openai")
            let saved = try await api.post("/v1/workspace/default-model", json(["model_settings": [
                ["model_type": "llm", "provider": "langgenius/openai/openai", "model": .string(gpt)],
                ["model_type": "rerank", "provider": .null, "model": .null],
            ]]), token: owner)
            #expect(saved.j == ["result": "success"])
            #expect(try await api.get("/v1/workspace/default-model?model_type=llm", token: owner).j["data"]?["provider"]?["provider"] == "langgenius/openai/openai")
            let unknown = try await api.post("/v1/workspace/default-model", json(["model_settings": [["model_type": "llm", "provider": "langgenius/openai/openai", "model": "gpt-none"]]]),
                                             token: owner)
            #expect(unknown.status == 400 && unknown.text.contains("Model gpt-none does not exist."))
            #expect(try await api.post("/v1/workspace/default-model", json(["model_settings": [["model_type": "llm", "provider": "x/y/z", "model": "m"]]]),
                                       token: owner).status == 400)
            // No active text-embedding model of anthropic; openai has one.
            #expect(try await api.get("/v1/workspace/default-model?model_type=text-embedding", token: owner).j["data"]?["provider"]?["provider"]
                == "langgenius/openai/openai")
        }
    }

    @Test func parameterRulesAndEnablingModels() async throws {
        try await withServer(config: noValidation()) { api, _, _ in
            let owner = try await api.setupOwner()
            let def = try #require(try ModelService.bundledCatalog.get().provider("anthropic"))
            let model = try #require(def.models.first { $0.modelType == "llm" && $0.rawParameterRules.contains { $0["name"] == "temperature" && $0["label"] == nil } }).model
            #expect(try await api.get("\(anthropic)/models/parameter-rules?model=\(model)", token: owner).j == ["data": []])  // not configured
            #expect(try await api.post("\(anthropic)/credentials", json(["credentials": ["anthropic_api_key": "sk-ant-1"]]), token: owner).status == 201)
            let rules = try await api.get("\(anthropic)/models/parameter-rules?model=\(model)", token: owner).data
            let temperature = try #require(rules.first { $0["name"] == "temperature" })
            #expect(temperature["label"] == ["en_US": "Temperature", "zh_Hans": "温度"] && temperature["use_template"] == "temperature")
            #expect(temperature["type"] == "float" && temperature["precision"] == 2 && temperature["options"] == [])
            #expect(try await api.get("\(anthropic)/models/parameter-rules?model=no-such-model", token: owner).j == ["data": []])
            #expect(try await api.get("\(anthropic)/models/parameter-rules", token: owner).status == 400)
            // Disabling: the model leaves the selector lists and its rules are refused (Dify's "Model x is disabled.").
            #expect(try await api.patch("\(anthropic)/models/disable", json(["model": .string(model), "model_type": "llm"]), token: owner).j == ["result": "success"])
            let status = try await api.get("\(anthropic)/models", token: owner).data.first { $0["model"] == .string(model) }?["status"]
            #expect(status == "disabled")
            let listed = try await api.get("/v1/workspace/models/model-types/llm", token: owner).data.first?["models"]?.array ?? []
            #expect(!listed.contains { $0["model"] == .string(model) } && !listed.isEmpty)
            let refused = try await api.get("\(anthropic)/models/parameter-rules?model=\(model)", token: owner)
            #expect(refused.status == 400 && refused.text.contains("is disabled"))
            #expect(try await api.patch("\(anthropic)/models/enable", json(["model": .string(model), "model_type": "llm"]), token: owner).status == 200)
            #expect(try await api.get("\(anthropic)/models/parameter-rules?model=\(model)", token: owner).data.count == rules.count)
            #expect(try await api.patch("\(anthropic)/models/enable", json(["model": .string(model), "model_type": "poem"]), token: owner).status == 400)
        }
    }

    @Test func customModelsOfAnOpenAICompatibleServerAndOllama() async throws {
        try await withStubProvider { base, log in
            try await withServer { api, _, _ in
                let owner = try await api.setupOwner()
                func credentials(_ key: String) -> JSON {
                    ["endpoint_url": .string("\(base)/oaic"), "api_key": .string(key), "mode": "chat", "context_size": "32768",
                     "max_tokens_to_sample": "8192", "function_calling_type": "tool_call"]
                }
                let created = try await api.post("\(oaic)/models/credentials", json(["model": "qwen3", "model_type": "llm", "credentials": credentials("sk-good-q1")]),
                                                 token: owner)
                #expect(created.status == 201, "\(created.text)")
                // No model list on that server: the 1-token chat request decided. (The form default of stream_function_calling is
                // not_supported, so no stream-tool-call below.)
                #expect(log.requests.map(\.path) == ["/oaic/models", "/oaic/chat/completions"])
                let bad = try await api.post("\(oaic)/models/credentials", json(["model": "qwen3", "model_type": "llm", "credentials": credentials("sk-bad-q")]),
                                             token: owner)
                #expect(bad.status == 400 && bad.errorCode == "credential_validation_failed")
                // Listed for the selectors, with the schema the plugin would compute.
                let llm = try await api.get("/v1/workspace/models/model-types/llm", token: owner).data
                let entry = try #require(llm.first { $0["provider"] == "langgenius/openai_api_compatible/openai_api_compatible" })
                let model = try #require(entry["models"]?.array?.first)
                #expect(model["model"] == "qwen3" && model["fetch_from"] == "customizable-model" && model["status"] == "active")
                #expect(model["features"] == ["multi-tool-call"] && model["model_properties"] == ["mode": "chat", "context_size": 32768])
                let rules = try await api.get("\(oaic)/models/parameter-rules?model=qwen3", token: owner).data
                #expect(rules.map { $0["name"]?.string ?? "" } == ["temperature", "top_p", "frequency_penalty", "presence_penalty", "max_tokens"])
                #expect(rules[4]["max"]?.double == 8192)
                // The provider list: custom models without credentials; the summary: has_custom_models.
                var config = try #require(try await api.get("/v1/workspace/model-providers", token: owner).data.first {
                    $0["provider"] == "langgenius/openai_api_compatible/openai_api_compatible"
                }?["custom_configuration"])
                let custom = try #require(config["custom_models"]?.array?.first)
                let firstId = try #require(custom["current_credential_id"]?.string)
                #expect(custom["model"] == "qwen3" && custom["credentials"] == .null && custom["unadded_to_model_list"] == false && config["status"] == "active")
                let summary = try #require(try await api.get("/v1/workspace/model-providers/summary", token: owner).data.first {
                    $0["provider"] == "langgenius/openai_api_compatible/openai_api_compatible"
                })
                #expect(summary["custom_configuration"]?["has_custom_models"] == true && summary["is_configured"] == true)
                // Masked on read, with the model's credentials as the available ones.
                let read = try await api.get("\(oaic)/models/credentials?model=qwen3&model_type=llm", token: owner)
                #expect(read.j["credentials"]?["api_key"] == "sk-goo************q1" && read.j["current_credential_id"] == .string(firstId))
                #expect(read.j["load_balancing"] == ["enabled": false, "configs": []] && read.j["available_credentials"]?.array?.count == 1)
                // A second credential, then switching between them (Dify's "add to model list").
                #expect(try await api.post("\(oaic)/models/credentials", json(["model": "qwen3", "model_type": "llm", "name": "backup",
                                                                               "credentials": credentials("sk-good-q2")]), token: owner).status == 201)
                let both = try await api.get("\(oaic)/models/credentials?model=qwen3&model_type=llm", token: owner).j["available_credentials"]?.array ?? []
                let secondId = try #require(both.first { $0["credential_name"] == "backup" }?["credential_id"]?.string)
                #expect(try await api.post("\(oaic)/models/credentials/switch", json(["model": "qwen3", "model_type": "llm", "credential_id": .string(secondId)]),
                                           token: owner).status == 200)
                #expect(try await api.get("\(oaic)/models/credentials?model=qwen3&model_type=llm", token: owner).j["current_credential_name"] == "backup")
                #expect(try await api.post("\(oaic)/models/credentials/switch", json(["model": "qwen3", "model_type": "llm", "credential_id": .string(secondId)]),
                                           token: owner).status == 400)  // "Can't add same credential"
                // Hidden round trip on a model credential.
                log.reset()
                var hidden = credentials("[__HIDDEN__]")
                if case .object(var m) = hidden { m["context_size"] = "65536"; hidden = .object(m) }
                #expect(try await api.put("\(oaic)/models/credentials", json(["model": "qwen3", "model_type": "llm", "credential_id": .string(secondId),
                                                                              "credentials": hidden]), token: owner).status == 200)
                #expect(log.keys.allSatisfy { $0 == "sk-good-q2" } && !log.keys.isEmpty)
                #expect(try await api.get("/v1/workspace/models/model-types/llm", token: owner).data.first {
                    $0["provider"] == "langgenius/openai_api_compatible/openai_api_compatible"
                }?["models"]?.array?.first?["model_properties"]?["context_size"] == 65536)
                // Out of the model list: offered as can_added; back in with POST /models.
                #expect(try await api.delete("\(oaic)/models", json(["model": "qwen3", "model_type": "llm"]), token: owner).status == 204)
                config = try #require(try await api.get("/v1/workspace/model-providers", token: owner).data.first {
                    $0["provider"] == "langgenius/openai_api_compatible/openai_api_compatible"
                }?["custom_configuration"])
                #expect(config["can_added_models"] == [["model": "qwen3", "model_type": "llm"]])
                #expect(config["custom_models"]?.array?.first?["unadded_to_model_list"] == true)
                #expect(try await api.get("/v1/workspace/models/model-types/llm", token: owner).data.isEmpty)
                #expect(try await api.post("\(oaic)/models", json(["model": "qwen3", "model_type": "llm", "config_from": "custom-model"]), token: owner).status == 400)
                #expect(try await api.post("\(oaic)/models", json(["model": "qwen3", "model_type": "llm", "config_from": "custom-model",
                                                                   "credential_id": .string(firstId)]), token: owner).status == 404)  // not in the list
                #expect(try await api.post("\(oaic)/models/credentials/switch", json(["model": "qwen3", "model_type": "llm", "credential_id": .string(firstId)]),
                                           token: owner).status == 200)  // adds it again
                #expect(try await api.post("\(oaic)/models", json(["model": "qwen3", "model_type": "llm", "config_from": "custom-model",
                                                                   "credential_id": .string(secondId)]), token: owner).j == ["result": "success"])
                #expect(try await api.get("/v1/workspace/models/model-types/llm", token: owner).data.count == 1)
                // Deleting both credentials removes the model.
                for id in [firstId, secondId] {
                    #expect(try await api.delete("\(oaic)/models/credentials", json(["model": "qwen3", "model_type": "llm", "credential_id": .string(id)]),
                                                 token: owner).status == 204)
                }
                #expect(try await api.get("/v1/workspace/models/model-types/llm", token: owner).data.isEmpty)
                #expect(try await api.get("/v1/workspace/model-providers/summary", token: owner).data.first {
                    $0["provider"] == "langgenius/openai_api_compatible/openai_api_compatible"
                }?["is_configured"] == false)
                // Providers without custom models refuse model credentials.
                #expect(try await api.post("/v1/workspace/model-providers/langgenius/deepseek/deepseek/models/credentials",
                                           json(["model": "m", "model_type": "llm", "credentials": ["api_key": "sk-good-1"]]), token: owner).status == 400)
                // Ollama: /api/show knows the model or not.
                let llama = try await api.post("\(ollama)/models/credentials", json(["model": "llama3", "model_type": "llm", "credentials": [
                    "base_url": .string(base), "mode": "chat", "context_size": "8192", "max_tokens": "4096"]]), token: owner)
                #expect(llama.status == 201, "\(llama.text)")
                let unknown = try await api.post("\(ollama)/models/credentials", json(["model": "mistral", "model_type": "llm", "credentials": [
                    "base_url": .string(base), "mode": "chat", "context_size": "8192", "max_tokens": "4096"]]), token: owner)
                #expect(unknown.status == 400 && unknown.text.contains("model 'mistral' not found"))
                let ollamaRules = try await api.get("\(ollama)/models/parameter-rules?model=llama3", token: owner).data
                #expect(ollamaRules.count == 19 && ollamaRules.first { $0["name"] == "num_predict" }?["max"]?.double == 4096)
            }
        }
    }

    @Test func secretEnvironmentVariablesAreEncryptedAndOldRowsAreMigrated() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            #expect(try await api.put("/v1/docs/d1", #"{"template":"empty"}"#, token: owner).status == 201)
            let stored = try await api.post("/v1/docs/d1/secrets", #"{"value":"s3cret-value-123"}"#, token: owner)
            #expect(stored.status == 201)
            let ref = stored.str("ref")
            var rows: [(String, Bool)] = []
            for try await row in try await store.client.query("SELECT value, sealed FROM secrets WHERE doc_id = 'd1'", logger: store.logger)
                .decode((String, Bool).self) { rows.append(row) }
            #expect(rows.count == 1 && rows[0].1 && rows[0].0.hasPrefix("v1:") && !rows[0].0.contains("s3cret"))
            #expect(try await store.secrets("d1") == [ref: "s3cret-value-123"])
            // A row an older server wrote in plaintext: readable as it is, then sealed by the migration.
            _ = try await store.client.query("INSERT INTO secrets (doc_id, ref, value) VALUES ('d1', 'sec-old', 'old-plain-secret')", logger: store.logger)
            #expect(try await store.secrets("d1")["sec-old"] == "old-plain-secret")
            let migrated = try await store.sealLegacySecrets()
            #expect(migrated.sealed == 1 && migrated.plaintextLeft == 0)
            var old: (String, Bool)?
            for try await row in try await store.client.query("SELECT value, sealed FROM secrets WHERE ref = 'sec-old'", logger: store.logger)
                .decode((String, Bool).self) { old = row }
            #expect(old?.1 == true && old?.0.contains("old-plain") == false)
            #expect(try await store.secrets("d1") == [ref: "s3cret-value-123", "sec-old": "old-plain-secret"])
            #expect(try await store.sealLegacySecrets().sealed == 0)  // idempotent
            // Export with include_secret still gives the plaintext.
            let export = try await api.get("/v1/docs/d1/export?include_secret=true", token: owner)
            #expect(export.status == 200)
            // Without a key the migration leaves plaintext rows and says how many.
            let keyless = PostgresStore(client: store.client, logger: store.logger, cipher: nil)
            _ = try await store.client.query("INSERT INTO secrets (doc_id, ref, value) VALUES ('d1', 'sec-old2', 'p')", logger: store.logger)
            let left = try await keyless.sealLegacySecrets()
            #expect(left.sealed == 0 && left.plaintextLeft == 1)
            #expect(try await keyless.secrets("d1") == ["sec-old2": "p"])  // sealed rows cannot be read without the key
        }
    }
}
