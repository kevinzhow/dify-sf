// Dify 1.17.1 output_type_checker.py and output_failure_orchestrator.py.
// Pure field decisions; the Swift server owns retries and file ownership validation.
import Foundation

public struct AgentDeclaredOutput: Sendable {
    public enum Kind: String, Sendable { case string, number, boolean, object, array, file }
    public enum Failure: String, Sendable { case stop, defaultValue = "default_value", failBranch = "fail_branch" }
    public var name: String
    public var kind: Kind
    public var required: Bool
    public var itemKind: Kind?
    public var retries: Int
    public var retryIntervalMs: Int
    public var failure: Failure
    public var defaultValue: JSONValue?
    public var json: JSONObject

    public init(_ json: JSONObject) throws {
        try Self.validateDefinition(json, child: false, depth: 0)
        guard let name = json["name"]?.string,
              name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              !["text", "switch", "_session"].contains(name), name.utf8.count <= 255,
              let kind = json["type"]?.string.flatMap(Kind.init(rawValue:)) else {
            throw NodeDataError("agent_declared_outputs: Invalid declared output name or type")
        }
        for flag in ["required"] {
            if let value = json[flag], value.bool == nil { throw NodeDataError("agent_declared_outputs: Invalid boolean field") }
        }
        for key in ["check", "failure_strategy", "file", "array_item"] {
            if let value = json[key], value != .null, value.object == nil {
                throw NodeDataError("agent_declared_outputs: Invalid config object")
            }
        }
        if let item = json["array_item"]?["type"], item.string.flatMap(Kind.init(rawValue:)) == nil || item == "array" {
            throw NodeDataError("agent_declared_outputs: Invalid or nested array item type")
        }
        if let children = json["children"], children.array == nil {
            throw NodeDataError("agent_declared_outputs: Invalid object children")
        }
        self.name = name
        self.kind = kind
        required = json["required"]?.bool ?? true
        itemKind = kind == .array ? (json["array_item"]?["type"]?.string.flatMap(Kind.init(rawValue:)) ?? .object) : nil
        if let check = json["check"], check["enabled"] == true {
            throw NodeDataError("agent_declared_outputs: Model-checked outputs are not supported")
        }
        let strategy = json["failure_strategy"]
        guard let failure = Failure(rawValue: strategy?["on_failure"]?.string ?? "stop") else {
            throw NodeDataError("agent_declared_outputs: Invalid output failure strategy")
        }
        self.failure = failure
        if let retry = strategy?["retry"], retry.object == nil {
            throw NodeDataError("agent_declared_outputs: Invalid retry config")
        }
        for value in [strategy?["retry"]?["enabled"], json["check"]?["enabled"]].compactMap({ $0 }) {
            guard value.bool != nil else { throw NodeDataError("agent_declared_outputs: Invalid enabled flag") }
        }
        for value in [strategy?["retry"]?["max_retries"], strategy?["retry"]?["retry_interval_ms"]].compactMap({ $0 }) {
            guard case .int = value else { throw NodeDataError("agent_declared_outputs: Retry limits must be integers") }
        }
        if let action = strategy?["on_failure"], action.string == nil {
            throw NodeDataError("agent_declared_outputs: Invalid output failure action")
        }
        let enabled = strategy?["retry"]?["enabled"] == true
        retries = enabled ? (strategy?["retry"]?["max_retries"]?.int ?? 0) : 0
        retryIntervalMs = enabled ? (strategy?["retry"]?["retry_interval_ms"]?.int ?? 0) : 0
        guard (0...10).contains(retries), (0...60_000).contains(retryIntervalMs) else {
            throw NodeDataError("agent_declared_outputs: Invalid output retry limits")
        }
        defaultValue = strategy?["default_value"]
        if failure == .defaultValue && (defaultValue == nil || defaultValue == .null) {
            throw NodeDataError("agent_declared_outputs: The output default value is required")
        }
        self.json = json
    }

