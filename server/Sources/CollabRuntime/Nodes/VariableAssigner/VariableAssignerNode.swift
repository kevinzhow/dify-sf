// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/variable_assigner/v1
// (node.py, node_data.py), v2 (node.py, entities.py, enums.py, helpers.py, exc.py), common (helpers.py, exc.py),
// graphon/variables/types.py (SegmentType.get_zero_value); Dify 1.17.1's node class choice by `version`
// (api/core/workflow/node_factory.py resolve_workflow_node_class). See ../../NOTICE.md.
//
// Not ported: file variables (no files before P5).

import Foundation

/// `VariableOperatorNodeError` and its subclasses (v2 turns them into a failed result).
struct VariableOperatorError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Shared helpers of both assigner versions (`common/helpers.py`, `SegmentType.get_zero_value`).
enum VariableAssignerCommon {
    /// `UpdatedVariable` (`{name, selector, value_type, new_value}`) of a written variable.
    static func updatedVariable(_ selector: [String], _ segment: Segment) throws -> JSONValue {
        guard selector.count >= VariablePool.selectorsLength else { throw VariableOperatorError("selector too short") }
        return ["name": .string(selector[1]), "selector": .array(selector.prefix(2).map(JSONValue.string)),
                "value_type": .string(segment.valueType.rawValue), "new_value": segment.value]
    }

    /// `SegmentType.get_zero_value(t).to_object()`.
    static func zeroValue(_ t: SegmentType) throws -> JSONValue {
        switch t {
        case .arrayObject, .arrayAny, .arrayString, .arrayNumber, .arrayBoolean: return .array([])
        case .object: return .object([:])
        case .string: return .string("")
        case .integer, .number: return .int(0)
        case .float: return .double(0)
        case .boolean: return .bool(false)
        default: throw NodeError("ValueError", "unsupported variable type: \(t.rawValue)")
        }
    }

    /// The variable stored at exactly `selector` (`get_variable`): a two-part selector of an existing value.
    static func variable(_ pool: VariablePool, _ selector: [String]) -> Segment? {
        selector.count == VariablePool.selectorsLength ? pool.get(selector) : nil
    }

    /// `repr(list)` of a selector (graphon puts the Python list into messages).
    static func repr(_ selector: [String]) -> String { PythonText.repr(.array(selector.map(JSONValue.string))) }
}

// MARK: - v1

/// The variable assigner, version 1 (`assigned_variable_selector`, `write_mode`, `input_variable_selector`).
public struct VariableAssignerV1Node: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let assignedSelector: [String]
    /// `over-write`, `append` or `clear`.
    public let writeMode: String
    public let inputSelector: [String]

    public var nodeType: String { NodeType.variableAssigner }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let assigned = data["assigned_variable_selector"]?.array else { throw NodeDataError("assigned_variable_selector: Field required") }
        assignedSelector = assigned.map { PythonText.str($0) }
        guard let mode = data["write_mode"]?.string, ["over-write", "append", "clear"].contains(mode) else {
            throw NodeDataError("write_mode: Input should be 'over-write', 'append' or 'clear'")
        }
        writeMode = mode
        guard let input = data["input_variable_selector"]?.array else { throw NodeDataError("input_variable_selector: Field required") }
        inputSelector = input.map { PythonText.str($0) }
    }

    public func blocksVariableOutput(_ selectors: Set<[String]>) -> Bool { selectors.contains(assignedSelector) }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        let pool = context.pool
        guard let original = VariableAssignerCommon.variable(pool, assignedSelector) else {
            throw NodeError("VariableOperatorNodeError", "assigned variable not found")
        }
        let income: Segment
        let updated: Segment
        switch writeMode {
        case "over-write":
            guard let v = pool.get(inputSelector) else { throw NodeError("VariableOperatorNodeError", "input value not found") }
            income = v
            updated = Segment(original.valueType, v.value)
        case "append":
            guard let v = pool.get(inputSelector) else { throw NodeError("VariableOperatorNodeError", "input value not found") }
            income = v
            guard original.valueType.isArray, case .array(let items) = original.value else {
                throw NodeError("VariableOperatorNodeError", "append mode requires an array variable")
            }
            updated = Segment(original.valueType, .array(items + [v.value]))
        default:
            let zero = try VariableAssignerCommon.zeroValue(original.valueType)
            income = Segment(original.valueType, zero)
            updated = Segment(original.valueType, zero)
        }
        let processed = try VariableAssignerCommon.updatedVariable(assignedSelector, updated)
        await emit(.variableUpdated(selector: Array(assignedSelector.prefix(2)), value: updated))
        await emit(.completed(NodeRunResult(status: .succeeded, inputs: ["value": income.value],
                                            processData: ["__updated_variables": .array([processed])], outputs: [:])))
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var out: [(String, [String])] = []
        for sel in [assignedSelector, inputSelector] {
            let key = "\(id).#\(sel.joined(separator: "."))#"
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1 = sel } else { out.append((key, sel)) }
        }
        return out
    }
}

