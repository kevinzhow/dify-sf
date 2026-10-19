/// Credential handling that Dify does around storage: the form-schema check and filter, the `[__HIDDEN__]` round trip and
/// the mask on read.
public enum Credentials {
    /// What the web form sends for a secret the user did not touch (Dify's `HIDDEN_VALUE`).
    public static let hidden = "[__HIDDEN__]"

    public struct SchemaError: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// graphon's `CommonValidator._validate_and_filter_credential_form_schemas`: only fields whose `show_on` conditions hold
    /// (all of them) are kept; an empty value takes the field's default, or is an error if the field is required; values
    /// must be strings; select/radio values must be options; switches become booleans. Everything else is dropped.
    /// `modelType` (custom models) is offered to `show_on` as `__model_type`, as Dify's `ModelCredentialSchemaValidator`.
    public static func validateAndFilter(_ schemas: [JSON], _ input: [String: JSON], modelType: String? = nil) throws -> [String: JSON] {
        var credentials = input
        if let modelType { credentials["__model_type"] = .string(modelType) }
        var out: [String: JSON] = [:]
        for f in schemas {
            guard let variable = f["variable"]?.string else { continue }
            let showOn = f["show_on"]?.array ?? []
            let shown = showOn.allSatisfy { s in
                guard let v = s["variable"]?.string, let value = credentials[v] else { return false }
                return value == s["value"]
            }
            guard shown else { continue }
            guard let value = credentials[variable], value.isTruthy else {
                if f["required"]?.bool ?? true { throw SchemaError(description: "Variable \(variable) is required") }
                if let d = f["default"]?.string, !d.isEmpty { out[variable] = .string(d) }
                continue
            }
            guard case .string(let s) = value else { throw SchemaError(description: "Variable \(variable) should be string") }
            if let max = f["max_length"]?.int, max > 0, s.unicodeScalars.count > max {
                throw SchemaError(description: "Variable \(variable) length should not be greater than \(max)")
            }
            let type = f["type"]?.string ?? ""
            if type == "select" || type == "radio", let options = f["options"]?.array, !options.isEmpty,
               !options.contains(where: { $0["value"]?.string == s }) {
                throw SchemaError(description: "Variable \(variable) is not in options")
            }
            if type == "switch" {
                guard ["true", "false"].contains(s.lowercased()) else { throw SchemaError(description: "Variable \(variable) should be true or false") }
                out[variable] = .bool(s.lowercased() == "true")
                continue
            }
            out[variable] = .string(s)
        }
        return out
    }

    /// Dify's update path (`validate_provider_credentials(..., credential_id)`): a secret sent as `[__HIDDEN__]` takes the
    /// stored value, when there is one.
    public static func restoringHidden(_ input: [String: JSON], stored: [String: JSON]?, secrets: Set<String>) -> [String: JSON] {
        guard let stored else { return input }
        var out = input
        for (k, v) in input where secrets.contains(k) && v == .string(hidden) {
            if let s = stored[k] { out[k] = s }
        }
        return out
    }

    /// Dify's `obfuscated_token`: the first 6 characters, twelve `*` and the last 2; twenty `*` for 8 characters or fewer
    /// (Python characters: Unicode scalars). Empty stays empty.
    public static func mask(_ token: String) -> String {
        let u = Array(token.unicodeScalars)
        if u.isEmpty { return token }
        guard u.count > 8 else { return String(repeating: "*", count: 20) }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: u[0..<6])
        return String(s) + String(repeating: "*", count: 12) + String(String.UnicodeScalarView(u[(u.count - 2)...]))
    }

    /// The credentials as Dify serves them: secret fields masked (non-string secrets as they are).
    public static func masked(_ c: [String: JSON], secrets: Set<String>) -> [String: JSON] {
        var out = c
        for (k, v) in c where secrets.contains(k) {
            if case .string(let s) = v { out[k] = .string(mask(s)) }
        }
        return out
    }
}
