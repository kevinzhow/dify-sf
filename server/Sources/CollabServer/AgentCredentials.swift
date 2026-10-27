import CollabRuntime
import CollabStore
import Foundation

extension Routes {
    /// Explicit references never silently fall back to a different credential. Provider keys stay inside Swift.
    func agentCredentials(provider: String, model: String, reference: JSONValue?) async throws -> JSONObject {
        // Reuse normal catalog, model-enabled and configured checks, even for an explicitly selected private credential.
        guard let reference, reference != .null else { return try await currentCredentials(provider: provider, model: model, modelType: "llm") }
        guard let definition = models.catalog.provider(provider) else { throw NodeError("AgentModelUnsupported", "The model provider is unavailable") }
        let state = try await store.modelProviderState()
        let providerView = view(definition, state)
        let key = ModelKey(provider: definition.id.description, model: model, modelType: "llm")
        guard providerView.settings[key] != false,
              definition.models.contains(where: { $0.model == model && $0.modelType == "llm" }) ||
              providerView.customModels.contains(where: { !$0.unadded && $0.key.model == model && $0.key.modelType == "llm" }) else {
            throw NodeError("AgentModelUnsupported", "The selected agent model is unavailable or disabled")
        }
        guard let type = reference["type"]?.string, let id = reference["id"]?.string, !id.isEmpty,
              reference["provider"] == nil || reference["provider"] == .null || reference["provider"] == .string(provider) else {
            throw NodeError("AgentCredentialInvalid", "The agent model credential reference is invalid")
        }
        let stored: StoredModelCredential
        switch type {
        case "provider", "provider_credential": stored = try await store.providerCredential(provider: provider, id: id)
        case "model", "model_credential": stored = try await store.modelCredential(.init(provider: provider, model: model, modelType: "llm"), id: id)
        default: throw NodeError("AgentCredentialInvalid", "This agent credential reference type is not supported")
        }
        guard let config = stored.config, let object = try JSONValue.parse(config).object, !object.isEmpty else {
            throw NodeError("AgentCredentialInvalid", "The agent model credential is unavailable")
        }
        return JSONObject(object.filter { $0.key != ModelDiscovery.metadataKey })
    }
}
