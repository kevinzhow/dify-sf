import CollabModels
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

private func originalSchemaCases() throws -> [JSONValue] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/model-providers/pinned-plugin-schemas.json")
    return try #require(JSONValue.parse(Data(contentsOf: path)).array)
}

final class SchemaScenario: Sendable {
    let installed = Mutex(true)
    let failure = Mutex(false)
    let catalogFails = Mutex(false)
    let taskStatus = Mutex("failed")
    let schemaDelay = Mutex(false)
    let schemaRequests = Mutex((active: 0, peak: 0))
}

/// Uses schemas captured from all ten actual signed plugins, without provider calls.
private func withOriginalSchemaDaemon(_ body: @Sendable @escaping (String, DaemonLog, SchemaScenario) async throws -> Void) async throws {
    let cases = try originalSchemaCases(), pins = try ProviderPlugin.bundled()
    let log = DaemonLog(), scenario = SchemaScenario()
    let rows: [JSONValue] = pins.map { ["id": .string(UUID().uuidString.lowercased()), "plugin_id": .string($0.id),
        "plugin_unique_identifier": .string($0.uniqueIdentifier), "declaration": ["version": .string($0.version)]] }
    try await withApp(configure: { app in
        app.get("plugin", ":tenant", "management", "list") { _ -> Response in
            if scenario.catalogFails.withLock({ $0 }) { return Response(status: .serviceUnavailable) }
            let value: JSONValue = ["code": 0, "data": ["list": .array(scenario.installed.withLock { $0 } ? rows : [])]]
            return Response(status: .ok, body: .init(string: value.compactJSON()))
        }
        app.post("plugin", ":tenant", "management", "uninstall") { _ -> Response in
            scenario.installed.withLock { $0 = false }
            return Response(status: .ok, body: .init(string: JSONValue.object(["code": 0, "data": true]).compactJSON()))
        }
        app.get("plugin", ":tenant", "management", "install", "tasks", ":task") { _ -> Response in
            let value: JSONValue = ["code": 0, "data": ["status": .string(scenario.taskStatus.withLock { $0 }), "error": "fixture-not-a-key"]]
            return Response(status: .ok, body: .init(string: value.compactJSON()))
        }
        app.post("plugin", ":tenant", "dispatch", "model", "schema") { req async throws -> Response in
            let raw = try await req.body.collect(max: .specified(ByteCount(value: 1 << 20)))
            let input = try JSONValue.parse(raw ?? Data())
            log.add(.init(path: "schema", body: input))
            scenario.schemaRequests.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            defer { scenario.schemaRequests.withLock { $0.active -= 1 } }
            if scenario.schemaDelay.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(100)) }
            let name = input["data"]?["model"]?.string, provider = input["data"]?["provider"]?.string
            let found = cases.first { $0["model"]?.string == name && $0["provider"]?.string?.split(separator: "/").last.map(String.init) == provider }
            var value: JSONValue
            if scenario.failure.withLock({ $0 }) {
                value = ["code": -500, "message": .string(JSONValue.object(["error_type": "PluginDaemonInnerError", "message": "fixture-not-a-key must never appear"]).compactJSON()), "data": .null]
            } else if found?["status"] == "expected-unknown-model" || found == nil {
                value = ["code": -500, "message": .string(JSONValue.object(["error_type": "ValueError", "message": "Base model not found"]).compactJSON()), "data": .null]
            } else {
                var schema = found?["schema"] ?? .null
                if let size = input["data"]?["credentials"]?["context_size"]?.string.flatMap(Int.init),
                   var object = schema.object, var properties = object["model_properties"]?.object {
                    properties["context_size"] = .int(size); object["model_properties"] = .object(properties); schema = .object(object)
                }
                value = ["code": 0, "message": "", "data": ["model_schema": schema]]
            }
            var headers = HTTPFields(); headers[.contentType] = "text/event-stream"
            return Response(status: .ok, headers: headers, body: .init(string: "data: " + value.compactJSON() + "\n\n"))
        }
    }) { app in
        try await app.testing(.running) { client in
            let port = try #require(client.port)
            try await body("http://127.0.0.1:\(port)", log, scenario)
        }
    }
}

