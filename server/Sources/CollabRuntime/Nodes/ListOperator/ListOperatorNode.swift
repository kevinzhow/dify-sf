// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/list_operator/node.py,
// entities.py, exc.py. See ../../NOTICE.md.
//
// Not ported: file arrays (no files before P5: filters and orders by file attributes fail with a message saying so).

import Foundation

/// The list operator: filter, extract (one item), order and limit an array of strings, numbers or booleans; outputs
/// `result`, `first_record`, `last_record`.
public struct ListOperatorNode: RuntimeNode {
    /// `FilterCondition`.
    public struct FilterCondition: Sendable {
        public var key: String
        public var comparisonOperator: String
        /// `str | Sequence[str] | bool`.
        public var value: JSONValue
    }

    public static let filterOperators: Set<String> = ["contains", "start with", "end with", "is", "in", "empty", "not contains", "is not",
                                                      "not in", "not empty", "=", "≠", "<", ">", "≥", "≤"]

    public let id: String
    public let base: BaseNodeData
    public let variable: [String]
    public let filterEnabled: Bool
    public let conditions: [FilterCondition]
    public let orderEnabled: Bool
    public let orderKey: String
    /// `asc` or `desc`.
    public let order: String
    public let limitEnabled: Bool
    public let limitSize: Int
    public let extractEnabled: Bool
    public let extractSerial: String

    public var nodeType: String { NodeType.listOperator }

