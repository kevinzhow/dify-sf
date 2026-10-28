import Foundation

/// Workflow-owned overrides of the inline agent's fixed model selection. References use the same marker as tasks.
/// Provider and credential configuration remain workspace-owned; variables never supply credentials or endpoints.
public struct AgentModelInputs: Sendable {
    public let values: JSONObject
    public init(_ value: JSONValue?) throws {
        guard let value, value != .null else { values = [:]; return }
        guard let object = value.object, Set(object.keys).isSubset(of: ["model", "reasoning_effort"]) else {
            throw NodeDataError("agent_model must contain only model and reasoning_effort")
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

    public var selectors: [[String]] { ["model", "reasoning_effort"].compactMap { values[$0]?.string.flatMap(Self.selector) } }

    public func resolve(_ config: AgentInlineConfig, pool: VariablePool, pinned: JSONObject? = nil) throws -> AgentInlineConfig {
        var soul = config.json
        if let pinned {
            soul["model"] = .object(pinned)
            return try AgentInlineConfig(soul, requireModel: true)
        }
        var selection = soul["model"]?.object ?? [:]
        for (key, value) in values {
            let text = value.string!
            let resolved: String
            if let selector = Self.selector(text) {
                guard let segment = pool.get(selector), segment.valueType == .string, let result = segment.value.string,
                      !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.utf8.count <= 255 else {
                    throw NodeError("AgentModelInputInvalid", "Agent \(key) requires a nonempty string variable")
                }
                resolved = result
            } else { resolved = text }
            if key == "model" {
                // Model-scoped credential IDs belong to the original model; resolve the selected model's own config.
                if selection["model"] != .string(resolved),
                   ["model", "model_credential"].contains(selection["credential_ref"]?["type"]?.string ?? "") {
                    selection["credential_ref"] = nil
                }
                selection["model"] = .string(resolved)
            } else {
                var settings = selection["model_settings"]?.object ?? [:]
                settings[key] = .string(resolved)
                selection["model_settings"] = .object(settings)
            }
        }
        soul["model"] = .object(selection)
        return try AgentInlineConfig(soul, requireModel: true)
    }
}
