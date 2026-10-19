// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/iteration/iteration_node.py,
// iteration_start_node.py, entities.py, graphon/nodes/loop/loop_start_node.py, loop_end_node.py. See ../../NOTICE.md.

import Foundation

/// The iteration node: its inner nodes run once per item of a list (in child frames the engine runs, `parallel_nums` at a
/// time when parallel); the node keeps only its configuration and suspends with `IterationFrameRequest`s
/// (graphon: "iteration execution is interpreted by GraphEngine").
public struct IterationNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let startNodeId: String
    public let iteratorSelector: [String]
    public let outputSelector: [String]
    public let isParallel: Bool
    public let parallelNums: Int
    public let errorHandleMode: ErrorHandleMode
    public let flattenOutput: Bool

    public var nodeType: String { NodeType.iteration }
    public var executionType: NodeExecutionType { .container }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let start = data["start_node_id"]?.string else { throw NodeDataError("start_node_id: Field required") }
        startNodeId = start
        iteratorSelector = try Self.selector(data["iterator_selector"], "iterator_selector")
        outputSelector = try Self.selector(data["output_selector"], "output_selector")
        switch data["is_parallel"] {
        case nil, .null?: isParallel = false
        case .bool(let b)?: isParallel = b
        default: throw NodeDataError("is_parallel: Input should be a valid boolean")
        }
        switch data["parallel_nums"] {
        case nil, .null?: parallelNums = 10
        case .int(let n)?:
            guard n >= 1 else { throw NodeDataError("parallel_nums: Input should be greater than or equal to 1") }
            parallelNums = n
        default: throw NodeDataError("parallel_nums: Input should be a valid integer")
        }
        switch data["error_handle_mode"] {
        case nil, .null?: errorHandleMode = .terminated
        case .string(let s)?:
            guard let m = ErrorHandleMode(rawValue: s) else {
                throw NodeDataError("error_handle_mode: Input should be 'terminated', 'continue-on-error' or 'remove-abnormal-output'")
            }
            errorHandleMode = m
        default: throw NodeDataError("error_handle_mode: Input should be a valid string")
        }
        switch data["flatten_output"] {
        case nil, .null?: flattenOutput = true
        case .bool(let b)?: flattenOutput = b
        default: throw NodeDataError("flatten_output: Input should be a valid boolean")
        }
    }

    static func selector(_ v: JSONValue?, _ field: String) throws -> [String] {
        guard let list = v?.array else { throw NodeDataError("\(field): Field required") }
        let parts = list.compactMap(\.string)
        guard parts.count == list.count else { throw NodeDataError("\(field): Input should be a valid list of strings") }
        return parts
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        guard let variable = context.pool.get(iteratorSelector) else {
            throw NodeError("ValueError", "iterator variable \(PythonText.repr(.array(iteratorSelector.map(JSONValue.string)))) not found")
        }
        let startedAt = Date()
        if variable.valueType == .none || (variable.valueType.isArray && (variable.value.array ?? []).isEmpty) {
            await runEmpty(variable, startedAt: startedAt, emit: emit)
            return
        }
        // _resolve_iterator_value
        guard variable.valueType.isArray, let items = variable.value.array else {
            throw NodeError("TypeError", "invalid iterator value: \(Self.segmentRepr(variable)), please provide a list.")
        }
        let parallel = isParallel ? parallelNums : 1
        await emit(.containerStarted(kind: .iteration, startAt: startedAt, inputs: ["iterator_selector": .array(items)],
                                     metadata: ["iteration_length": .int(items.count)]))
        let indexes = Array(0..<min(parallel, items.count))
        for index in indexes { await emit(.containerNext(kind: .iteration, index: index, preOutput: [:])) }
        await emit(.awaitContainer(.iteration(IterationFrameRequest(
            items: items, rootNodeId: startNodeId, indexes: indexes, outputSelector: outputSelector, errorHandleMode: errorHandleMode,
            flattenOutput: flattenOutput, parallelNums: parallel))))
    }

    /// `_run_empty_iteration`: a missing or empty list succeeds at once with an empty output of the list's type.
    func runEmpty(_ variable: Segment, startedAt: Date, emit: @Sendable (NodeEvent) async -> Void) async {
        let type: SegmentType = variable.valueType.isArray ? variable.valueType : .arrayAny
        let inputs: JSONObject = ["iterator_selector": .array([])]
        let outputs: JSONObject = ["output": .array([])]
        await emit(.containerStarted(kind: .iteration, startAt: startedAt, inputs: inputs, metadata: ["iteration_length": 0]))
        await emit(.containerCompleted(kind: .iteration, startAt: startedAt, inputs: inputs, outputs: outputs, metadata: [:], steps: 0, error: nil))
        var r = NodeRunResult(status: .succeeded, inputs: inputs, outputs: outputs)
        r.outputTypes["output"] = type
        await emit(.completed(r))
    }

    public func resume(_ result: ContainerResult, startAt: Date, context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        switch result {
        case .request(.iteration(let request)):
            for index in request.indexes { await emit(.containerNext(kind: .iteration, index: index, preOutput: [:])) }
            await emit(.awaitContainer(.iteration(request)))
        case .request(.loop):
            throw NodeError("TypeError", "Unsupported iteration result LoopFrameRequest")
        case .finished(let outcome):
            let r = outcome.result
            switch r.status {
            case .succeeded:
                await emit(.containerCompleted(kind: .iteration, startAt: startAt, inputs: r.inputs, outputs: r.outputs, metadata: outcome.metadata,
                                               steps: outcome.steps, error: nil))
            case .failed:
                await emit(.containerCompleted(kind: .iteration, startAt: startAt, inputs: r.inputs, outputs: r.outputs, metadata: outcome.metadata,
                                               steps: outcome.steps, error: r.error))
            default:
                throw NodeError("ValueError", "Unsupported iteration status \(r.status.rawValue)")
            }
            await emit(.completed(r))
        }
    }

    /// The single run's variable mapping of the node itself (`{id}.input_selector`); the inner nodes' part needs their
    /// instances (`ContainerVariableMapping`).
    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        [("\(id).input_selector", iteratorSelector)]
    }

    /// `str(segment)` of a pydantic segment (`value_type=<SegmentType.STRING: 'string'> value='abc'`).
    static func segmentRepr(_ s: Segment) -> String {
        let name = s.valueType.rawValue.replacingOccurrences(of: "[", with: "_").replacingOccurrences(of: "]", with: "").uppercased()
        return "value_type=<SegmentType.\(name): '\(s.valueType.rawValue)'> value=\(PythonText.repr(s.value))"
    }
}

