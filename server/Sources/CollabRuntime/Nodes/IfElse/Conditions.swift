// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/utils/condition/processor.py,
// entities.py. See ../../NOTICE.md.
//
// Not ported: sub-conditions over file arrays (no files before P5; they fail with "Sub variable is required" or an
// unsupported-file error).

/// `SubCondition`.
public struct SubCondition: Sendable, Hashable {
    public var key: String
    public var comparisonOperator: String
    public var value: JSONValue

    var json: JSONValue { ["key": .string(key), "comparison_operator": .string(comparisonOperator), "value": value] }
}

/// `SubVariableCondition`.
public struct SubVariableCondition: Sendable, Hashable {
    public var logicalOperator: String
    public var conditions: [SubCondition]

    var json: JSONValue { ["logical_operator": .string(logicalOperator), "conditions": .array(conditions.map(\.json))] }
}

/// `Condition`: a variable compared with a value.
public struct Condition: Sendable, Hashable {
    public var variableSelector: [String]
    public var comparisonOperator: String
    /// `str | Sequence[str] | bool | None`.
    public var value: JSONValue
    public var subVariableCondition: SubVariableCondition?

    public static let operators: Set<String> = ["contains", "not contains", "start with", "end with", "is", "is not", "empty", "not empty",
                                                "in", "not in", "all of", "=", "≠", ">", "<", "≥", "≤", "null", "not null", "exists",
                                                "not exists"]

    /// pydantic's validation of a condition (values coerced as its lax mode does for `str | list[str] | bool | None`).
    public init(json j: JSONValue) throws {
        guard let sel = j["variable_selector"]?.array else { throw NodeDataError("conditions.variable_selector: Field required") }
        variableSelector = sel.map { PythonText.str($0) }
        guard let op = j["comparison_operator"]?.string, Self.operators.contains(op) else {
            throw NodeDataError("conditions.comparison_operator: Input should be one of the supported operators")
        }
        comparisonOperator = op
        value = Self.coerceValue(j["value"] ?? .null)
        if let s = j["sub_variable_condition"]?.object {
            subVariableCondition = SubVariableCondition(
                logicalOperator: s["logical_operator"]?.string ?? "and",
                conditions: (s["conditions"]?.array ?? []).compactMap { c in
                    guard let key = c["key"]?.string, let op = c["comparison_operator"]?.string else { return nil }
                    return SubCondition(key: key, comparisonOperator: op, value: Self.coerceValue(c["value"] ?? .null))
                })
        }
    }

    static func coerceValue(_ v: JSONValue) -> JSONValue {
        switch v {
        case .null, .string, .bool: return v
        case .int(let i) where i == 0 || i == 1: return .bool(i == 1)
        case .int, .double: return .string(PythonText.str(v))
        case .array(let a): return .array(a.map { $0.string != nil || $0.bool != nil ? $0 : .string(PythonText.str($0)) })
        case .object: return .string(PythonText.str(v))
        }
    }

    /// `model_dump()`.
    public var json: JSONValue {
        ["variable_selector": .array(variableSelector.map(JSONValue.string)), "comparison_operator": .string(comparisonOperator),
         "value": value, "sub_variable_condition": subVariableCondition?.json ?? .null]
    }
}

/// `ConditionProcessor`.
public enum ConditionProcessor {
    public struct Result: Sendable {
        public var inputs: [JSONValue]
        public var groupResults: [Bool]
        public var finalResult: Bool
    }

    /// A condition could not be evaluated (graphon's `ValueError` / `TypeError`, which fail the node).
    public struct EvaluationError: Error, CustomStringConvertible, Sendable {
        public var description: String
        init(_ d: String) { description = d }
    }

    static let unary: Set<String> = ["empty", "not empty", "null", "not null", "exists", "not exists"]

