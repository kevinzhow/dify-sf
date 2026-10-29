import CollabModels
import CollabRuntime
import Foundation

/// The compatible provider describes an arbitrary upstream service. Its plugin's
/// built-in menu is a recommendation, not evidence of that service's enum.
enum ModelReasoning {
    static let levelsKey = "_dify_sf_reasoning_levels"

    static func declared(_ credentials: [String: JSON]) -> [String]? {
        let field = credentials[ModelDiscovery.metadataKey]?["model"]?["fields"]?["reasoning_levels"]
        guard field?["source"] == "provider" else { return nil }
        return validLevels(field?["value"])
    }

    private static func validLevels(_ value: JSON?) -> [String]? {
        guard let values = ModelDiscovery.strings(value),
              !values.isEmpty, values.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return nil }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Runtime credentials already contain only the verified provider enum. The
    /// compatible plugin's built-in options are suggestions, just as in settings.
    /// Nil means the service validates custom values; do not advertise suggestions
    /// as an authoritative capability list to the Agent harness either.
    static func runtimeOptions(provider: String, credentials: JSONObject, rule: JSONValue?) -> [JSONValue]? {
        if provider == ModelDiscovery.provider {
            guard let raw = credentials[levelsKey],
                  let value = try? JSONCoding.decode(Data(raw.compactJSON().utf8)),
                  let values = validLevels(value) else { return nil }
            return values.map(JSONValue.string)
        }
        guard rule?["allow_custom_value"] != true, let values = rule?["options"]?.array, !values.isEmpty else { return nil }
        return values
    }

    /// Pass only bounded, non-secret discovery data to the host compatibility
    /// layer. Remove the full receipt, even for providers that do not use it.
    static func runtimeCredentials(_ credentials: [String: JSON], provider: String) -> [String: JSON] {
        var result = credentials.filter { $0.key != ModelDiscovery.metadataKey && $0.key != levelsKey }
        if provider == ModelDiscovery.provider, let values = declared(credentials) {
            result[levelsKey] = .array(values.map(JSON.string))
        }
        return result
    }

    static func apply(_ schema: inout ModelSchema, provider: String, credentials: [String: JSON]) {
        schema.parameterRules = rules(schema.parameterRules, provider: provider, credentials: credentials)
    }

    static func referenced(_ credentials: [String: JSON]) -> [String]? {
        guard let connection = try? ModelDiscovery.Connection(credentials), ModelDiscoveryReference.isOfficial(connection),
              let model = credentials[ModelDiscovery.metadataKey]?["model"], let id = model["id"]?.string,
              model["fields"]?["reasoning_levels"]?["source"] == "reference",
              let reference = ModelDiscoveryReference.model(id, connection: connection, catalog: nil),
              model["fields"]?["reasoning_levels"]?["value"] == reference["fields"]?["reasoning_levels"]?["value"] else { return nil }
        let mapped = credentials["endpoint_model_name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard mapped.isEmpty || mapped == id else { return nil }
        return validLevels(reference["fields"]?["reasoning_levels"]?["value"])
    }

    static func rules(_ input: [JSON], provider: String, credentials: [String: JSON]) -> [JSON] {
        guard provider == ModelDiscovery.provider else { return input }
        let declared = declared(credentials), referenced = referenced(credentials)
        let values = declared ?? referenced
        return input.map { raw in
            guard raw["name"] == "reasoning_effort", var rule = raw.object else { return raw }
            if let values { rule["options"] = .array(values.map(JSON.string)) }
            rule["allow_custom_value"] = .bool(declared == nil)
            rule["options_source"] = declared != nil ? "provider" : referenced != nil ? "reference" : "plugin"
            rule["help"] = referenced != nil && declared == nil
                ? ["en_US": "Suggested values come from the official model documentation. Other values are validated by the service.",
                   "zh_Hans": "推荐档位来自官方模型说明；其他档位由服务校验。"]
                : values == nil
                ? ["en_US": "Suggested values come from the plugin. Enter another value if your service supports it; the service validates it.",
                   "zh_Hans": "推荐值来自插件。可填写服务支持的其他档位，由服务校验。"]
                : ["en_US": "Supported values declared by the model service.", "zh_Hans": "这些档位由模型服务声明支持。"]
            return .object(rule)
        }
    }
}