@Suite("Original provider metadata alignment", .enabled(if: testDbHost != nil))
struct ModelSchemaAlignmentTests {
    @Test func slowMetadataReadsOverlapAndRetainEverySavedModelInOrder() async throws {
        try await withOriginalSchemaDaemon { daemon, _, scenario in
            scenario.schemaDelay.withLock { $0 = true }
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, store, _ in
                let owner = try await api.setupOwner(), provider = "langgenius/openai_api_compatible/openai_api_compatible"
                let names = (0..<8).map { "unrecognized-alias-\($0)" }
                for name in names {
                    _ = try await store.createModelCredential(.init(provider: provider, model: name, modelType: "llm"),
                        name: nil, config: #"{"api_key":"fixture-not-a-key","endpoint_url":"https://example.com/v1"}"#, createdBy: nil)
                }
                let result = try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner)
                #expect(result.status == 200)
                #expect(result.data.compactMap { $0["model"]?.string } == names)
                #expect(result.data.allSatisfy { $0["schema_status"] == "unavailable" && $0["model_properties"] == [:] })
                #expect(scenario.schemaRequests.withLock { $0.peak } > 1)
            }
        }
    }

    @Test func tenProvidersPreserveOriginalCapabilitiesAndParameterRules() async throws {
        let cases = try originalSchemaCases()
        #expect(Set(cases.compactMap { $0["provider"]?.string }).count == 10)
        try await withOriginalSchemaDaemon { daemon, log, _ in
            try await withServerAndRoutes(config: runtimeConfig(daemon: daemon)) { api, store, routes in
                let owner = try await api.setupOwner()
                for item in cases where item["status"] == "passed" {
                    let provider = try #require(item["provider"]?.string), model = try #require(item["model"]?.string)
                    let definition = try #require(routes.models.catalog.provider(provider))
                    let config = try #require(item["credentials"]).compactJSON()
                    if definition.supportsCustomModels {
                        _ = try await store.createModelCredential(.init(provider: provider, model: model, modelType: "llm"), name: nil, config: config, createdBy: nil)
                    } else {
                        _ = try await store.createProviderCredential(provider: provider, name: nil, config: config, createdBy: nil)
                    }
                    let list = try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner)
                    let entry = try #require(list.data.first { $0["model"]?.string == model })
                    let expected = try #require(item["schema"])
                    let props = try JSONCoding.decode(Data(try #require(expected["model_properties"]).compactJSON().utf8))
                    #expect(entry["model_properties"] == props, "\(provider) \(model)")
                    let features = try JSONCoding.decode(Data((expected["features"] ?? .null).compactJSON().utf8))
                    #expect(entry["features"] == features)
                    #expect(entry["status"] == "active" && entry["schema_status"] == nil)
                    let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
                    let parameters = try await api.get("/v1/workspace/model-providers/\(provider)/models/parameter-rules?model=\(escaped)", token: owner)
                    let expectedRules = try #require(expected["parameter_rules"]?.array).map {
                        ParameterRules.output((try? JSONCoding.decode(Data($0.compactJSON().utf8)).object) ?? [:])
                    }
                    #expect(parameters.status == 200 && parameters.data == expectedRules, "\(provider) \(parameters.text)")
                    // The editor runtime sees precisely the same original plugin schema.
                    let runtime = PluginDaemonModelRuntime(daemon: routes.providerPluginDaemon(), credentialsOf: { _, _, _ in [:] }, appId: nil)
                    let runtimeSchema = try await runtime.modelSchema(provider: provider, model: model, modelType: "llm", credentials: item["credentials"]?.object ?? [:])
                    #expect(runtimeSchema?.json["features"] == expected["features"])
                    #expect(runtimeSchema?.json["model_properties"] == expected["model_properties"])
                    #expect(!list.text.contains("fixture-not-a-key") && !parameters.text.contains("fixture-not-a-key"))
                }
                #expect(log.requests.count >= 20)
            }
        }
    }

    @Test func unknownCustomModelAndTransientFailuresKeepSavedRowsWithoutInvented4K() async throws {
        try await withOriginalSchemaDaemon { daemon, _, scenario in
            try await withServerAndRoutes(config: runtimeConfig(daemon: daemon)) { api, store, routes in
                let owner = try await api.setupOwner(), provider = "langgenius/openai/openai", name = "codex/gpt-6.1-terra"
                let key = ModelKey(provider: provider, model: name, modelType: "llm")
                _ = try await store.createModelCredential(key, name: nil, config: #"{"openai_api_key":"fixture-not-a-key"}"#, createdBy: nil)
                var row = try #require(try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner).data.first { $0["model"]?.string == name })
                #expect(row["schema_status"] == "unavailable" && row["schema_error"] == "model_schema_missing")
                #expect(row["model_properties"] == [:] && row["status"] == "no-configure")
                let rules = try await api.get("/v1/workspace/model-providers/\(provider)/models/parameter-rules?model=\(name)", token: owner)
                #expect(rules.status == 400 && rules.errorCode == "model_schema_missing" && rules.text.contains("OpenAI-compatible"))
                scenario.failure.withLock { $0 = true }; await routes.models.schemas.invalidate()
                row = try #require(try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner).data.first { $0["model"]?.string == name })
                #expect(row["schema_status"] == "unknown" && row["model_properties"] == [:])
                let failedRules = try await api.get("/v1/workspace/model-providers/\(provider)/models/parameter-rules?model=\(name)", token: owner)
                #expect(failedRules.status == 503 && !failedRules.text.contains("fixture-not-a-key"))
                #expect(try await store.modelProviderState().modelCredentials[key]?.count == 1)
                scenario.installed.withLock { $0 = false }; await routes.models.plugins.invalidate(); await routes.models.schemas.invalidate()
                row = try #require(try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner).data.first { $0["model"]?.string == name })
                #expect(row["schema_error"] == "plugin_not_installed" && row["status"] == "no-configure")
            }
        }
    }

    @Test func savingAndEditingCustomCapabilitiesRefreshesTheCanonicalSchemaAndKeepsTheSecret() async throws {
        try await withOriginalSchemaDaemon { daemon, log, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, store, _ in
                let owner = try await api.setupOwner(), provider = "langgenius/openai_api_compatible/openai_api_compatible", name = "codex/gpt-6.1-terra"
                let path = "/v1/workspace/model-providers/\(provider)/models/credentials"
                let credentials: JSONValue = ["api_key": "fixture-not-a-key", "endpoint_url": "https://example.com/v1", "mode": "chat", "api_type": "responses",
                    "context_size": "1050000", "max_tokens_to_sample": "128000", "vision_support": "support", "function_calling_type": "tool_call"]
                let created = try await api.post(path, JSONValue.object(["model": .string(name), "model_type": "llm", "credentials": credentials]).compactJSON(), token: owner)
                #expect(created.status == 201, "\(created.text)")
                let key = ModelKey(provider: provider, model: name, modelType: "llm")
                let saved = try #require(try await store.modelProviderState().modelCredentials[key]?.first)
                var changed = credentials.object ?? [:]; changed["context_size"] = "262144"; changed["api_key"] = "[__HIDDEN__]"
                let updated = try await api.put(path, JSONValue.object(["model": .string(name), "model_type": "llm", "credential_id": .string(saved.id), "credentials": .object(changed)]).compactJSON(), token: owner)
                #expect(updated.status == 200, "\(updated.text)")
                let entry = try #require(try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner).data.first { $0["model"]?.string == name })
                #expect(entry["model_properties"]?["context_size"] == 262144)
                #expect(entry["features"]?.array?.contains("vision") == true)
                #expect(log.requests.last?.body["data"]?["credentials"]?["api_key"] == "fixture-not-a-key")
                #expect(log.requests.last?.body["data"]?["credentials"]?["api_type"] == "responses")
                let config = try #require(try await store.modelProviderState().modelCredentials[key]?.first?.config)
                #expect(try JSONCoding.decode(Data(config.utf8))["api_key"] == "fixture-not-a-key")
            }
        }
    }
}