    /// `process_conditions`: short-circuits on the first decisive result.
    public static func process(pool: VariablePool, conditions: [Condition], logicalOperator: String) throws -> Result {
        var inputs: [JSONValue] = []
        var results: [Bool] = []
        for c in conditions {
            guard let variable = pool.get(c.variableSelector) else {
                throw EvaluationError("Variable \(PythonText.repr(.array(c.variableSelector.map(JSONValue.string)))) not found")
            }
            let result: Bool
            if variable.valueType == .arrayFile, ["contains", "not contains", "all of"].contains(c.comparisonOperator) {
                guard c.subVariableCondition != nil else { throw EvaluationError("Sub variable is required") }
                throw EvaluationError("File conditions are not supported by this runtime yet")
            } else if c.comparisonOperator == "exists" || c.comparisonOperator == "not exists" {
                result = try evaluate(c.comparisonOperator, value: variable.value, expected: .null)
            } else {
                let expected = try prepareExpected(variable, pool, c.value)
                inputs.append(["actual_value": variable.value, "expected_value": expected, "comparison_operator": .string(c.comparisonOperator)])
                result = try evaluate(c.comparisonOperator, value: variable.value, expected: expected)
            }
            results.append(result)
            if (logicalOperator == "and" && !result) || (logicalOperator == "or" && result) {
                return Result(inputs: inputs, groupResults: results, finalResult: result)
            }
        }
        let final = logicalOperator == "and" ? results.allSatisfy { $0 } : results.contains(true)
        return Result(inputs: inputs, groupResults: results, finalResult: final)
    }

    static func prepareExpected(_ variable: Segment, _ pool: VariablePool, _ expected: JSONValue) throws -> JSONValue {
        var v = expected
        if case .string(let s) = expected { v = .string(VariableTemplate.convert(pool, s).text) }
        if v == .null { return .null }
        if variable.valueType == .boolean || variable.valueType == .arrayBoolean {
            if case .array(let items) = v { return .array(try items.map { .bool(try convertToBool($0)) }) }
            return .bool(try convertToBool(v))
        }
        switch v {
        case .string, .bool: return v
        case .array(let a) where a.allSatisfy({ $0.string != nil }): return v
        case .array(let a) where a.allSatisfy({ $0.bool != nil }): return v
        default: throw EvaluationError("unexpected expected value: \(PythonText.repr(v))")
        }
    }

    static func convertToBool(_ v: JSONValue) throws -> Bool {
        switch v {
        case .int(let i): return i != 0
        case .bool(let b): return b
        case .string(let s):
            switch try? JSONValue.parse(s) {
            case .int(let i)?: return i != 0
            case .bool(let b)?: return b
            default: throw EvaluationError("unexpected value: type=<class 'str'>, value=\(s)")
            }
        default: throw EvaluationError("unexpected value: type=\(WorkflowBootstrap.pythonTypeName(v)), value=\(PythonText.str(v))")
        }
    }

    /// `_evaluate_condition`.
    public static func evaluate(_ op: String, value: JSONValue, expected: JSONValue) throws -> Bool {
        switch op {
        case "contains":
            if !value.isTruthy { return false }
            switch value {
            case .string(let s): return s.contains(PythonText.str(expected))
            case .array(let a): return a.contains { PythonValue.equal($0, expected) }
            default: throw EvaluationError("Invalid actual value type: string or array")
            }
        case "not contains":
            if !value.isTruthy { return true }
            switch value {
            case .string(let s): return !s.contains(PythonText.str(expected))
            case .array(let a): return !a.contains { PythonValue.equal($0, expected) }
            default: throw EvaluationError("Invalid actual value type: string or array")
            }
        case "start with", "end with":
            if !value.isTruthy { return false }
            guard case .string(let s) = value else { throw EvaluationError("Invalid actual value type: string") }
            guard case .string(let e) = expected else {
                throw EvaluationError("Expected value must be a string for \(op == "start with" ? "startswith" : "endswith")")
            }
            return op == "start with" ? s.hasPrefix(e) : s.hasSuffix(e)
        case "is", "is not":
            if value == .null { return false }
            switch value {
            case .string, .bool:
                let eq = PythonValue.equal(value, expected)
                return op == "is" ? eq : !eq
            default: throw EvaluationError("Invalid actual value type: string or boolean")
            }
        case "empty": return !value.isTruthy
        case "not empty": return value.isTruthy
        case "=", "≠":
            if value == .null { return false }
            let e = try normalizeEqualityExpected(value, expected)
            let eq = PythonValue.equal(value, e)
            return op == "=" ? eq : !eq
        case ">", "<", "≥", "≤":
            if value == .null { return false }
            guard let (a, b) = try normalizeNumeric(value, expected) else { throw EvaluationError("Invalid actual value type: number") }
            switch op {
            case ">": return a > b
            case "<": return a < b
            case "≥": return a >= b
            default: return a <= b
            }
        case "null", "not exists": return value == .null
        case "not null", "exists": return value != .null
        case "in", "not in":
            if !value.isTruthy { return op == "not in" }
            guard case .array(let a) = expected else { throw EvaluationError("Invalid expected value type: array") }
            let found = a.contains { PythonValue.equal(value, $0) }
            return op == "in" ? found : !found
        case "all of":
            guard case .array(let items) = expected, items.allSatisfy({ $0.string != nil }) || items.allSatisfy({ $0.bool != nil }) else {
                throw EvaluationError("all of operator expects homogeneous list of strings or booleans")
            }
            if !value.isTruthy { return false }
            switch value {
            case .array(let a): return items.allSatisfy { i in a.contains { PythonValue.equal($0, i) } }
            case .string(let s) where items.allSatisfy({ $0.string != nil }): return items.allSatisfy { s.contains($0.string!) }
            default: return false
            }
        default:
            throw EvaluationError("Unsupported operator: \(op)")
        }
    }

