// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/code/code_node.py,
// entities.py, limits.py, exc.py; Dify 1.17.1 (Apache-2.0 with Dify's conditions): api/core/workflow/node_factory.py
// (DefaultWorkflowCodeExecutor, CodeNodeLimits from CODE_*). See ../../NOTICE.md.
//
// Not ported: file inputs (no files before P5), `dependencies` (graphon ignores them too).

import Foundation

/// The code node: Python 3 or JavaScript in the sandbox (`main(...)` over named variables); its returned object is checked
/// against the declared outputs and Dify's limits.
public struct CodeNode: RuntimeNode {
    /// `CodeNodeData.Output`.
    public struct OutputSpec: Sendable {
        public var type: SegmentType
        public var children: [(name: String, spec: OutputSpec)]?
    }

    public let id: String
    public let base: BaseNodeData
    public let variables: [VariableSelector]
    public let language: CodeLanguage
    public let code: String
    public let outputs: [(name: String, spec: OutputSpec)]
    let executor: any CodeExecutor
    let limits: CodeNodeLimits

    public var nodeType: String { NodeType.code }
    public var retryEnabled: Bool { base.retryConfig.retryEnabled }

    static let allowedOutputTypes: [SegmentType] = [.string, .number, .object, .boolean, .arrayString, .arrayNumber, .arrayObject,
                                                    .arrayBoolean]