    static func validateDefinition(_ value: JSONObject, child: Bool, depth: Int) throws {
        let shapeKeys: Set<String> = ["name", "type", "description", "required", "file", "array_item", "children"]
        let allowed = child ? shapeKeys : shapeKeys.union(["id", "check", "failure_strategy"])
        guard depth < 32, Set(value.keys).isSubset(of: allowed),
              let kind = value["type"]?.string.flatMap(Kind.init(rawValue:)) else { throw NodeDataError("Invalid declared output shape") }
        if let name = value["name"], name.string?.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
            throw NodeDataError("Invalid output field name")
        }
        if let required = value["required"], required.bool == nil { throw NodeDataError("Invalid output required flag") }
        if let description = value["description"], description != .null, description.string == nil { throw NodeDataError("Invalid output description") }
        if let file = value["file"], file != .null {
            guard kind == .file, let metadata = file.object, Set(metadata.keys).isSubset(of: ["extensions", "mime_types"]) else {
                throw NodeDataError("Invalid output file metadata")
            }
            for key in ["extensions", "mime_types"] {
                if let list = metadata[key] {
                    guard let values = list.array, values.count <= 128,
                          values.allSatisfy({ $0.string?.isEmpty == false && ($0.string?.utf8.count ?? 0) <= 255 }) else {
                        throw NodeDataError("Invalid file output constraints")
                    }
                }
            }
        }
        if let children = value["children"], children != .null {
            guard let values = children.array, values.isEmpty || kind == .object else { throw NodeDataError("Children need an object output") }
            var names = Set<String>()
            for field in values {
                guard let definition = field.object, let name = definition["name"]?.string, names.insert(name).inserted else {
                    throw NodeDataError("Invalid or duplicate output child")
                }
                try validateDefinition(definition, child: true, depth: depth + 1)
            }
        }
        if let item = value["array_item"], item != .null {
            guard kind == .array, var spec = item.object, Set(spec.keys).isSubset(of: ["type", "description", "children"]), spec["type"] != "array" else {
                throw NodeDataError("Invalid array item definition")
            }
            spec["name"] = "item"
            try validateDefinition(spec, child: true, depth: depth + 1)
        }
        if let check = value["check"], check != .null {
            guard kind == .file, let object = check.object,
                  Set(object.keys).isSubset(of: ["enabled", "prompt", "benchmark_file_ref", "model_ref"]) else {
                throw NodeDataError("Only file outputs have content checks")
            }
        }
        if let strategy = value["failure_strategy"], strategy != .null {
            guard let object = strategy.object, Set(object.keys).isSubset(of: ["retry", "on_failure", "default_value"]) else {
                throw NodeDataError("Invalid output failure policy")
            }
            if let retry = object["retry"], retry != .null {
                guard let object = retry.object, Set(object.keys).isSubset(of: ["enabled", "max_retries", "retry_interval_ms"]) else {
                    throw NodeDataError("Invalid output retry policy")
                }
            }
        }
    }

    public static func parse(_ declarations: [JSONValue]) throws -> [AgentDeclaredOutput] {
        guard declarations.count <= 128 else { throw NodeDataError("Too many declared outputs") }
        let fields = try declarations.map { value in
            guard let object = value.object else {
                throw NodeDataError("agent_declared_outputs: An output must be an object")
            }
            return try AgentDeclaredOutput(object)
        }
        guard Set(fields.map(\.name)).count == fields.count else {
            throw NodeDataError("agent_declared_outputs: Output names must be unique")
        }
        return fields
    }
}

public struct AgentOutputCheck: Sendable {
    public enum Status: String, Sendable { case ready, notProduced = "not_produced", failed = "type_check_failed" }
    public var field: String
    public var status: Status
    public var value: JSONValue?
    public var reason: String?
    public var json: JSONValue {
        ["name": .string(field), "status": .string(status.rawValue), "value": value ?? .null,
         "reason": reason.map(JSONValue.string) ?? .null]
    }
}