    /// `ListOperatorError` (caught: a failed result with the inputs).
    struct ListError: Error, CustomStringConvertible {
        var description: String
    }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        variable = (data["variable"]?.array ?? []).map { PythonText.str($0) }
        guard let filter = data["filter_by"]?.object else { throw NodeDataError("filter_by: Field required") }
        guard let orderBy = data["order_by"]?.object else { throw NodeDataError("order_by: Field required") }
        guard let limit = data["limit"]?.object else { throw NodeDataError("limit: Field required") }
        filterEnabled = filter["enabled"]?.bool ?? false
        conditions = try (filter["conditions"]?.array ?? []).map { c in
            let op = c["comparison_operator"]?.string ?? "contains"
            guard Self.filterOperators.contains(op) else { throw NodeDataError("filter_by.conditions.comparison_operator: invalid value '\(op)'") }
            let value: JSONValue
            switch c["value"] ?? .string("") {
            case .string(let s): value = .string(s)
            case .bool(let b): value = .bool(b)
            case .int(let i) where i == 0 || i == 1: value = .bool(i == 1)
            case .array(let a) where a.allSatisfy({ $0.string != nil }): value = .array(a)
            default: throw NodeDataError("filter_by.conditions.value: Input should be a valid string, list of strings or boolean")
            }
            return FilterCondition(key: c["key"]?.string ?? "", comparisonOperator: op, value: value)
        }
        orderEnabled = orderBy["enabled"]?.bool ?? false
        orderKey = orderBy["key"]?.string ?? ""
        let o = orderBy["value"]?.string ?? "asc"
        guard o == "asc" || o == "desc" else { throw NodeDataError("order_by.value: Input should be 'asc' or 'desc'") }
        order = o
        limitEnabled = limit["enabled"]?.bool ?? false
        limitSize = limit["size"]?.int ?? -1
        let extract = data["extract_by"]?.object ?? [:]
        extractEnabled = extract["enabled"]?.bool ?? false
        extractSerial = extract["serial"].map { $0.string ?? PythonText.str($0) } ?? "1"
    }

    static let supported: Set<SegmentType> = [.arrayFile, .arrayNumber, .arrayString, .arrayBoolean]

    /// Python's class of a pool value (`type(variable)` in graphon's message).
    func pythonClass(_ s: Segment) -> String {
        let names: [SegmentType: String] = [
            .string: "String", .secret: "Secret", .integer: "Integer", .float: "Float", .number: "Float", .object: "Object", .boolean: "Boolean",
            .none: "None", .file: "File", .arrayAny: "ArrayAny", .arrayString: "ArrayString", .arrayNumber: "ArrayNumber",
            .arrayObject: "ArrayObject", .arrayFile: "ArrayFile", .arrayBoolean: "ArrayBoolean",
        ]
        let name = names[s.valueType] ?? "Segment"
        return variable.count == VariablePool.selectorsLength
            ? "<class 'graphon.variables.variables.\(name)Variable'>" : "<class 'graphon.variables.segments.\(name)Segment'>"
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        let selectorText = PythonText.repr(.array(variable.map(JSONValue.string)))
        guard let segment = context.pool.get(variable) else {
            await emit(.completed(NodeRunResult(status: .failed, inputs: [:], outputs: [:], error: "Variable not found for selector: \(selectorText)")))
            return
        }
        if !segment.value.isTruthy {
            await emit(.completed(NodeRunResult(status: .succeeded, inputs: ["variable": []], processData: ["variable": []],
                                                outputs: Self.outputs([]))))
            return
        }
        guard Self.supported.contains(segment.valueType), case .array(let items) = segment.value else {
            await emit(.completed(NodeRunResult(status: .failed, inputs: [:], outputs: [:],
                                                error: "Variable \(selectorText) is not an array type, actual type: \(pythonClass(segment))")))
            return
        }
        let inputs: JSONObject = ["variable": segment.value]
        let processData: JSONObject = ["variable": segment.value]
        do {
            var values = items
            if filterEnabled { values = try applyFilter(values, segment.valueType, context.pool) }
            if extractEnabled { values = try extract(values, context.pool) }
            if orderEnabled { values = try applyOrder(values, segment.valueType) }
            if limitEnabled { values = Self.slice(values, to: limitSize) }
            var r = NodeRunResult(status: .succeeded, inputs: inputs, processData: processData, outputs: Self.outputs(values))
            r.outputTypes = ["result": segment.valueType]
            await emit(.completed(r))
        } catch let e as ListError {
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, processData: processData, outputs: [:], error: e.description)))
        }
    }

    static func outputs(_ values: [JSONValue]) -> JSONObject {
        ["result": .array(values), "first_record": values.first ?? .null, "last_record": values.last ?? .null]
    }

    /// Python's `value[:n]`.
    static func slice(_ a: [JSONValue], to n: Int) -> [JSONValue] {
        let end = n >= 0 ? min(n, a.count) : max(0, a.count + n)
        return Array(a[..<end])
    }

    func applyFilter(_ items: [JSONValue], _ type: SegmentType, _ pool: VariablePool) throws -> [JSONValue] {
        var values = items
        for c in conditions {
            switch type {
            case .arrayString:
                guard case .string(let raw) = c.value else { throw ListError(description: "Invalid filter value: \(PythonText.str(c.value))") }
                let v = VariableTemplate.convert(pool, raw).text
                let f = try Self.stringFilter(c.comparisonOperator, v)
                values = values.filter { f($0.string ?? PythonText.str($0)) }
            case .arrayNumber:
                guard case .string(let raw) = c.value else { throw ListError(description: "Invalid filter value: \(PythonText.str(c.value))") }
                let text = VariableTemplate.convert(pool, raw).text
                guard let v = Self.pythonFloat(text) else { throw NodeError("ValueError", "could not convert string to float: \(PythonText.repr(.string(text)))") }
                let f = try Self.numberFilter(c.comparisonOperator, v)
                values = values.filter { $0.double.map(f) ?? false }
            case .arrayFile:
                throw ListError(description: "File filters are not supported by this runtime yet")
            default:
                guard case .bool(let b) = c.value else {
                    throw NodeError("TypeError", "Boolean filter expects a boolean value, got \(WorkflowBootstrap.pythonTypeName(c.value))")
                }
                guard c.comparisonOperator == "is" || c.comparisonOperator == "is not" else {
                    throw ListError(description: "Invalid condition: \(c.comparisonOperator)")
                }
                let isOp = c.comparisonOperator == "is"
                values = values.filter { PythonValue.equal($0, .bool(b)) == isOp }
            }
        }
        return values
    }

    /// Python's `float(text)` (spaces allowed around; `inf`, `nan`).
    static func pythonFloat(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "")
        if t.isEmpty { return nil }
        return Double(t)
    }

    /// Python's `str` operations compare code points (no Unicode normalization, unlike Swift's `String`).
    enum CodePoints {
        static func of(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
        static func contains(_ s: [UInt32], _ sub: [UInt32]) -> Bool {
            if sub.isEmpty { return true }
            if sub.count > s.count { return false }
            for i in 0...(s.count - sub.count) where s[i] == sub[0] && Array(s[i..<(i + sub.count)]) == sub { return true }
            return false
        }
    }

    static func stringFilter(_ op: String, _ value: String) throws -> (String) -> Bool {
        let v = CodePoints.of(value)
        switch op {
        case "empty": return { $0.isEmpty }
        case "not empty": return { !$0.isEmpty }
        case "contains": return { CodePoints.contains(CodePoints.of($0), v) }
        case "start with": return { CodePoints.of($0).starts(with: v) }
        case "end with": return { CodePoints.of($0).reversed().starts(with: v.reversed()) }
        case "is": return { CodePoints.of($0) == v }
        case "in": return { CodePoints.contains(v, CodePoints.of($0)) }
        case "not contains": return { !CodePoints.contains(CodePoints.of($0), v) }
        case "is not": return { CodePoints.of($0) != v }
        case "not in": return { !CodePoints.contains(v, CodePoints.of($0)) }
        default: throw ListError(description: "Invalid condition: \(op)")
        }
    }

    static func numberFilter(_ op: String, _ v: Double) throws -> (Double) -> Bool {
        switch op {
        case "=": return { $0 == v }
        case "≠": return { $0 != v }
        case "<": return { $0 < v }
        case "≤": return { $0 <= v }
        case ">": return { $0 > v }
        case "≥": return { $0 >= v }
        default: throw ListError(description: "Invalid condition: \(op)")
        }
    }

    /// `_extract_slice`: the `serial`-th item (from 1; the serial may be a template).
    func extract(_ values: [JSONValue], _ pool: VariablePool) throws -> [JSONValue] {
        let text = VariableTemplate.convert(pool, extractSerial).text
        guard let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NodeError("ValueError", "invalid literal for int() with base 10: \(PythonText.repr(.string(text)))")
        }
        if n < 1 { throw NodeError("ValueError", "Invalid serial index: must be >= 1, got \(n)") }
        if n > values.count { throw ListError(description: "Invalid serial index: must be <= \(values.count), got \(n)") }
        return [values[n - 1]]
    }

    /// `sorted(values, reverse=desc)`: stable, Python's ordering (code points for strings, numbers by value, False < True).
    func applyOrder(_ values: [JSONValue], _ type: SegmentType) throws -> [JSONValue] {
        if type == .arrayFile { throw ListError(description: "Invalid order key: \(orderKey)") }
        let desc = order == "desc"
        func less(_ a: JSONValue, _ b: JSONValue) -> Bool {
            if case .string(let x) = a, case .string(let y) = b {
                return x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars) { $0.value < $1.value }
            }
            func num(_ v: JSONValue) -> Double? { v.double ?? v.bool.map { $0 ? 1 : 0 } }
            if let x = num(a), let y = num(b) { return x < y }
            return false
        }
        return values.enumerated().sorted { l, r in
            let (a, b) = (l.element, r.element)
            if desc { if less(b, a) { return true }; if less(a, b) { return false } } else {
                if less(a, b) { return true }; if less(b, a) { return false }
            }
            return l.offset < r.offset
        }.map(\.element)
    }
}

extension BuiltinNodeFactory {
    func makeListOperator(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        try ListOperatorNode(id: config.id, data: config.data)
    }
}