/// `IterationStartNode`, `LoopStartNode`, `LoopEndNode`: they succeed with nothing (a loop end ends its loop: the engine
/// sees it succeed).
public struct ContainerStartNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let nodeType: String

    public init(id: String, data: JSONObject, nodeType: String) throws {
        self.id = id
        base = try BaseNodeData(data)
        self.nodeType = nodeType
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        await emit(.completed(NodeRunResult(status: .succeeded)))
    }
}

/// The variable mapping of an iteration or loop single run (`_extract_variable_selector_to_variable_mapping` of
/// `IterationNode` / `LoopNode`): the container's own selectors plus its inner nodes' (keys prefixed with the inner node's
/// id), without selectors of the container itself or of nodes inside it.
public enum ContainerVariableMapping {
    public static func mapping(containerId: String, graph: GraphConfig, factory: any NodeFactory) async throws
        -> [(key: String, selector: [String])] {
        guard let config = graph.node(containerId) else { return [] }
        let container = try await factory.createNode(config, graph: graph)
        let key = container.nodeType == NodeType.loop ? "loop_id" : "iteration_id"
        let inner = graph.nodes.filter { $0.data[key]?.string == containerId }.map(\.id)
        let innerIds = Set(inner)
        var out: [(key: String, selector: [String])] = []
        func put(_ k: String, _ s: [String]) {
            if let i = out.firstIndex(where: { $0.key == k }) { out[i].selector = s } else { out.append((k, s)) }
        }
        if container.nodeType == NodeType.iteration {
            for (k, s) in container.variableMapping(graph: graph) { put(k, s) }
        }
        for subId in inner {
            guard let subConfig = graph.node(subId) else { continue }
            let sub = try await factory.createNode(subConfig, graph: graph)
            // A container inside: its whole mapping (its own inner nodes too).
            let subMapping = sub.nodeType == NodeType.iteration || sub.nodeType == NodeType.loop
                ? try await mapping(containerId: subId, graph: graph, factory: factory) : sub.variableMapping(graph: graph)
            for (k, s) in subMapping where s.first != containerId { put(subId + "." + k, s) }
        }
        if container.nodeType == NodeType.loop {
            for (k, s) in container.variableMapping(graph: graph) { put(k, s) }
        }
        return out.filter { !innerIds.contains($0.selector.first ?? "") }
    }
}
