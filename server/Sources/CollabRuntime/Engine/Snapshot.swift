// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// runtime/graph_runtime_state.py, runtime/container_state.py, graph_engine/frames.py and
// graph_engine/filters/response_stream.py (snapshot/restore). See ../NOTICE.md.
// The encoding is versioned for this Swift runtime; it is not a Python object pickle or a graphon snapshot.

import Foundation

/// A drained engine's durable state. Services and node instances are rebuilt from the saved graph; they are never
/// serialized. JSON values use literal text to preserve Python object order and `1` versus `1.0`; segment types are explicit.
public struct GraphEngineSnapshot: Sendable {
    let state: EngineSnapshotRecord

    public struct Invalid: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.runtimeSnapshot] = true
        let state = try decoder.decode(EngineSnapshotRecord.self, from: data)
        guard state.version == 1 else { throw Invalid(description: "Unsupported runtime snapshot version \(state.version)") }
        guard let root = state.frames[rootFrameId], state.pools[root.poolId] != nil else {
            throw Invalid(description: "Runtime snapshot has no root frame or variable pool")
        }
        self.state = state
    }

    init(_ dispatcher: Dispatcher) {
        state = EngineSnapshotRecord(version: 1, graph: dispatcher.graph.config.json, rootId: dispatcher.graph.rootId,
                                     frames: dispatcher.frames, pools: dispatcher.pools,
                                     ready: Array(dispatcher.readyQueue.dropFirst(dispatcher.readyHead)),
                                     containers: dispatcher.containerRuns, executionIds: dispatcher.executionIds,
                                     retryCounts: dispatcher.retryCounts, exceptionsCount: dispatcher.exceptionsCount,
                                     filter: dispatcher.filter.snapshot)
    }

    /// The root frame's variable pool: what a human-input form's runtime references (and a variable-backed select's
    /// options) are resolved against — Dify's `GraphRuntimeState.variable_pool` from the same pause snapshot.
    public func variablePool() -> VariablePool? {
        // `rootId` is the graph's root **node**, not a frame: the root frame is always "root" (GraphEngine.rootFrameId).
        let rootId = "root"
        guard let root = state.frames[rootId] else { return nil }
        return state.pools[root.poolId]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.userInfo[.runtimeSnapshot] = true
        return try encoder.encode(state)
    }
}

struct EngineSnapshotRecord: Codable, Sendable {
    var version: Int
    var graph: JSONValue
    var rootId: String
    var frames: [String: ExecutionFrame]
    var pools: [String: VariablePool]
    var ready: [ReadyTask]
    var containers: [String: ContainerRun]
    var executionIds: [FrameNode: String]
    var retryCounts: [FrameNode: Int]
    var exceptionsCount: Int
    var filter: ResponseStreamFilter.Snapshot
}

// Tuple-shaped runtime APIs stay unchanged; their durable representation uses named records.
private struct SelectorRecord: Codable { var key: String; var selector: [String] }
private struct InitialVariableRecord: Codable { var selector: [String]; var value: JSONValue }

extension LoopFrameRequest: Codable {
    private struct Record: Codable {
        var inputs: JSONObject
        var outputs: JSONObject
        var loopCount: Int
        var rootNodeId: String
        var selectors: [SelectorRecord]
        var nodeIds: Set<String>
        var index: Int
        var initial: [InitialVariableRecord]
    }

    public init(from decoder: any Decoder) throws {
        let r = try Record(from: decoder)
        self.init(inputs: r.inputs, outputs: r.outputs, loopCount: r.loopCount, rootNodeId: r.rootNodeId,
                  loopVariableSelectors: r.selectors.map { ($0.key, $0.selector) }, loopNodeIds: r.nodeIds, index: r.index,
                  initialVariables: r.initial.map { ($0.selector, $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        try Record(inputs: inputs, outputs: outputs, loopCount: loopCount, rootNodeId: rootNodeId,
                   selectors: loopVariableSelectors.map { SelectorRecord(key: $0.key, selector: $0.selector) },
                   nodeIds: loopNodeIds, index: index,
                   initial: initialVariables.map { InitialVariableRecord(selector: $0.selector, value: $0.value) }).encode(to: encoder)
    }
}

extension LoopRun: Codable {
    private struct Record: Codable {
        var invocationId: String
        var frameId: String
        var nodeId: String
        var startedAt: Date
        var inputs: JSONObject
        var outputs: JSONObject
        var loopCount: Int
        var rootNodeId: String
        var selectors: [SelectorRecord]
        var nodeIds: Set<String>
        var durationMap: JSONObject
        var variableMap: JSONObject
        var usage: LLMUsage
        var completedCount: Int
        var reachedBreak: Bool
    }

    init(from decoder: any Decoder) throws {
        let r = try Record(from: decoder)
        self.init(invocationId: r.invocationId, frameId: r.frameId, nodeId: r.nodeId, startedAt: r.startedAt,
                  inputs: r.inputs, outputs: r.outputs, loopCount: r.loopCount, rootNodeId: r.rootNodeId,
                  loopVariableSelectors: r.selectors.map { ($0.key, $0.selector) }, loopNodeIds: r.nodeIds,
                  durationMap: r.durationMap, variableMap: r.variableMap, usage: r.usage,
                  completedCount: r.completedCount, reachedBreak: r.reachedBreak)
    }

    func encode(to encoder: any Encoder) throws {
        try Record(invocationId: invocationId, frameId: frameId, nodeId: nodeId, startedAt: startedAt,
                   inputs: inputs, outputs: outputs, loopCount: loopCount, rootNodeId: rootNodeId,
                   selectors: loopVariableSelectors.map { SelectorRecord(key: $0.key, selector: $0.selector) },
                   nodeIds: loopNodeIds, durationMap: durationMap, variableMap: variableMap, usage: usage,
                   completedCount: completedCount, reachedBreak: reachedBreak).encode(to: encoder)
    }
}

extension VariablePool: Codable {
    private struct Entry: Codable { var name: String; var segment: Segment }
    private struct Node: Codable { var id: String; var entries: [Entry] }

    public init(from decoder: any Decoder) throws {
        self.init()
        let nodes = try [Node](from: decoder)
        for node in nodes {
            remove([node.id]) // Empty namespaces and their original insertion order matter too.
            for entry in node.entries { try add([node.id, entry.name], entry.segment) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try nodeOrder.map { id in
            Node(id: id, entries: (variables[id] ?? []).map { Entry(name: $0.name, segment: $0.segment) })
        }.encode(to: encoder)
    }
}

extension ResponseStreamFilter {
    struct Snapshot: Codable, Sendable {
        var activeSession: Session?
        var waitingSessions: [Session]
        var responseSessions: [String: Session]
        var pathsMaps: [String: [[String]]]
        var nodeExecutionIds: [String: String]
        var buffers: [[String]: [Chunk]]
        var positions: [[String]: Int]
        var closed: Set<[String]>
    }

    var snapshot: Snapshot {
        Snapshot(activeSession: activeSession, waitingSessions: waitingSessions, responseSessions: responseSessions,
                 pathsMaps: pathsMaps, nodeExecutionIds: nodeExecutionIds, buffers: buffers, positions: positions, closed: closed)
    }

    mutating func restore(_ snapshot: Snapshot) {
        activeSession = snapshot.activeSession
        waitingSessions = snapshot.waitingSessions
        responseSessions = snapshot.responseSessions
        pathsMaps = snapshot.pathsMaps
        nodeExecutionIds = snapshot.nodeExecutionIds
        buffers = snapshot.buffers
        positions = snapshot.positions
        closed = snapshot.closed
    }
}
