import Foundation

/// Workflow-owned overrides of the inline agent's fixed model selection. References use the same marker as tasks.
/// Provider and credential configuration remain workspace-owned; variables never supply credentials or endpoints.
public struct AgentModelInputs: Sendable {
    public let values: JSONObject
    public init(_ value: JSONValue?) throws {
        guard let value, value != .null else { values = [:]; return }
        guard let object = value.object, Set(object.keys).isSubset(of: ["selection", "model", "reasoning_effort"]) else {
            throw NodeDataError("agent_model must contain only selection, model and reasoning_effort")
        }
        guard object["selection"] == nil || object["model"] == nil else {
            throw NodeDataError("Agent selection and legacy model inputs are mutually exclusive")
        }
        for (_, value) in object {
            guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 255 else { throw NodeDataError("Agent model inputs must be nonempty text") }
            guard Self.selector(text) != nil else { throw NodeDataError("Agent model inputs require a single variable reference") }
        }
        values = object
    }

    public static func selector(_ text: String) -> [String]? {
        guard text.hasPrefix("{{#"), text.hasSuffix("#}}") else { return nil }
        let inner = String(text.dropFirst(3).dropLast(3))
        guard !inner.contains("#"), !inner.contains("{"), !inner.contains("}") else { return nil }
        let parts = inner.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }) else { return nil }
        return parts
    }

    public var selectors: [[String]] { ["selection", "model", "reasoning_effort"].compactMap { values[$0]?.string.flatMap(Self.selector) } }

    public var selectsProvider: Bool { values["selection"] != nil }

    public func resolve(_ config: AgentInlineConfig, pool: VariablePool, pinned: JSONObject? = nil) throws -> AgentInlineConfig {
        var soul = config.json
        if let pinned {
            soul["model"] = .object(pinned)
            return try AgentInlineConfig(soul, requireModel: true)
        }
        var selection = soul["model"]?.object ?? [:]
        func input(_ key: String, limit: Int = 255) throws -> String? {
            guard let text = values[key]?.string, let selector = Self.selector(text) else { return nil }
            guard let segment = pool.get(selector), segment.valueType == .string, let result = segment.value.string,
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.utf8.count <= limit else {
                throw NodeError("AgentModelInputInvalid", "Agent \(key) requires a nonempty string variable")
            }
            return result
        }
        if let full = try input("selection", limit: 512) {
            guard let divider = full.range(of: "::") else {
                throw NodeError("AgentModelInputInvalid", "Agent selection must be provider::model")
            }
            let provider = String(full[..<divider.lowerBound]), model = String(full[divider.upperBound...])
            let parts = provider.split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
            guard parts.count == 3, provider.utf8.count <= 255,
                  parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }),
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 255 else {
                throw NodeError("AgentModelInputInvalid", "Agent selection requires a complete provider identifier and model name")
            }
            let providerChanged = provider != config.provider
            let modelChanged = selection["model"] != .string(model)
            if providerChanged || modelChanged {
                // A different model must not inherit another model's tuning parameters.
                selection["model_settings"] = .object([:])
                if providerChanged || ["model", "model_credential"].contains(selection["credential_ref"]?["type"]?.string ?? "") {
                    selection["credential_ref"] = nil
                }
            }
            selection["plugin_id"] = .string(parts.prefix(2).joined(separator: "/"))
            selection["model_provider"] = .string(String(parts[2]))
            selection["model"] = .string(model)
        } else if let model = try input("model") {
            // Preserve legacy model-name bindings and their parameter semantics.
            if selection["model"] != .string(model),
               ["model", "model_credential"].contains(selection["credential_ref"]?["type"]?.string ?? "") {
                selection["credential_ref"] = nil
            }
            selection["model"] = .string(model)
        }
        if let effort = try input("reasoning_effort") {
            var settings = selection["model_settings"]?.object ?? [:]
            settings["reasoning_effort"] = .string(effort)
            selection["model_settings"] = .object(settings)
        }
        soul["model"] = .object(selection)
        return try AgentInlineConfig(soul, requireModel: true)
    }
}
