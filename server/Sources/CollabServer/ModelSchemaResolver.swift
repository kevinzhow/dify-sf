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
    private var generation = 0

    func invalidate() {
        generation += 1
        entries.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    func resolve(_ key: String, now: Date = Date(), load: @escaping @Sendable () async -> ResolvedModelSchema) async -> ResolvedModelSchema {
        if let entry = entries[key], now.timeIntervalSince(entry.at) < (entry.value.status == "ready" ? 30 : 3) {
            return entry.value
        }
        if let task = pending[key] { return await task.value }
        let previous = entries[key]?.value.schema
        // Keep settings responsive when many saved models share an unavailable
        // daemon, without starting an unbounded number of metadata requests.
        guard pending.count < 32 else { return .init(schema: previous, status: "unknown", error: "model_schema_unavailable") }
        let started = generation
        let task = Task {
            var value = await load()
            // A transient failure does not erase previously verified metadata.
            // Its availability remains explicitly unknown, even with a cached schema.
            if value.status == "unknown", value.schema == nil { value.schema = previous }
            return value
        }
        pending[key] = task
        let value = await task.value
        guard generation == started else { return value }
        pending[key] = nil
        entries[key] = Entry(value: value, at: now)
        if entries.count > 256, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries[oldest] = nil }
        return value
    }
}

extension Routes {
    func customModelSchema(_ def: ProviderDefinition, _ model: CustomModelView) async -> ResolvedModelSchema {
        guard let credentials = model.config, !credentials.isEmpty else { return .unknown }
        return await resolvedModelSchema(def, name: model.key.model, type: model.key.modelType, credentials: credentials, credentialId: model.currentId)
    }

    func resolvedModelSchema(_ def: ProviderDefinition, name: String, type: String, credentials: [String: JSON], credentialId: String?) async -> ResolvedModelSchema {
        if !runtimeConfigured {
            // The two fully ported plugins also work without a daemon. Other
            // plugins need their own schema: never substitute a generic 4K LLM.
            if ["langgenius/ollama/ollama", "langgenius/openai_api_compatible/openai_api_compatible"].contains(def.id.description),
               let schema = CustomModels.schema(provider: def, model: name, modelType: type, credentials: credentials) {
                return .ready(schema)
            }
            let base = name.hasPrefix("ft:") ? name.split(separator: ":", maxSplits: 2).dropFirst().first.map(String.init) : name
            if def.id.description == "langgenius/openai/openai", let base, let inherited = def.model(base, type: type) {
                var schema = inherited.schema
                schema.model = name
                schema.label = ["en_US": .string(name), "zh_Hans": .string(name)]
                schema.fetchFrom = "customizable-model"
                return .ready(schema)
            }
            return .unknown
        }
        let plugins = await installedProviderPlugins()
        if plugins.known && plugins.plugin(def.id.pluginId) == nil {
            return .init(schema: nil, status: "unavailable", error: "plugin_not_installed")
        }
        let encoded = (try? Self.encodeConfig(credentials)) ?? ""
        let digest = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = [config.pluginDaemonTenant, def.id.description, name, type, credentialId ?? "", digest].joined(separator: "\u{0}")
        let daemon = PluginDaemonClient(baseURL: config.pluginDaemonURL, key: config.pluginDaemonKey, tenant: config.pluginDaemonTenant,
                                        timeoutSeconds: min(5, max(1, config.pluginDaemonTimeoutSeconds)))
        let provider = def.id.description
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
                    modelProperties: props, deprecated: raw["deprecated"]?.bool ?? false,
                    parameterRules: rules.map { ParameterRules.output($0.object ?? [:]) })
                return .ready(schema)
            } catch let error as PluginDaemonWire.DaemonError where error.errorType == "ValueError" {
                return .missing
            } catch {
                // Daemon errors can quote submitted credentials. Only the stable,
                // non-secret error code crosses the settings boundary.
                return .unknown
            }
        }
    }
}
