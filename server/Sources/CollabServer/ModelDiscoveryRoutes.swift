import CollabModels
import CollabStore
import Foundation
import Vapor

extension Routes {
    func discoveryProvider(_ req: Request) throws -> ProviderDefinition {
        let def = try provider(req)
        guard def.id.description == ModelDiscovery.provider else {
            throw ServerError.badRequest("Automatic discovery is available for OpenAI-API-compatible language models.")
        }
        return def
    }

    func discoverModels(_ req: Request) async throws -> Response {
        let principal = try await authenticate(req, .privileged)
        _ = try discoveryProvider(req)
        let connection = try ModelDiscovery.Connection(credentialsBody(try await jsonBody(req)))
        try await modelDiscoveryReceipts.begin(principal.id)
        do {
            var value = try await ModelDiscovery.discover(connection).object ?? [:]
            value["discovery_id"] = .string(await modelDiscoveryReceipts.put(owner: principal.id, binding: connection.binding, value: .object(value)))
            await modelDiscoveryReceipts.end(principal.id)
            return try json(JSON.object(value))
        } catch {
            await modelDiscoveryReceipts.end(principal.id)
            throw error
        }
    }

    func probeModelCapabilities(_ req: Request) async throws -> Response {
        let principal = try await authenticate(req, .privileged)
        _ = try discoveryProvider(req)
        let input = try await jsonBody(req)
        guard input["consent"]?.bool == true else {
            throw ServerError.badRequest("Confirm the capability probe: it makes up to seven short model requests and may incur provider charges.")
        }
        let connection = try ModelDiscovery.Connection(credentialsBody(input))
        let model = try requiredString(input, "model")
        let protocolName = try requiredString(input, "api_type")
        try await modelDiscoveryReceipts.begin(principal.id, probe: true)
        do {
            var value = try await ModelCapabilityProbe.run(connection, model: model, protocolName: protocolName).object ?? [:]
            value["probe_id"] = .string(await modelDiscoveryReceipts.put(owner: principal.id, binding: connection.binding, value: .object(value)))
            await modelDiscoveryReceipts.end(principal.id)
            return try json(JSON.object(value))
        } catch {
            await modelDiscoveryReceipts.end(principal.id)
            throw error
        }
    }

    func saveAutofilledModel(_ req: Request) async throws -> Response {
        let principal = try await authenticate(req, .privileged)
        let def = try discoveryProvider(req)
        let body = try await jsonBody(req)
        let model = try requiredString(body, "model")
        guard ModelDiscovery.validModel(model) else { throw ServerError.badRequest("Enter a complete model name of at most 512 bytes.") }
        let input = try credentialsBody(body)
        let mapped = input["endpoint_model_name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveModel = mapped.isEmpty ? model : mapped
        guard ModelDiscovery.validModel(effectiveModel) else { throw ServerError.badRequest("Enter a valid endpoint model name.") }
        let connection = try ModelDiscovery.Connection(input)
        let discovery = try await modelDiscoveryReceipts.get(body["discovery_id"]?.string, owner: principal.id, binding: connection.binding)
        let probe = try await modelDiscoveryReceipts.get(body["probe_id"]?.string, owner: principal.id, binding: connection.binding)
        guard discovery != nil || probe?["fields"]?["api_type"]?["source"] == "observed" else {
            throw ServerError.badRequest("Fetch the model list or explicitly probe this connection before adding a model.")
        }
        let listed = discovery?["models"]?.array?.first { $0["id"]?.string == effectiveModel }
        var selected = listed ?? ModelDiscovery.normalize([:], id: effectiveModel)
        if let probe {
            guard probe["id"]?.string == effectiveModel, probe["protocol"]?.string == input["api_type"]?.string else {
                throw ServerError.badRequest("The probe belongs to a different model or API type. Run it again or restore the original settings.")
            }
            var fields = selected["fields"]?.object ?? [:]
            for (key, value) in probe["fields"]?.object ?? [:] where value["source"]?.string == "observed" {
                fields[key] = value
            }
            selected = ["id": .string(effectiveModel), "fields": .object(fields)]
        }
        let defaults = ModelDiscovery.defaults(selected)
        let merged = defaults.merging(input) { _, submitted in submitted }
        for field in ["context_size", "max_tokens_to_sample"] {
            guard let raw = merged[field]?.string, let count = Int(raw), (1...1_000_000_000).contains(count) else {
                throw ServerError.badRequest("Usage budgets must be positive whole numbers.")
            }
        }
        let name = try credentialName(body)
        try requireSecretsKey()
        // A bound receipt proves this exact connection was fetched/probed.
        // Keep the original plugin's form/schema checks, without the existing
        // credential checker's paid POST fallback when /models is unavailable.
        var checked = try await checkedCredentials(def, model: model, modelType: "llm", merged, checkProvider: false)
        checked[ModelDiscovery.metadataKey] = ModelAutofillMetadata.make(model: selected, defaults: defaults, actual: checked,
            listed: listed != nil, probe: probe)
        let config = try Self.encodeConfig(checked)
        let key = ModelKey(provider: def.id.description, model: model, modelType: "llm")
        _ = try await modelStoreCall { try await store.createModelCredential(key, name: name, config: config, createdBy: principal.id) }
        await models.schemas.invalidate()
        return try ok(.created)
    }
}

enum ModelAutofillMetadata {
    static let settingFields = ["display_name", "api_type", "context_size", "max_tokens_to_sample", "vision_support", "function_calling_type", "structured_output_support"]
    static func make(model: JSON, defaults: [String: JSON], actual: [String: JSON], listed: Bool, probe: JSON?) -> JSON {
        var settings: [String: JSON] = [:]
        let mapping = ["display_name": "display_name", "api_type": "api_type", "vision_support": "vision", "function_calling_type": "tools",
                       "context_size": "context_capacity", "max_tokens_to_sample": "output_capacity", "structured_output_support": "json_schema"]
        for key in settingFields {
            let origin = model["fields"]?[mapping[key] ?? ""]?["source"]?.string ?? "unknown"
            let source = actual[key] != defaults[key] ? "manual" : origin == "unknown" ? "application_default" : origin
            settings[key] = ModelDiscovery.field(actual[key], source)
        }
        return ["version": 1, "model": model, "listed": .bool(listed), "settings": .object(settings),
                "observations": probe?["observations"] ?? [:], "probed_at": probe?["probed_at"] ?? .null,
                "saved_at": .string(ISO8601DateFormatter().string(from: Date()))]
    }
    static func edited(_ metadata: JSON, old: [String: JSON], new: [String: JSON]) -> JSON {
        var result = metadata.object ?? [:]
        var settings = metadata["settings"]?.object ?? [:]
        let changedConnection = ["endpoint_url", "api_key", "endpoint_model_name", "api_type"].contains { old[$0] != new[$0] }
        if changedConnection {
            result["model"] = ModelDiscovery.normalize([:], id: metadata["model"]?["id"]?.string ?? "")
            result["observations"] = [:]
            result["probed_at"] = .null
            result["listed"] = false
        }
        for key in settingFields where changedConnection || old[key] != new[key] {
            settings[key] = ModelDiscovery.field(new[key], "manual")
        }
        result["settings"] = .object(settings)
        return .object(result)
    }
}
