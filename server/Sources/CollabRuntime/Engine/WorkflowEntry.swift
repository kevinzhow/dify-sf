// Ported from Dify 1.17.1 (https://github.com/langgenius/dify, Apache-2.0 with Dify's conditions):
// api/core/workflow/system_variables.py (build_system_variables, build_bootstrap_variables),
// api/core/workflow/variable_pool_initializer.py, api/factories/variable_factory.py (_build_variable_from_mapping),
// api/core/app/apps/base_app_generator.py (_prepare_user_inputs, _validate_inputs), api/core/app/apps/workflow/
// app_runner.py (the draft run's pool). See ../NOTICE.md.
//
// Not ported: `MAX_VARIABLE_SIZE` on
// environment and conversation variables (the editor already limits them).

import Foundation

/// What Dify puts into a run's variable pool before the engine starts.
public enum WorkflowBootstrap {
    public struct InvalidInput: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// `build_system_variables(...)`: the keys in Dify's order, nil values dropped, `files` defaulting to `[]`.
    public static func systemVariables(_ values: [(String, JSONValue?)]) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        var runId: JSONValue?
        for (k, v) in values {
            if k == "workflow_execution_id" { runId = v; continue }
            guard let v, v != .null else { continue }
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1 = v } else { out.append((k, v)) }
        }
        if let runId, runId != .null, !out.contains(where: { $0.0 == "workflow_run_id" }) { out.append(("workflow_run_id", runId)) }
        if !out.contains(where: { $0.0 == "files" }) { out.append(("files", .array([]))) }
        return out
    }

    /// `_build_variable_from_mapping`: an environment or conversation variable as a typed segment.
    public static func variable(_ mapping: JSONValue) throws -> (name: String, segment: Segment) {
        guard let name = mapping["name"]?.string, !name.isEmpty else { throw InvalidInput("missing name") }
        guard let valueType = mapping["value_type"]?.string else { throw InvalidInput("missing value type") }
        guard let value = mapping["value"], value != .null else { throw InvalidInput("missing value") }
        func typed(_ t: SegmentType) -> (String, Segment) { (name, Segment(t, value)) }
        switch (valueType, value) {
        case ("string", .string): return typed(.string)
        case ("secret", .string): return typed(.secret)
        case ("number", .int), ("integer", .int): return typed(.integer)
        case ("number", .double), ("float", .double): return typed(.float)
        case ("boolean", .bool): return typed(.boolean)
        case ("number", _): throw InvalidInput("invalid number value \(PythonText.str(value))")
        case ("object", .object): return typed(.object)
        case ("array[string]", .array): return typed(.arrayString)
        case ("array[number]", .array): return typed(.arrayNumber)
        case ("array[object]", .array): return typed(.arrayObject)
        case ("array[boolean]", .array): return typed(.arrayBoolean)
        default: throw InvalidInput("not supported value type \(valueType)")
        }
    }

    /// The pool of a run: system variables, environment variables, conversation variables, then the start node's inputs.
    public static func pool(system: [(String, JSONValue)], environment: [(name: String, segment: Segment)],
                            conversation: [(name: String, segment: Segment)], rootId: String, inputs: JSONObject) throws -> VariablePool {
        var pool = VariablePool()
        for (k, v) in system { try pool.add([VariablePool.systemNodeId, k], v) }
        for (k, v) in environment { try pool.add([VariablePool.environmentNodeId, k], v) }
        for (k, v) in conversation { try pool.add([VariablePool.conversationNodeId, k], v) }
        for (k, v) in inputs { try pool.add([rootId, k], v) }
        return pool
    }

    /// `_prepare_user_inputs` + `_validate_inputs`: one value per start variable (in the start node's order), defaults
    /// for missing optional ones, numbers parsed from text, checkboxes from words; NUL characters removed from text.
    public static func prepareUserInputs(_ inputs: JSONObject, variables: [VariableEntity]) throws -> JSONObject {
        var out = JSONObject()
        for v in variables {
            var value = inputs[v.variable] ?? .null
            if value == .null {
                if v.required { throw InvalidInput("\(v.variable) is required in input form") }
                value = v.defaultValue ?? .null
                if value == .null { out[v.variable] = .null; continue }
            }
            if (v.type == "file" || v.type == "file-list"), !v.required, value == .string("") {
                out[v.variable] = .null
                continue
            }
            if ["text-input", "select", "paragraph"].contains(v.type), value.string == nil {
                throw InvalidInput("(type '\(v.type)') \(v.variable) in input form must be a string")
            }
            switch v.type {
            case "number":
                switch value {
                case .int, .double: break
                case .string(let s):
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { value = .null; break }
                    if s.contains(".") {
                        guard let d = Double(t) else { throw InvalidInput("\(v.variable) in input form must be a valid number") }
                        value = .double(d)
                    } else {
                        guard let i = Int(t) else { throw InvalidInput("\(v.variable) in input form must be a valid number") }
                        value = .int(i)
                    }
                default:
                    throw InvalidInput("expected value type int, float or str, got \(pythonTypeName(value)), value: \(PythonText.str(value))")
                }
            case "select":
                if !v.options.contains(value.string ?? "") {
                    throw InvalidInput("\(v.variable) in input form must be one of the following: \(PythonText.repr(.array(v.options.map(JSONValue.string))))")
                }
            case "text-input", "paragraph":
                if let max = v.maxLength, max > 0, (value.string ?? "").count > max {
                    throw InvalidInput("\(v.variable) in input form must be less than \(max) characters")
                }
            case "file":
                guard RuntimeFile.isFile(value) else { throw InvalidInput("\(v.variable) in input form must be a file") }
            case "file-list":
                guard let items = value.array, items.allSatisfy(RuntimeFile.isFile) else { throw InvalidInput("\(v.variable) in input form must be a list of files") }
                if let limit = v.maxLength, limit > 0, items.count > limit { throw InvalidInput("\(v.variable) in input form must be less than \(limit) files") }
            case "checkbox":
                switch value {
                case .string(let s):
                    let n = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["true", "1", "yes", "on"].contains(n) { value = .bool(true) } else if ["false", "0", "no", "off"].contains(n) { value = .bool(false) }
                case .int(let i): if i == 1 { value = .bool(true) } else if i == 0 { value = .bool(false) }
                case .double(let d): if d == 1 { value = .bool(true) } else if d == 0 { value = .bool(false) }
                default: break
                }
            case "json_object":
                if value.isTruthy, value.object == nil { throw InvalidInput("\(v.variable) in input form must be a dict") }
            default:
                break
            }
            if case .string(let s) = value { value = .string(s.replacingOccurrences(of: "\u{0}", with: "")) }
            out[v.variable] = value
        }
        return out
    }

    static func pythonTypeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "<class 'NoneType'>"
        case .bool: return "<class 'bool'>"
        case .int: return "<class 'int'>"
        case .double: return "<class 'float'>"
        case .string: return "<class 'str'>"
        case .array: return "<class 'list'>"
        case .object: return "<class 'dict'>"
        }
    }
}
