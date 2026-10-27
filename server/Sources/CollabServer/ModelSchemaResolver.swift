import CollabModels
import CollabRuntime
import Crypto
import Foundation

/// Settings and workflow execution read the same original model plugin schema.
/// Cached keys contain a credential ID and digest; credentials and daemon replies
/// are never logged, persisted, or exposed through a settings response.
struct ResolvedModelSchema: Sendable {
    var schema: ModelSchema?
    var status: String
    var error: String?

    static func ready(_ schema: ModelSchema) -> Self { .init(schema: schema, status: "ready") }
    static let unknown = Self(schema: nil, status: "unknown", error: "model_schema_unavailable")
    static let missing = Self(schema: nil, status: "unavailable", error: "model_schema_missing")
}

actor ModelSchemaCache {
    struct Entry { var value: ResolvedModelSchema; var at: Date }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<ResolvedModelSchema, Never>] = [:]

    func resolve(_ key: String, now: Date = Date(), load: @escaping @Sendable () async -> ResolvedModelSchema) async -> ResolvedModelSchema {
        if let entry = entries[key], now.timeIntervalSince(entry.at) < (entry.value.status == "ready" ? 30 : 3) {
            return entry.value
        }
        if let task = pending[key] { return await task.value }
        let previous = entries[key]?.value.schema
        let task = Task {
            var value = await load()
            // A transient failure does not erase previously verified metadata.
            // Its availability remains explicitly unknown, even with a cached schema.
            if value.status == "unknown", value.schema == nil { value.schema = previous }
            return value
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        entries[key] = Entry(value: value, at: now)
        if entries.count > 256, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries[oldest] = nil }
        return value
    }
}

extension Routes {
    func customModelSchema(_ def: ProviderDefinition, _ model: CustomModelView) async -> ResolvedModelSchema {
        guard let credentials = model.config, !credentials.isEmpty else { return .unknown }
        if !runtimeConfigured {
            // The two fully ported plugins also work without a daemon. Other
            // plugins need their own schema: never substitute a generic 4K LLM.
            if ["langgenius/ollama/ollama", "langgenius/openai_api_compatible/openai_api_compatible"].contains(def.id.description),
               let schema = CustomModels.schema(provider: def, model: model.key.model, modelType: model.key.modelType, credentials: credentials) {
                return .ready(schema)
            }
            let base = model.key.model.hasPrefix("ft:") ? model.key.model.split(separator: ":", maxSplits: 2).dropFirst().first.map(String.init) : model.key.model
            if def.id.description == "langgenius/openai/openai", let base, let inherited = def.model(base, type: model.key.modelType) {
                var schema = inherited.schema
                schema.model = model.key.model
                schema.label = ["en_US": .string(model.key.model), "zh_Hans": .string(model.key.model)]
                schema.fetchFrom = "customizable-model"
                return .ready(schema)
            }
            return .unknown
        }
        let encoded = (try? Self.encodeConfig(credentials)) ?? ""
        let digest = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = [config.pluginDaemonTenant, def.id.description, model.key.model, model.key.modelType, model.currentId ?? "", digest].joined(separator: "\u{0}")
        let daemon = PluginDaemonClient(baseURL: config.pluginDaemonURL, key: config.pluginDaemonKey, tenant: config.pluginDaemonTenant,
                                        timeoutSeconds: min(15, max(1, config.pluginDaemonTimeoutSeconds)))
        let provider = def.id.description, name = model.key.model, type = model.key.modelType
        return await models.schemas.resolve(key) {
            do {
                let runtime = PluginDaemonModelRuntime(daemon: daemon, credentialsOf: { _, _, _ in [:] }, appId: nil)
                let input = try JSONValue.parse(Data(try JSONCoding.encode(JSON.object(credentials))))
                guard let result = try await runtime.modelSchema(provider: provider, model: name, modelType: type, credentials: input.object ?? [:]) else { return .missing }
                let raw = try JSONCoding.decode(Data(result.json.compactJSON().utf8))
                guard raw["model_type"]?.string == type, let props = raw["model_properties"]?.object,
                      let rules = raw["parameter_rules"]?.array else { return .unknown }
                let schema = ModelSchema(model: name,
                    label: raw["label"] ?? ["en_US": .string(name), "zh_Hans": .string(name)], modelType: type,
                    features: raw["features"]?.array?.compactMap(\.string), fetchFrom: "customizable-model",
                    modelProperties: props, deprecated: raw["deprecated"]?.bool ?? false, parameterRules: rules)
                return .ready(schema)
            } catch {
                // Daemon errors can quote submitted credentials. Only the stable,
                // non-secret error code crosses the settings boundary.
                return .unknown
            }
        }
    }
}
