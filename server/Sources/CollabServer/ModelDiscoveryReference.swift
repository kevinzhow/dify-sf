import CollabModels
import Foundation

/// A model list establishes availability, not every capability. For the official
/// origin only, reuse our existing provider catalog and fill its newer-model gaps
/// from explicitly dated official documentation. Never apply these facts to an
/// alias or another service, even when it uses an identical model name.
enum ModelDiscoveryReference {
    static let documented: JSON? = {
        guard let directory = try? ModelCatalog.bundledDirectory(),
              let data = try? Data(contentsOf: directory.deletingLastPathComponent().appendingPathComponent("model-discovery-references.json")),
              let value = try? JSONCoding.decode(data), value["version"] == 1,
              value["origin"] == "https://api.openai.com/v1" else { return nil }
        return value["models"]
    }()
    static func isOfficial(_ connection: ModelDiscovery.Connection) -> Bool {
        guard let url = URLComponents(string: connection.base) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.openai.com"
            && (url.port == nil || url.port == 443) && url.path == "/v1"
    }

    static func model(_ id: String, connection: ModelDiscovery.Connection, catalog: ModelCatalog?) -> JSON? {
        guard isOfficial(connection) else { return nil }
        var reference = "https://developers.openai.com/api/docs/models/" + id
        var source = "reference", checkedAt = ""
        var values: [String: JSON] = [:]
        var toolAPI: String?
        // Versioned data, with exact ids and primary sources, supplements the
        // pinned provider definitions without model-name rules in the detector.
        if let record = documented?[id], let fields = record["fields"]?.object,
           let url = record["reference"]?.string, url.hasPrefix("https://developers.openai.com/api/docs/models/"),
           let checked = record["checked_at"]?.string {
            values = fields; reference = url; checkedAt = checked
            toolAPI = record["tool_api_type"]?.string
        } else if let definition = catalog?.provider("langgenius/openai/openai")?.model(id, type: "llm") {
            source = "catalog"; checkedAt = "2026-10-13"
            reference = "https://github.com/langgenius/dify-official-plugins/blob/f2d7811364193f8d7069f24a299ee465c5519d3c/models/openai/models/llm/" + id + ".yaml"
            if let context = definition.modelProperties["context_size"]?.int, context > 0 { values["context_capacity"] = .int(context) }
            let features = definition.features ?? []
            for (field, names) in [("vision", ["vision"]), ("reasoning", ["agent-thought"]),
                ("tools", ["tool-call", "multi-tool-call"]), ("json_schema", ["structured-output"])] {
                // Absence in a vendor declaration is not a negative test result.
                if names.contains(where: features.contains) { values[field] = true }
            }
            if features.contains("stream-tool-call") { values["streaming"] = true }
            let rules = definition.parameterRules
            if let output = rules.first(where: { $0["name"] == "max_tokens" })?["max"]?.int, output > 0 {
                values["output_capacity"] = .int(output)
            }
            if let levels = ModelDiscovery.strings(rules.first(where: { $0["name"] == "reasoning_effort" })?["options"]), !levels.isEmpty {
                values["reasoning_levels"] = .array(levels.map(JSON.string))
            }
        } else { return nil }
        var fields: [String: JSON] = [:]
        for (name, value) in values {
            fields[name] = ["value": value, "source": .string(source), "reference": .string(reference), "checked_at": .string(checkedAt)]
        }
        var result: [String: JSON] = ["fields": .object(fields), "reference": .string(reference), "checked_at": .string(checkedAt)]
        if let toolAPI { result["tool_api_type"] = .string(toolAPI) }
        return .object(result)
    }

    static func enrich(_ model: JSON, connection: ModelDiscovery.Connection, catalog: ModelCatalog?) -> JSON {
        guard let id = model["id"]?.string, let reference = self.model(id, connection: connection, catalog: catalog) else { return model }
        var result = model.object ?? [:], fields = model["fields"]?.object ?? [:]
        for (name, value) in reference["fields"]?.object ?? [:] where fields[name]?["value"] == nil || fields[name]?["value"] == .null {
            fields[name] = value
        }
        result["fields"] = .object(fields)
        for key in ["reference", "checked_at", "tool_api_type"] { result[key] = reference[key] }
        return .object(result)
    }

    static func applicable(_ model: JSON, apiType: String?) -> JSON {
        guard let required = model["tool_api_type"]?.string, apiType != required else { return model }
        var result = model.object ?? [:], fields = model["fields"]?.object ?? [:]
        if fields["tools"]?["source"] == "reference" { fields["tools"] = ModelDiscovery.field(nil) }
        result["fields"] = .object(fields)
        return .object(result)
    }

    static func probeEffort(_ model: JSON?) -> String? {
        let levels = model?["fields"]?["reasoning_levels"]?["value"]?.array?.compactMap(\.string) ?? []
        return levels.contains("none") ? "none" : levels.contains("low") ? "low" : nil
    }
}