@Suite("Model schema cache availability")
struct ModelSchemaCacheTests {
    @Test func sharesConcurrentReadsRetriesFailuresAndPreservesLastVerifiedMetadata() async throws {
        let cache = ModelSchemaCache(), calls = Mutex(0)
        let schema = ModelSchema(model: "fixture", label: "fixture", modelType: "llm", features: ["vision"], fetchFrom: "customizable-model",
            modelProperties: ["context_size": 1050000], deprecated: false, parameterRules: [])
        let start = Date(timeIntervalSince1970: 1000)
        await withTaskGroup(of: ResolvedModelSchema.self) { group in
            for _ in 0..<4 { group.addTask {
                await cache.resolve("credential-A", now: start) { calls.withLock { $0 += 1 }; try? await Task.sleep(for: .milliseconds(10)); return .ready(schema) }
            } }
            for await result in group { #expect(result.schema == schema && result.status == "ready") }
        }
        #expect(calls.withLock { $0 } == 1)
        let transient = await cache.resolve("credential-A", now: start.addingTimeInterval(31)) { .unknown }
        #expect(transient.status == "unknown" && transient.schema == schema)
        let recovered = await cache.resolve("credential-A", now: start.addingTimeInterval(35)) { .ready(schema) }
        #expect(recovered.status == "ready")
        let changed = await cache.resolve("credential-B", now: start) { .missing }
        #expect(changed.schema == nil && changed.status == "unavailable")
        let missing = await cache.resolve("credential-A", now: start.addingTimeInterval(70)) { .missing }
        #expect(missing.schema == nil)
        await cache.invalidate()
        let fresh = await cache.resolve("credential-A", now: start.addingTimeInterval(71)) { .ready(schema) }
        #expect(fresh.schema == schema)
    }
}

private struct MetadataNoopChecker: CredentialChecker {
    func check(_ plan: CollabModels.Validation.Plan) async -> String? { nil }
}

private final class WrongProviderPackage: ProviderPluginPackageSource, Sendable {
    let calls = Mutex(0)
    func package(_ pin: ProviderPlugin) async throws -> Data { calls.withLock { $0 += 1 }; return Data("incorrect package".utf8) }
}

@Suite("Provider plugin management", .enabled(if: testDbHost != nil))
struct ProviderPluginManagementTests {
    @Test func catalogUsesActualInstallationsAndWritesRequireAnOwnerOrAdmin() async throws {
        try await withOriginalSchemaDaemon { daemon, _, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let owner = try await api.setupOwner()
                let (_, editor) = try await api.member("editor@example.com", role: "editor", inviter: owner)
                let read = try await api.get("/v1/workspace/model-provider-plugins", token: editor)
                #expect(read.status == 200 && read.data.count == 10)
                #expect(read.data.contains { $0["provider"] == "langgenius/gemini/google" })
                #expect(read.data.allSatisfy { $0["status"] == "installed" && $0["installation_id"]?.string != nil })
                #expect(try await api.get("/v1/workspace/model-provider-plugins").status == 401)
                #expect(try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/install", token: editor).status == 403)
                #expect(try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/uninstall", "{}", token: editor).status == 403)
                #expect(try await api.post("/v1/workspace/model-provider-plugins/other/arbitrary/install", token: owner).status == 400)
                #expect(try await api.get("/v1/workspace/model-provider-plugins/tasks/not-a-uuid", token: owner).status == 400)
            }
        }
    }

