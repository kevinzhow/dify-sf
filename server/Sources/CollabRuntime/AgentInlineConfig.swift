// Inline subset of Dify 1.17.1 AgentSoulConfig. Persist its product shape; reject unsupported active sections.
import Foundation

public struct AgentInlineConfig: Sendable {
    public var json: JSONObject
    public var systemPrompt: String
    public var provider: String?
    public var model: String?
    public var modelParameters: JSONObject
    public var contacts: [JSONObject]
    public var files: [JSONObject]
    public var environment: [JSONObject]
    public var secretReferences: [JSONObject]
    /// The immutable Soul pins a name; the executor host owns its definition.
    public var executorProfile: String
    public var askHuman: Bool { !contacts.isEmpty }

    public init(_ value: JSONObject, requireModel: Bool = false) throws {
        let allowed: Set<String> = ["schema_version", "prompt", "tools", "knowledge", "human", "env", "config_skills",
            "config_files", "config_note", "sandbox", "memory", "model", "app_features", "app_variables", "misc_legacy", "executor_profile"]
        guard Set(value.keys).isSubset(of: allowed) else { throw NodeDataError("Unknown agent config field") }
        if let profile = value["executor_profile"] {
            guard let name = profile.string, name.isEmpty || Self.validExecutorProfile(name) else {
                throw NodeDataError("Invalid agent executor profile name")
            }
            executorProfile = name.isEmpty ? "default" : name
        } else { executorProfile = "default" }
        if let version = value["schema_version"], version != 1 { throw NodeDataError("Unsupported agent config version") }
        for name in ["prompt", "tools", "knowledge", "human", "env", "sandbox", "memory", "app_features", "misc_legacy", "model"] {
            if let section = value[name], section != .null, section.object == nil {
                throw NodeDataError("Agent config \(name) must be an object")
            }
        }
        let sectionKeys: [String: Set<String>] = [
            "prompt": ["system_prompt"], "tools": ["dify_tools", "cli_tools"], "knowledge": ["sets"],
            "human": ["contacts", "tools"], "env": ["variables", "secret_refs"],
            "memory": ["scope", "budget", "artifacts"], "sandbox": ["provider", "config"]]
        for (name, keys) in sectionKeys {
            if let section = value[name]?.object, !Set(section.keys).isSubset(of: keys) {
                throw NodeDataError("Unknown agent config field in \(name)")
            }
        }
        for name in ["app_features", "misc_legacy"] {
            if let section = value[name], !Self.inactive(section) { throw NodeDataError("Agent app features are not supported") }
        }
        if let note = value["config_note"], note.string == nil { throw NodeDataError("config_note must be text") }
        for section in ["config_skills", "app_variables"] {
            try Self.requireInactiveArray(value[section], name: section)
        }
        for key in ["dify_tools", "cli_tools"] {
            try Self.requireInactiveArray(value["tools"]?[key], name: "tools." + key)
        }
        try Self.requireInactiveArray(value["knowledge"]?["sets"], name: "knowledge.sets")
        try Self.requireInactiveArray(value["human"]?["tools"], name: "human.tools")
        try Self.requireInactiveArray(value["memory"]?["artifacts"], name: "memory.artifacts")
        for name in ["scope", "budget"] {
            if let active = value["memory"]?[name], active != .null, active != "" {
                throw NodeDataError("Agent persistent memory is not supported")
            }
        }
        if let prompt = value["prompt"]?["system_prompt"], prompt.string == nil {
            throw NodeDataError("Agent system_prompt must be text")
        }
        systemPrompt = value["prompt"]?["system_prompt"]?.string ?? ""
        guard systemPrompt.utf8.count <= 256 << 10 else { throw NodeDataError("Agent prompt is too large") }
        let selection = value["model"]?.object
        if let selection {
            for key in ["plugin_id", "model_provider", "model"] {
                guard let name = selection[key]?.string, !name.isEmpty, name.utf8.count <= 255 else {
                    throw NodeDataError("Agent model selection is incomplete")
                }
            }
            let keys: Set<String> = ["plugin_id", "model_provider", "model", "credential_ref", "model_settings"]
            guard Set(selection.keys).isSubset(of: keys) else { throw NodeDataError("Unknown agent model field") }
            if let ref = selection["credential_ref"], ref != .null {
                guard let object = ref.object, Set(object.keys).isSubset(of: ["type", "id", "provider"]),
                      object["type"]?.string?.isEmpty == false else { throw NodeDataError("Invalid model credential reference") }
            }
        }
        // The execution supervisor chooses the fixed image and resource limits. A Soul cannot override that boundary.
        if let sandbox = value["sandbox"]?.object {
            if let provider = sandbox["provider"], provider != .null, provider != "", provider != "local" {
                throw NodeDataError("This sandbox provider is not supported")
            }
            if let config = sandbox["config"], config != .null {
                guard let object = config.object else { throw NodeDataError("Invalid sandbox config") }
                for (key, entry) in object {
                    if entry != .null && entry != "" && entry != .array([]) {
                        throw NodeDataError("Agent sandbox override \(key) is not supported")
                    }
                }
            }
        }
        model = selection?["model"]?.string
        if let plugin = selection?["plugin_id"]?.string, let name = selection?["model_provider"]?.string {
            // Product config stores org/plugin separately from the provider name.
            provider = name.hasPrefix(plugin + "/") ? name : "\(plugin)/\(name)"
        } else { provider = nil }
        if requireModel && (model?.isEmpty != false || provider?.isEmpty != false) {
            throw NodeDataError("An agent model is required")
        }
        if let settings = selection?["model_settings"], settings.object == nil {
            throw NodeDataError("Agent model_settings must be an object")
        }
        modelParameters = selection?["model_settings"]?.object ?? [:]
        contacts = try Self.objects(value["human"]?["contacts"], name: "human.contacts")
        for contact in contacts {
            let channel = contact["channel"]?.string ?? contact["method"]?.string ?? contact["contact_method"]?.string ?? "web_app"
            guard ["web_app", "webapp", "chat", "email"].contains(channel) else {
                throw NodeDataError("Agent contact channel \(channel) is not supported")
            }
            if channel == "email", contact["email"]?.string?.contains("@") != true {
                throw NodeDataError("An email contact needs an email address")
            }
        }
        files = try Self.objects(value["config_files"], name: "config_files")
        var names = Set<String>()
        for file in files {
            guard Set(file.keys).isSubset(of: ["name", "file_kind", "file_id", "is_missing", "size", "hash", "mime_type"]),
                  let name = file["name"]?.string, Self.validFileName(name), names.insert(name).inserted,
                  ["upload_file", "tool_file"].contains(file["file_kind"]?.string ?? "") else {
                throw NodeDataError("Invalid or duplicate agent config file")
            }
            if requireModel && (file["is_missing"] == true || file["file_id"]?.string?.isEmpty != false) {
                throw NodeDataError("An agent config file is missing")
            }
        }
        environment = try Self.objects(value["env"]?["variables"], name: "env.variables")
        secretReferences = try Self.objects(value["env"]?["secret_refs"], name: "env.secret_refs")
        var keys = Set<String>()
        for variable in environment where variable["type"] == "secret" {
            throw NodeDataError("Secret environment values must use secret_refs")
        }
        for variable in environment + secretReferences {
            let key = Self.environmentName(variable)
            guard !key.isEmpty, key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  !Self.reservedEnvironment(key), keys.insert(key).inserted else {
                throw NodeDataError("Invalid, reserved or duplicate agent environment name")
            }
        }
        var normalized = value
        normalized["schema_version"] = 1
        normalized["prompt"] = ["system_prompt": .string(systemPrompt)]
        normalized["config_files"] = .array(files.map(JSONValue.object))
        normalized["human"] = (value["human"]?.object).map(JSONValue.object) ?? ["contacts": [], "tools": []]
        normalized["env"] = ["variables": .array(environment.map(JSONValue.object)), "secret_refs": .array(secretReferences.map(JSONValue.object))]
        json = normalized
    }