    /// `_normalize_numeric_equality_expected`.
    static func normalizeEqualityExpected(_ value: JSONValue, _ expected: JSONValue) throws -> JSONValue {
        switch value {
        case .bool:
            switch expected {
            case .bool, .int, .string: return .bool(expected.isTruthy)
            default: throw EvaluationError("Cannot convert \(WorkflowBootstrap.pythonTypeName(expected)) to bool")
            }
        case .int:
            switch expected {
            case .int(let i): return .int(i)
            case .bool(let b): return .int(b ? 1 : 0)
            case .double(let d): return .int(Int(d.rounded(.towardZero)))
            case .string(let s):
                guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else {
                    throw EvaluationError("invalid literal for int() with base 10: \(PythonText.repr(expected))")
                }
                return .int(i)
            default: throw EvaluationError("Cannot convert \(WorkflowBootstrap.pythonTypeName(expected)) to int")
            }
        case .double:
            switch expected {
            case .int(let i): return .double(Double(i))
            case .bool(let b): return .double(b ? 1 : 0)
            case .double: return expected
            case .string(let s):
                guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else {
                    throw EvaluationError("could not convert string to float: \(PythonText.repr(expected))")
                }
                return .double(d)
            default: throw EvaluationError("Cannot convert \(WorkflowBootstrap.pythonTypeName(expected)) to float")
            }
        default:
            throw EvaluationError("Invalid actual value type: number or boolean")
        }
    }

    /// `_normalize_numeric_values` (as doubles: the comparison result is the same).
    static func normalizeNumeric(_ value: JSONValue, _ expected: JSONValue) throws -> (Double, Double)? {
        let a: Double
        switch value {
        case .int(let i): a = Double(i)
        case .double(let d): a = d
        case .bool(let b): a = b ? 1 : 0
        default: return nil
        }
        switch expected {
        case .string(let s):
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { throw EvaluationError("Cannot convert '\(s)' to number") }
            return (a, d)
        case .int(let i): return (a, Double(i))
        case .double(let d): return (a, d)
        case .bool(let b): return (a, b ? 1 : 0)
        default: throw EvaluationError("Cannot convert \(WorkflowBootstrap.pythonTypeName(expected)) to number")
        }
    }
}

/// Python's `==` between JSON-like values: numbers across int / float / bool, lists element-wise, dicts by key.
public enum PythonValue {
    public static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        func num(_ v: JSONValue) -> Double? {
            switch v {
            case .int(let i): return Double(i)
            case .double(let d): return d
            case .bool(let x): return x ? 1 : 0
            default: return nil
            }
        }
        if let x = num(a), let y = num(b) { return x == y }
        switch (a, b) {
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { equal(v, $0) } ?? false }
        default: return a == b
        }
    }
}