    @Test func installationIsIdempotentAndRemovalRetainsCredentialsAndModels() async throws {
        try await withOriginalSchemaDaemon { daemon, _, _ in
            let packages = WrongProviderPackage()
            let models = ModelService(catalog: try ModelCatalog.bundled(), checker: MetadataNoopChecker(), validate: false, packages: packages)
            try await withServer(config: runtimeConfig(daemon: daemon), models: models) { api, store, _ in
                let owner = try await api.setupOwner(), provider = "langgenius/openai/openai"
                let key = ModelKey(provider: provider, model: "codex/gpt-6.1-terra", modelType: "llm")
                let id = try await store.createModelCredential(key, name: nil, config: #"{"openai_api_key":"fixture-not-a-key"}"#, createdBy: nil)
                let initial = try await store.modelProviderState()
                let same = try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/install", token: owner)
                #expect(same.status == 200 && same.j["all_installed"] == true && packages.calls.withLock { $0 } == 0)
                let catalog = try await api.get("/v1/workspace/model-provider-plugins", token: owner)
                let installation = try #require(catalog.data.first { $0["provider"] == .string(provider) }?["installation_id"]?.string)
                let stale = try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/uninstall", #"{"installation_id":"stale"}"#, token: owner)
                #expect(stale.status == 409 && stale.errorCode == "plugin_installation_changed")
                let removed = try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/uninstall", JSONValue.object(["installation_id": .string(installation)]).compactJSON(), token: owner)
                #expect(removed.status == 200)
                let after = try await store.modelProviderState()
                #expect(after.customModelOrder == initial.customModelOrder)
                #expect(after.modelCredentials[key]?.first?.id == id && after.modelCredentials[key]?.first?.config == initial.modelCredentials[key]?.first?.config)
                let list = try await api.get("/v1/workspace/model-providers/\(provider)/models", token: owner)
                #expect(list.data.first { $0["model"] == "codex/gpt-6.1-terra" }?["schema_error"] == "plugin_not_installed")
                // A changed package is rejected before upload, even from an injected source.
                let install = try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/install", token: owner)
                #expect(install.status == 503 && packages.calls.withLock { $0 } == 1)
                #expect(try await store.modelProviderState().modelCredentials[key]?.first?.id == id)
            }
        }
    }

    @Test func anUnavailableCatalogNeverAuthorizesInstallationOrRemoval() async throws {
        try await withOriginalSchemaDaemon { daemon, _, scenario in
            let packages = WrongProviderPackage()
            let models = ModelService(catalog: try ModelCatalog.bundled(), checker: MetadataNoopChecker(), validate: false, packages: packages)
            try await withServer(config: runtimeConfig(daemon: daemon), models: models) { api, _, _ in
                let owner = try await api.setupOwner()
                scenario.catalogFails.withLock { $0 = true }
                let rows = try await api.get("/v1/workspace/model-provider-plugins", token: owner)
                #expect(rows.status == 200 && rows.data.count == 10 && rows.data.allSatisfy { $0["status"] == "unknown" })
                #expect(try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/install", token: owner).status == 503)
                #expect(try await api.post("/v1/workspace/model-provider-plugins/langgenius/openai/uninstall", "{}", token: owner).status == 503)
                #expect(packages.calls.withLock { $0 } == 0)
                scenario.catalogFails.withLock { $0 = false }
                let recovered = try await api.get("/v1/workspace/model-provider-plugins", token: owner)
                #expect(recovered.data.allSatisfy { $0["status"] == "installed" })
            }
        }
    }

    @Test func taskErrorsAreSanitizedAndSuccessClearsStaleMetadata() async throws {
        try await withOriginalSchemaDaemon { daemon, _, scenario in
            try await withServerAndRoutes(config: runtimeConfig(daemon: daemon)) { api, _, routes in
                let owner = try await api.setupOwner(), id = UUID().uuidString.lowercased()
                let path = "/v1/workspace/model-provider-plugins/tasks/\(id)"
                let failed = try await api.get(path, token: owner)
                #expect(failed.status == 200 && failed.j["status"] == "failed" && !failed.text.contains("fixture-not-a-key"))
                _ = await routes.models.schemas.resolve("previous-failure") { .unknown }
                scenario.taskStatus.withLock { $0 = "success" }
                let done = try await api.get(path, token: owner)
                #expect(done.j["status"] == "success" && done.j["error"] == .null)
                let fresh = await routes.models.schemas.resolve("previous-failure") { .missing }
                #expect(fresh.status == "unavailable")
            }
        }
    }
}