    public static var empty: JSONObject {
        ["schema_version": 1, "prompt": ["system_prompt": ""], "model": .null, "config_files": [],
         "human": ["contacts": [], "tools": []], "env": ["variables": [], "secret_refs": []],
         "tools": ["dify_tools": [], "cli_tools": []], "knowledge": ["sets": []], "config_skills": []]
    }

    public static func environmentName(_ value: JSONObject) -> String {
        for key in ["name", "key", "env_name", "variable"] {
            if let name = value[key]?.string, !name.isEmpty { return name }
        }
        return ""
    }

    public static func validExecutorProfile(_ name: String) -> Bool {
        name.utf8.count <= 64 && name.range(of: #"^[a-z0-9][a-z0-9-]*\z"#, options: .regularExpression) != nil
    }

    public static func reservedEnvironment(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["HOME", "PATH", "TMPDIR", "TMP", "TEMP", "NO_PROXY"].contains(upper)
            || upper.hasPrefix("SHELLCTL_") || upper.hasSuffix("_PROXY")
    }

    static func inactive(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool(false), .string(""), .int(0): return true
        case .array(let values): return values.isEmpty
        case .object(let object): return object.values.allSatisfy(inactive)
        default: return false
        }
    }

    static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && ![".", ".."].contains(name)
            && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { $0.value < 32 }
    }

    static func requireInactiveArray(_ value: JSONValue?, name: String) throws {
        guard let value, value != .null else { return }
        guard let array = value.array, array.isEmpty else {
            throw NodeDataError("Agent config \(name) is not supported")
        }
    }

    static func objects(_ value: JSONValue?, name: String) throws -> [JSONObject] {
        guard let value, value != .null else { return [] }
        guard let values = value.array, values.count <= 128 else { throw NodeDataError("Invalid agent \(name)") }
        return try values.map {
            guard let object = $0.object else { throw NodeDataError("Invalid agent \(name)") }
            return object
        }
    }
}

/// Dify's UI filter is name/label based, not a capability certificate.
public enum AgentModelCompatibility {
    public static func isCompatible(label: String) -> Bool {
        !AgentModelPatterns.excluded.contains { label.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

}