    public init(id: String, data: JSONObject, executor: any CodeExecutor, limits: CodeNodeLimits? = nil) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let vars = data["variables"]?.array else { throw NodeDataError("variables: Field required") }
        variables = try vars.map { v in
            guard let s = VariableSelector(json: v) else { throw NodeDataError("variables: variable and value_selector are required") }
            return s
        }
        switch data["code_language"]?.string {
        case "python3"?: language = .python3
        case "javascript"?: language = .javascript
        default: throw NodeDataError("code_language: Input should be 'python3' or 'javascript'")
        }
        guard let c = data["code"]?.string else { throw NodeDataError("code: Field required") }
        code = c
        guard let outs = data["outputs"]?.object else { throw NodeDataError("outputs: Field required") }
        outputs = try outs.map { ($0.key, try Self.outputSpec($0.value)) }
        self.executor = executor
        self.limits = limits ?? executor.limits
    }

    static func outputSpec(_ j: JSONValue) throws -> OutputSpec {
        guard let t = j["type"]?.string, let type = SegmentType(rawValue: t) else {
            throw NodeDataError("outputs.type: Input should be a valid segment type")
        }
        guard allowedOutputTypes.contains(type) else {
            throw NodeDataError("invalid type for code output, expected \(allowedOutputTypes.map(\.rawValue)), actual \(type.rawValue)")
        }
        var children: [(String, OutputSpec)]?
        if let c = j["children"]?.object { children = try c.map { ($0.key, try outputSpec($0.value)) } }
        return OutputSpec(type: type, children: children)
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var inputs = JSONObject()
        for v in variables { inputs[v.variable] = context.pool.get(v.valueSelector)?.object ?? .null }
        do {
            let result = try await CodeTemplateTransformer.execute(executor, language: language, code: code, inputs: inputs)
            let outputs = try transformResult(result, schema: outputs)
            await emit(.completed(NodeRunResult(status: .succeeded, inputs: inputs, outputs: outputs)))
        } catch let e as CodeNodeError {
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, error: e.message, errorType: e.kind.rawValue)))
        } catch let e as CodeExecutionError {
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, error: e.message, errorType: "CodeExecutionError")))
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var out: [(String, [String])] = []
        for v in variables {
            let key = id + "." + v.variable
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1 = v.valueSelector } else { out.append((key, v.valueSelector)) }
        }
        return out
    }

    // MARK: - Output validation (graphon's _transform_result and helpers)

    /// `CodeNodeError` and its subclasses (`error_type` is the class name).
    public struct CodeNodeError: Error, CustomStringConvertible, Sendable {
        public enum Kind: String, Sendable { case codeNodeError = "CodeNodeError", outputValidation = "OutputValidationError",
                                                  depthLimit = "DepthLimitError" }
        public var kind: Kind
        public var message: String
        public var description: String { message }
    }

    static func validation(_ m: String) -> CodeNodeError { CodeNodeError(kind: .outputValidation, message: m) }

    static func pyClass(_ v: JSONValue) -> String { "<class '\(CodeTemplateTransformer.pythonTypeName(v))'>" }

    static func path(_ prefix: String, _ name: String) -> String { prefix.isEmpty ? name : "\(prefix).\(name)" }

    static func isNumber(_ v: JSONValue) -> Bool {
        switch v { case .int, .double, .bool: return true; default: return false }
    }

    func checkString(_ s: String?, _ variable: String) throws -> String? {
        guard let s else { return nil }
        if s.unicodeScalars.count > limits.maxStringLength {
            throw Self.validation("The length of output variable `\(variable)` must be less than \(limits.maxStringLength) characters")
        }
        return s.replacingOccurrences(of: "\u{0}", with: "")
    }

    /// Python's `float > int` (exact).
    static func greater(_ d: Double, _ i: Int) -> Bool {
        if d.isNaN { return false }
        if d >= 9.223372036854775808e18 { return true }
        if d < -9.223372036854775808e18 { return false }
        let f = d.rounded(.down)
        return d == f ? Int(f) > i : Int(f) >= i
    }

    static func less(_ d: Double, _ i: Int) -> Bool {
        if d.isNaN { return false }
        return i == Int.min ? false : greater(-d, -i)
    }

    /// `Decimal(str(value)).normalize()`'s negative exponent.
    static func precision(_ d: Double) -> Int {
        if !d.isFinite || d == 0 { return 0 }
        let r = PythonText.floatRepr(abs(d))
        var mantissa = r, exp = 0
        if let e = r.firstIndex(of: "e") {
            mantissa = String(r[..<e])
            exp = Int(r[r.index(after: e)...]) ?? 0
        }
        var digits = mantissa.replacingOccurrences(of: ".", with: "")
        var exponent = exp - (mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0)
        while digits.count > 1, digits.last == "0" { digits.removeLast(); exponent += 1 }
        return exponent < 0 ? -exponent : 0
    }

    func checkNumber(_ v: JSONValue, _ variable: String) throws {
        let out: Bool
        switch v {
        case .null: return
        case .int(let i): out = i > limits.maxNumber || i < limits.minNumber
        case .bool(let b): out = (b ? 1 : 0) > limits.maxNumber || (b ? 1 : 0) < limits.minNumber
        case .double(let d): out = Self.greater(d, limits.maxNumber) || Self.less(d, limits.minNumber)
        default: return
        }
        if out {
            throw Self.validation("Output variable `\(variable)` is out of range, it must be between \(limits.minNumber) and \(limits.maxNumber).")
        }
        if case .double(let d) = v, Self.precision(d) > limits.maxPrecision {
            throw Self.validation("Output variable `\(variable)` has too high precision, it must be less than \(limits.maxPrecision) digits.")
        }
    }

    static func boolToInt(_ v: JSONValue) -> JSONValue {
        if case .bool(let b) = v { return .int(b ? 1 : 0) }
        return v
    }

    func validateUntypedList(_ name: String, _ list: [JSONValue], _ prefix: String, _ depth: Int) throws {
        let outputPath = Self.path(prefix, name)
        guard let first = list.first, first != .null else { return }
        func indexed(_ i: Int) -> String { "\(outputPath)[\(i)]" }
        if Self.isNumber(first), list.allSatisfy({ $0 == .null || Self.isNumber($0) }) {
            for (i, v) in list.enumerated() { try checkNumber(v, indexed(i)) }
            return
        }
        if first.string != nil, list.allSatisfy({ $0 == .null || $0.string != nil }) {
            for (i, v) in list.enumerated() { _ = try checkString(v.string, indexed(i)) }
            return
        }
        if (first.object != nil && list.allSatisfy({ $0 == .null || $0.object != nil }))
            || (first.array != nil && list.allSatisfy({ $0 == .null || $0.array != nil })) {
            for (i, v) in list.enumerated() where v != .null {
                if case .object(let o) = v {
                    _ = try transformResult(o, schema: nil, prefix: indexed(i), depth: depth + 1)
                } else if depth + 1 > limits.maxDepth {
                    throw CodeNodeError(kind: .depthLimit, message: "Depth limit \(limits.maxDepth) reached, object too deep.")
                } else {
                    // graphon hands the inner list to `_transform_result`, which fails on `.items()`.
                    throw NodeError("AttributeError", "'list' object has no attribute 'items'")
                }
            }
            return
        }
        throw Self.validation("Output \(outputPath) is not a valid array. make sure all elements are of the same type.")
    }

    func validateUntyped(_ name: String, _ value: JSONValue, _ prefix: String, _ depth: Int) throws {
        let outputPath = Self.path(prefix, name)
        switch value {
        case .object(let o): _ = try transformResult(o, schema: nil, prefix: outputPath, depth: depth + 1)
        case .bool: return
        case .int, .double: try checkNumber(value, outputPath)
        case .string(let s): _ = try checkString(s, outputPath)
        case .array(let a): try validateUntypedList(name, a, prefix, depth)
        case .null: return
        }
    }

    func transformSchemaOutput(_ name: String, _ spec: OutputSpec, _ result: JSONObject, _ prefix: String, _ depth: Int) throws -> JSONValue {
        let value = result[name] ?? .null
        let outputPath = Self.path(prefix, name)
        func indexed(_ i: Int) -> String { "\(outputPath)[\(i)]" }
        func requireArray(_ max: Int?) throws -> [JSONValue]? {
            guard case .array(let a) = value else {
                if value == .null { return nil }
                throw Self.validation("Output \(outputPath) is not an array, got \(Self.pyClass(value)) instead.")
            }
            if let max, a.count > max {
                throw Self.validation("The length of output variable `\(outputPath)` must be less than \(max) elements.")
            }
            return a
        }
        switch spec.type {
        case .object:
            guard case .object(let o) = value else {
                if value == .null { return .null }
                throw Self.validation("Output \(outputPath) is not an object, got \(Self.pyClass(value)) instead.")
            }
            return .object(try transformResult(o, schema: spec.children, prefix: outputPath, depth: depth + 1))
        case .number:
            if value != .null, !Self.isNumber(value) {
                throw Self.validation("Output \(outputPath) is not a number, got \(Self.pyClass(value)) instead.")
            }
            try checkNumber(value, outputPath)
            return Self.boolToInt(value)
        case .string:
            if value != .null, value.string == nil {
                throw Self.validation("Output \(outputPath) must be a string, got \(CodeTemplateTransformer.pythonTypeName(value)) instead.")
            }
            return try checkString(value.string, outputPath).map(JSONValue.string) ?? .null
        case .boolean:
            return value
        case .arrayNumber:
            guard let a = try requireArray(limits.maxNumberArrayLength) else { return .null }
            for (i, v) in a.enumerated() where !Self.isNumber(v) {
                throw Self.validation("The element at index \(i) of output variable `\(outputPath)` must be a number.")
            }
            return .array(a.map(Self.boolToInt))
        case .arrayString:
            guard let a = try requireArray(limits.maxStringArrayLength) else { return .null }
            var out: [JSONValue] = []
            for (i, v) in a.enumerated() {
                if v != .null, v.string == nil {
                    throw Self.validation("Output \(outputPath)[\(i)] must be a string, got \(CodeTemplateTransformer.pythonTypeName(v)) instead.")
                }
                out.append(try checkString(v.string, indexed(i)).map(JSONValue.string) ?? .null)
            }
            return .array(out)
        case .arrayObject:
            guard let a = try requireArray(limits.maxObjectArrayLength) else { return .null }
            var out: [JSONValue] = []
            for (i, v) in a.enumerated() {
                if v == .null { out.append(.null); continue }
                guard case .object(let o) = v else {
                    throw Self.validation("Output \(outputPath)[\(i)] is not an object, got \(Self.pyClass(v)) instead at index \(i).")
                }
                out.append(.object(try transformResult(o, schema: spec.children, prefix: indexed(i), depth: depth + 1)))
            }
            return .array(out)
        case .arrayBoolean:
            guard let a = try requireArray(nil) else { return .null }
            for (i, v) in a.enumerated() where v != .null && v.bool == nil {
                throw Self.validation("Output \(outputPath)[\(i)] is not a boolean, got \(Self.pyClass(v)) instead.")
            }
            return value
        default:
            throw Self.validation("Output type \(spec.type.rawValue) is not supported.")
        }
    }

    /// `_transform_result`.
    func transformResult(_ result: JSONObject, schema: [(name: String, spec: OutputSpec)]?, prefix: String = "", depth: Int = 1) throws -> JSONObject {
        if depth > limits.maxDepth {
            throw CodeNodeError(kind: .depthLimit, message: "Depth limit \(limits.maxDepth) reached, object too deep.")
        }
        guard let schema else {
            for (name, value) in result { try validateUntyped(name, value, prefix, depth) }
            return result
        }
        var out = JSONObject()
        for (name, spec) in schema {
            guard result[name] != nil else { throw Self.validation("Output \(Self.path(prefix, name)) is missing.") }
            out[name] = try transformSchemaOutput(name, spec, result, prefix, depth)
        }
        if out.count != result.count { throw CodeNodeError(kind: .codeNodeError, message: "Not all output parameters are validated.") }
        return out
    }
}

extension BuiltinNodeFactory {
    /// Dify's factory: the sandbox (`DefaultWorkflowCodeExecutor`) and `CODE_*` limits.
    func makeCode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        guard let executor = services.codeExecutor else { throw ServiceNotConfigured(service: .codeSandbox) }
        return try CodeNode(id: config.id, data: config.data, executor: executor)
    }
}