// MARK: - v2

/// The variable assigner, version 2: a list of operations (`items`), each on one variable.
public struct VariableAssignerV2Node: RuntimeNode {
    /// `VariableOperationItem`.
    public struct Item: Sendable {
        public var variableSelector: [String]
        /// `variable` or `constant`.
        public var inputType: String
        public var operation: String
        /// A constant, or the source selector for `variable` input.
        public var value: JSONValue

        var json: JSONValue {
            ["variable_selector": .array(variableSelector.map(JSONValue.string)), "input_type": .string(inputType),
             "operation": .string(operation), "value": value]
        }
    }

    public static let operations: Set<String> = ["over-write", "clear", "append", "extend", "set", "+=", "-=", "*=", "/=", "remove-first",
                                                 "remove-last"]

    public let id: String
    public let base: BaseNodeData
    public let items: [Item]
    /// `node_data.model_dump()`: the node's inputs.
    let dump: JSONObject

    public var nodeType: String { NodeType.variableAssigner }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        items = try (data["items"]?.array ?? []).map { j in
            guard let sel = j["variable_selector"]?.array else { throw NodeDataError("items.variable_selector: Field required") }
            guard let input = j["input_type"]?.string, input == "variable" || input == "constant" else {
                throw NodeDataError("items.input_type: Input should be 'variable' or 'constant'")
            }
            guard let op = j["operation"]?.string, Self.operations.contains(op) else {
                throw NodeDataError("items.operation: Input should be a supported operation")
            }
            return Item(variableSelector: sel.map { PythonText.str($0) }, inputType: input, operation: op, value: j["value"] ?? .null)
        }
        // pydantic's model_dump: the declared fields, then the extra keys as given.
        var d = JSONObject()
        d["type"] = .string(base.type)
        d["title"] = .string(base.title)
        d["desc"] = base.desc.map(JSONValue.string) ?? .null
        d["version"] = .string(base.version)
        d["error_strategy"] = base.errorStrategy.map { .string($0.rawValue) } ?? .null
        d["default_value"] = base.defaultValue.map { .array($0.map { ["value": $0.value, "type": .string($0.type), "key": .string($0.key)] }) } ?? .null
        d["retry_config"] = ["max_retries": .int(base.retryConfig.maxRetries), "retry_interval": .int(base.retryConfig.retryInterval),
                             "retry_enabled": .bool(base.retryConfig.retryEnabled)]
        d["items"] = .array(items.map(\.json))
        for (k, v) in data where d[k] == nil { d[k] = v }
        dump = d
    }

    public func blocksVariableOutput(_ selectors: Set<[String]>) -> Bool { items.contains { selectors.contains($0.variableSelector) } }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var working = context.pool
        var updatedSelectors: [[String]] = []
        do {
            for item in items {
                if let sel = try apply(item, &working) { updatedSelectors.append(sel) }
            }
        } catch let e as VariableOperatorError {
            await emit(.completed(NodeRunResult(status: .failed, inputs: dump, processData: [:], error: e.description)))
            return
        }
        var seen = Set<[String]>()
        updatedSelectors = updatedSelectors.filter { seen.insert($0).inserted }
        var processData = JSONObject()
        var updated: [JSONValue] = []
        for sel in updatedSelectors {
            guard let v = VariableAssignerCommon.variable(working, sel) else {
                throw NodeError("VariableNotFoundError", "Variable \(VariableAssignerCommon.repr(sel)) not found")
            }
            processData[sel[1]] = v.value
            updated.append(try VariableAssignerCommon.updatedVariable(sel, v))
        }
        processData["__updated_variables"] = .array(updated)
        for sel in updatedSelectors {
            guard let v = VariableAssignerCommon.variable(working, sel) else {
                throw NodeError("VariableNotFoundError", "Variable \(VariableAssignerCommon.repr(sel)) not found")
            }
            await emit(.variableUpdated(selector: sel, value: v))
        }
        await emit(.completed(NodeRunResult(status: .succeeded, inputs: dump, processData: processData, outputs: [:])))
    }

    /// `_apply_item`: the selector written, nil when the update is skipped (a variable input that is None).
    func apply(_ item: Item, _ pool: inout VariablePool) throws -> [String]? {
        guard let variable = VariableAssignerCommon.variable(pool, item.variableSelector) else {
            throw VariableOperatorError("Variable \(VariableAssignerCommon.repr(item.variableSelector)) not found")
        }
        let t = variable.valueType
        let op = item.operation
        // _validate_item_support
        guard Self.isOperationSupported(t, op) else { throw VariableOperatorError("Operation \(op) is not supported for type \(t.rawValue)") }
        if item.inputType == "variable" {
            if ["set", "+=", "-=", "*=", "/="].contains(op) {
                throw VariableOperatorError("Input type variable is not supported for operation \(op)")
            }
        } else if !Self.isConstantInputSupported(t, op) {
            throw VariableOperatorError("Input type constant is not supported for operation \(op)")
        }
        // _resolve_item_input_value
        var input = item.value
        if item.inputType == "variable", !["clear", "remove-first", "remove-last"].contains(op), item.value != .null {
            let selector = (item.value.array ?? []).map { PythonText.str($0) }
            guard let source = pool.get(selector) else {
                throw VariableOperatorError("Variable \(PythonText.repr(item.value)) not found")
            }
            if source.valueType == .none { return nil }
            input = source.value
        }
        if op == "set", t == .object, case .string(let s) = input {
            guard let parsed = try? JSONValue.parse(s) else { throw VariableOperatorError("Invalid input value \(s)") }
            input = parsed
        }
        guard Self.isInputValid(t, op, input) else { throw VariableOperatorError("Invalid input value \(PythonText.str(input))") }
        let newValue = try Self.handle(variable, op, input)
        let selector = Array(item.variableSelector.prefix(2))
        try? pool.add(selector, Segment(t, newValue))
        return selector
    }

    static let numericTypes: Set<SegmentType> = [.number, .integer, .float]

    static func isOperationSupported(_ t: SegmentType, _ op: String) -> Bool {
        switch op {
        case "over-write", "clear": return true
        case "set": return [.object, .string, .number, .integer, .float, .boolean].contains(t)
        case "+=", "-=", "*=", "/=": return numericTypes.contains(t)
        default: return t.isArray  // append, extend, remove-first, remove-last
        }
    }

    static func isConstantInputSupported(_ t: SegmentType, _ op: String) -> Bool {
        switch t {
        case .string, .object, .boolean: return op == "over-write" || op == "set"
        case .number, .integer, .float: return ["over-write", "set", "+=", "-=", "*=", "/="].contains(op)
        default: return false
        }
    }

    /// Python's `isinstance` for the input kinds graphon accepts (`bool` is an `int`).
    enum Kind { case str, int, float, bool, dict }
    static func isInstance(_ v: JSONValue, _ kinds: Set<Kind>) -> Bool {
        switch v {
        case .string: return kinds.contains(.str)
        case .int: return kinds.contains(.int)
        case .double: return kinds.contains(.float)
        case .bool: return kinds.contains(.bool) || kinds.contains(.int)
        case .object: return kinds.contains(.dict)
        default: return false
        }
    }

    static func elementKinds(_ t: SegmentType) -> Set<Kind>? {
        switch t {
        case .arrayAny: return [.str, .float, .int, .dict]
        case .arrayString: return [.str]
        case .arrayNumber: return [.int, .float]
        case .arrayObject: return [.dict]
        case .arrayBoolean: return [.bool]
        default: return nil
        }
    }

    /// `helpers.is_input_value_valid`.
    static func isInputValid(_ t: SegmentType, _ op: String, _ value: JSONValue) -> Bool {
        if ["clear", "remove-first", "remove-last"].contains(op) { return true }
        if numericTypes.contains(t) {
            guard isInstance(value, [.int, .float]) else { return false }
            return !(op == "/=" && PythonValue.equal(value, .int(0)))
        }
        let scalar: [SegmentType: Kind] = [.string: .str, .boolean: .bool, .object: .dict]
        if let k = scalar[t], isInstance(value, [k]) { return true }
        if op == "append" { return elementKinds(t).map { isInstance(value, $0) } ?? false }
        if op == "extend" || op == "over-write" {
            guard let kinds = elementKinds(t), case .array(let items) = value else { return false }
            return items.allSatisfy { isInstance($0, kinds) }
        }
        return false
    }

    /// `_handle_item`.
    static func handle(_ variable: Segment, _ op: String, _ value: JSONValue) throws -> JSONValue {
        switch op {
        case "over-write", "set": return value
        case "clear": return try VariableAssignerCommon.zeroValue(variable.valueType)
        case "append": return .array((variable.value.array ?? []) + [value])
        case "extend", "+=":
            if case .array(let a) = variable.value, case .array(let b) = value { return .array(a + b) }
            return try arithmetic(variable.value, value, "+")
        case "-=": return try arithmetic(variable.value, value, "-")
        case "*=": return try arithmetic(variable.value, value, "*")
        case "/=": return try arithmetic(variable.value, value, "/")
        case "remove-first", "remove-last":
            guard case .array(let a) = variable.value, !a.isEmpty else { return variable.value }
            return .array(op == "remove-first" ? Array(a.dropFirst()) : Array(a.dropLast()))
        default: return value
        }
    }

    /// Python's `+ - * /` on numbers (`bool` counts as `int`; `/` is always true division).
    static func arithmetic(_ a: JSONValue, _ b: JSONValue, _ op: String) throws -> JSONValue {
        func asInt(_ v: JSONValue) -> Int? {
            switch v {
            case .int(let i): return i
            case .bool(let x): return x ? 1 : 0
            default: return nil
            }
        }
        if op != "/", let x = asInt(a), let y = asInt(b) {
            switch op {
            case "+": return .int(x &+ y)
            case "-": return .int(x &- y)
            default: return .int(x &* y)
            }
        }
        guard let x = a.double ?? asInt(a).map(Double.init), let y = b.double ?? asInt(b).map(Double.init) else {
            throw NodeError("TypeError", "unsupported operand type(s) for \(op): \(WorkflowBootstrap.pythonTypeName(a)) and \(WorkflowBootstrap.pythonTypeName(b))")
        }
        switch op {
        case "+": return .double(x + y)
        case "-": return .double(x - y)
        case "*": return .double(x * y)
        default:
            guard y != 0 else { throw NodeError("ZeroDivisionError", "division by zero") }
            return .double(x / y)
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var out: [(String, [String])] = []
        func put(_ sel: [String]) {
            let key = "\(id).#\(sel.joined(separator: "."))#"
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1 = sel } else { out.append((key, sel)) }
        }
        for item in items {
            put(item.variableSelector)
            if item.inputType == "variable", case .array(let sel) = item.value, sel.count >= VariablePool.selectorsLength {
                put(sel.map { PythonText.str($0) })
            }
        }
        return out
    }
}

extension BuiltinNodeFactory {
    /// Dify's class choice: version "1" is v1, "2" (and anything else: the latest) is v2.
    func makeVariableAssigner(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        if config.version == "1" { return try VariableAssignerV1Node(id: config.id, data: config.data) }
        return try VariableAssignerV2Node(id: config.id, data: config.data)
    }
}
