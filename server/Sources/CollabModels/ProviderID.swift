/// A model provider id, `organization/plugin/provider` (Dify's `ModelProviderID`, `api/models/provider_ids.py`).
public struct ProviderID: Hashable, Sendable, CustomStringConvertible {
    public var organization: String
    public var plugin: String
    public var provider: String

    /// Accepts the long form, or a bare name (`openai` -> `langgenius/openai/openai`). As in Dify, `langgenius/*/google`
    /// is the `gemini` plugin's. Nil for anything else (segments are `[a-z0-9_-]+`).
    public init?(_ value: String) {
        func valid(_ s: Substring) -> Bool {
            !s.isEmpty && s.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45 }
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 3, parts.allSatisfy(valid) {
            (organization, plugin, provider) = (String(parts[0]), String(parts[1]), String(parts[2]))
        } else if parts.count == 1, valid(parts[0]) {
            (organization, plugin, provider) = ("langgenius", value, value)
        } else {
            return nil
        }
        if organization == "langgenius", provider == "google" { plugin = "gemini" }
    }

    public var description: String { "\(organization)/\(plugin)/\(provider)" }
    /// `organization/plugin` (Dify's `plugin_id`).
    public var pluginId: String { "\(organization)/\(plugin)" }
}
