// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/loop/loop_node.py,
// entities.py. See ../../NOTICE.md.

import Foundation

/// The loop node: its inner nodes run round after round (in child frames over the parent's pool) until a break condition
/// holds, a loop-end node runs, or `loop_count` rounds ran. The node initializes the loop variables and suspends with
/// `LoopFrameRequest`s; the engine runs the rounds.
public struct LoopNode: RuntimeNode {
    /// `LoopVariableData`.
    public struct LoopVariable: Sendable {
        public var label: String
        public var varType: SegmentType
        /// `variable` (a selector) or `constant`.
        public var valueType: String
        public var value: JSONValue
    }

    public let id: String
    public let base: BaseNodeData
    public let startNodeId: String
    public let loopCount: Int
    public let breakConditions: [Condition]
    public let logicalOperator: String
    public let loopVariables: [LoopVariable]
    /// `_extract_loop_node_ids_from_config`: the nodes whose `data.loop_id` is this loop.
    public let loopNodeIds: Set<String>

    public var nodeType: String { NodeType.loop }
    public var executionType: NodeExecutionType { .container }

    static let validVarTypes: Set<SegmentType> = [.string, .number, .object, .boolean, .arrayString, .arrayNumber, .arrayObject, .arrayBoolean]

    public init(id: String, data: JSONObject, graph: GraphConfig) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let start = data["start_node_id"]?.string else { throw NodeDataError("start_node_id: Field required") }
        startNodeId = start
        guard let count = data["loop_count"]?.int else { throw NodeDataError("loop_count: Field required") }
        guard count >= 1 else { throw NodeDataError("loop_count: Input should be greater than or equal to 1") }
        loopCount = count
        guard let conditions = data["break_conditions"]?.array else { throw NodeDataError("break_conditions: Field required") }
        breakConditions = try conditions.map(Condition.init(json:))
        guard let op = data["logical_operator"]?.string, op == "and" || op == "or" else {
            throw NodeDataError("logical_operator: Input should be 'and' or 'or'")
        }
        logicalOperator = op
        loopVariables = try (data["loop_variables"]?.array ?? []).map { v in
            guard let label = v["label"]?.string else { throw NodeDataError("loop_variables.label: Field required") }
            guard let t = v["var_type"]?.string, let type = SegmentType(rawValue: t), Self.validVarTypes.contains(type) else {
                throw NodeDataError("loop_variables.var_type: Value error")
            }
            guard let vt = v["value_type"]?.string, vt == "variable" || vt == "constant" else {
                throw NodeDataError("loop_variables.value_type: Input should be 'variable' or 'constant'")
            }
            return LoopVariable(label: label, varType: type, valueType: vt, value: v["value"] ?? .null)
        }
        loopNodeIds = Set(graph.nodes.filter { $0.data["loop_id"]?.string == id }.map(\.id))
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var inputs: JSONObject = ["loop_count": .int(loopCount)]
        // _initialize_loop_variables: each value is written to the pool (as its plain value) before the next is read.
        var pool = context.pool
        var selectors: [(key: String, selector: [String])] = []
        var initial: [(selector: [String], value: JSONValue)] = []
        for v in loopVariables {
            let segment: Segment?
            if v.valueType == "constant" {
                segment = try Self.constantSegment(v.varType, v.value)
            } else {
                guard let list = v.value.array, list.allSatisfy({ $0.string != nil }) else {
                    throw NodeError("TypeError", "Invalid value for loop variable \(v.label)")
                }
                segment = pool.get(list.compactMap(\.string))
            }
            guard let segment else { throw NodeError("ValueError", "Invalid value for loop variable \(v.label)") }
            let selector = [id, v.label]
            try pool.add(selector, segment.value)
            initial.append((selector, segment.value))
            selectors.append((v.label, selector))
            inputs[v.label] = segment.value
        }
        await emit(.containerStarted(kind: .loop, startAt: Date(), inputs: inputs, metadata: ["loop_length": .int(loopCount)]))
        await emit(.awaitContainer(.loop(LoopFrameRequest(inputs: inputs, outputs: [:], loopCount: loopCount, rootNodeId: startNodeId,
                                                          loopVariableSelectors: selectors, loopNodeIds: loopNodeIds, index: 0,
                                                          initialVariables: initial))))
    }

    public func resume(_ result: ContainerResult, startAt: Date, context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        switch result {
        case .request(.loop(let request)):
            await emit(.containerNext(kind: .loop, index: request.index, preOutput: request.outputs))
            await emit(.awaitContainer(.loop(request)))
        case .request(.iteration):
            throw NodeError("TypeError", "Unsupported loop result IterationFrameRequest")
        case .finished(let outcome):
            let r = outcome.result
            switch r.status {
            case .succeeded:
                await emit(.containerCompleted(kind: .loop, startAt: startAt, inputs: r.inputs, outputs: r.outputs, metadata: outcome.metadata,
                                               steps: outcome.steps, error: nil))
            case .failed:
                await emit(.containerCompleted(kind: .loop, startAt: startAt, inputs: r.inputs, outputs: r.outputs, metadata: outcome.metadata,
                                               steps: outcome.steps, error: r.error))
            default:
                throw NodeError("ValueError", "Unsupported loop status \(r.status.rawValue)")
            }
            await emit(.completed(r))
        }
    }

    /// `_get_segment_for_constant`: arrays of numbers / objects / strings come as JSON text (anything else is `[]`); a value
    /// of the wrong type given as text is parsed as JSON once more.
    static func constantSegment(_ type: SegmentType, _ original: JSONValue) throws -> Segment {
        var value = original
        switch type {
        case .arrayNumber, .arrayObject, .arrayString:
            if case .string(let s) = original, !s.isEmpty {
                do { value = try JSONValue.parse(s) } catch { throw NodeError("JSONDecodeError", "\(error)") }
            } else {
                value = .array([])
            }
        default:
            break
        }
        do {
            return try DraftVariableRules.buildSegment(type: type, value: value)
        } catch let mismatch {
            guard case .string(let s) = original, let parsed = try? JSONValue.parse(s) else { throw NodeError("TypeMismatchError", "\(mismatch)") }
            do { return try DraftVariableRules.buildSegment(type: type, value: parsed) } catch {
                throw NodeError("TypeMismatchError", "\(error)")
            }
        }
    }

    /// `{id}.{label}` for the loop variables that read a variable (the inner nodes' part: `ContainerVariableMapping`).
    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        loopVariables.compactMap { v in
            guard v.valueType == "variable", let list = v.value.array else { return nil }
            return ("\(id).\(v.label)", list.compactMap(\.string))
        }
    }
}