public struct AgentOutputDecision: Sendable {
    public enum Action: String, Sendable { case succeeded, retry, failNode = "fail_node", failBranch = "fail_branch" }
    public var action: Action
    public var outputs: JSONObject
    public var checks: [AgentOutputCheck]
    public var nextAttempt: Int
    public var retryIntervalMs: Int
    public var feedback: [JSONValue] {
        checks.filter { $0.status == .failed }.map { ["field": .string($0.field), "error": .string($0.reason ?? "Invalid output")] }
    }
}

/// Validates and decides once. JSON-Schema feedback from the agent is informative; authoritative field checks live here.
public enum AgentOutputPolicy {
    public static func decide(fields: [AgentDeclaredOutput], candidate: JSONValue, attempt: Int,
                              fileValid: @Sendable (JSONValue) async -> Bool) async -> AgentOutputDecision {
        let payload = candidate.object
        var checks: [AgentOutputCheck] = []
        for field in fields {
            guard let payload else {
                checks.append(.init(field: field.name, status: .failed, value: candidate, reason: "Backend output is not a JSON object."))
                continue
            }
            guard let value = payload[field.name] else {
                checks.append(.init(field: field.name, status: field.required ? .failed : .notProduced, value: nil,
                                    reason: field.required ? "Required output \(field.name) is missing from backend payload." : nil))
                continue
            }
            let error = await reason(kind: field.kind, itemKind: field.itemKind, value: value, fileValid: fileValid)
            checks.append(.init(field: field.name, status: error == nil ? .ready : .failed, value: value, reason: error))
        }
        var outputs: JSONObject = ["text": .string(payload?["text"]?.string ?? candidate.string ?? "")]
        for check in checks where check.status == .ready {
            if let value = check.value { outputs[check.field] = value }
        }
        let failed = checks.filter { $0.status == .failed }
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
        let failedFields = failed.compactMap { byName[$0.field] }
        if failedFields.isEmpty {
            return .init(action: .succeeded, outputs: outputs, checks: checks, nextAttempt: attempt, retryIntervalMs: 0)
        }
        let budget = failedFields.map(\.retries).max() ?? 0
        if attempt < budget {
            return .init(action: .retry, outputs: outputs, checks: checks, nextAttempt: attempt + 1,
                         retryIntervalMs: failedFields.filter { attempt < $0.retries }.map(\.retryIntervalMs).max() ?? 0)
        }
        if failedFields.contains(where: { $0.failure == .failBranch }) {
            return .init(action: .failBranch, outputs: outputs, checks: checks, nextAttempt: attempt, retryIntervalMs: 0)
        }
        if failedFields.contains(where: { $0.failure == .stop }) {
            return .init(action: .failNode, outputs: outputs, checks: checks, nextAttempt: attempt, retryIntervalMs: 0)
        }
        for field in failedFields {
            guard let value = field.defaultValue,
                  await reason(kind: field.kind, itemKind: field.itemKind, value: value, fileValid: fileValid) == nil else {
                return .init(action: .failNode, outputs: outputs, checks: checks, nextAttempt: attempt, retryIntervalMs: 0)
            }
            outputs[field.name] = value
        }
        return .init(action: .succeeded, outputs: outputs, checks: checks, nextAttempt: attempt, retryIntervalMs: 0)
    }

    static func reason(kind: AgentDeclaredOutput.Kind, itemKind: AgentDeclaredOutput.Kind?, value: JSONValue,
                       fileValid: @Sendable (JSONValue) async -> Bool) async -> String? {
        switch (kind, value) {
        case (.string, .string), (.number, .int), (.boolean, .bool), (.object, .object): return nil
        case (.number, .double(let number)) where number.isFinite: return nil
        case (.array, .array(let values)):
            for (index, item) in values.enumerated() {
                if let error = await reason(kind: itemKind ?? .object, itemKind: nil, value: item, fileValid: fileValid) {
                    return "items[\(index)]: \(error)"
                }
            }
            return nil
        case (.file, .object): return await fileValid(value) ? nil : "The file is unavailable or belongs to another execution."
        default: return "Expected \(kind.rawValue), got \(valueType(value))."
        }
    }

    static func valueType(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int, .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
