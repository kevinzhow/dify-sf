// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/graph_engine/graph_engine.py,
// orchestration/dispatcher.py, worker.py, worker_management/worker_pool.py, event_management/event_handlers.py,
// graph_traversal/edge_processor.py, graph_traversal/skip_propagator.py, graph_state_manager.py, error_handler.py,
// domain/graph_execution.py, layers/execution_limits.py, command_processing/command_handlers.py,
// graphon/runtime/graph_runtime_state.py (outputs, usage, steps), graphon/graph_events/graph.py. See ../NOTICE.md.
//
// Shape: graphon runs a dispatcher thread, a pool of worker threads and a generator that polls collected events. Here
// one dispatcher task owns all run state (no locks); nodes run as child tasks (at most `maxWorkers` at a time, in
// ready-queue order) and send their events to the dispatcher's mailbox; collected events pass the response stream
// filter at once and go to the run's stream. Each node reads a copy of the pool taken when it starts (everything it
// can read is written before it is enqueued). Not ported yet: containers (iteration, loop: P3), pause and resume (P4),
// layers other than the execution limits.

import Foundation
import Synchronization

/// `GraphEngineConfig` + Dify's `WORKFLOW_MAX_EXECUTION_STEPS` / `_TIME`.
public struct GraphEngineConfig: Sendable {
    /// Dify's `GRAPH_ENGINE_MAX_WORKERS` (10): nodes running at once.
    public var maxWorkers: Int
    /// `WORKFLOW_MAX_EXECUTION_STEPS` (500).
    public var maxSteps: Int
    /// `WORKFLOW_MAX_EXECUTION_TIME` (3600 s).
    public var maxTimeSeconds: Double

    public init(maxWorkers: Int = 10, maxSteps: Int = 500, maxTimeSeconds: Double = 3600) {
        self.maxWorkers = max(1, maxWorkers)
        self.maxSteps = maxSteps
        self.maxTimeSeconds = maxTimeSeconds
    }
}

/// What a run's stream carries (`GraphEngineEvent`s after Dify's response stream filter).
public enum GraphEngineEvent: Sendable {
    /// `GraphRunStartedEvent`.
    case runStarted
    /// A node event (started, chunks, variable updates, succeeded / failed / exception, retry).
    case node(GraphNodeEvent)
    /// `GraphEdgeTakenEvent` / `GraphEdgeSkippedEvent` (consumed by the response stream filter; never on the stream).
    case edgeTaken(RuntimeGraph.Edge)
    case edgeSkipped(RuntimeGraph.Edge)
    /// `GraphRunSucceededEvent`.
    case runSucceeded(GraphRunStats)
    /// `GraphRunPartialSucceededEvent`: some node failed but an error strategy (or a retry) handled it.
    case runPartialSucceeded(GraphRunStats)
    /// `GraphRunFailedEvent`.
    case runFailed(error: String, GraphRunStats)
    /// `GraphRunAbortedEvent` (stop, execution limits).
    case runAborted(reason: String, GraphRunStats)

    public var isTerminal: Bool {
        switch self {
        case .runSucceeded, .runPartialSucceeded, .runFailed, .runAborted: return true
        default: return false
        }
    }
}

/// The run's totals at its end (`GraphRuntimeState`: outputs, `total_tokens`, `node_run_steps`, `llm_usage`).
public struct GraphRunStats: Sendable {
    public var outputs: JSONObject
    public var totalTokens: Int
    public var totalSteps: Int
    public var llmUsage: LLMUsage
    public var exceptionsCount: Int
}

/// The engine's command channel (`InMemoryChannel` + `AbortCommand`): stop a run from outside.
public final class GraphEngineCommands: Sendable {
    private struct State {
        var abortReason: String?
        var wake: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    public init() {}

    /// `AbortCommand(reason)`; Dify's stop sends "User requested stop".
    public func abort(reason: String? = nil) {
        let wake = state.withLock { s -> (@Sendable () -> Void)? in
            if s.abortReason == nil { s.abortReason = reason ?? "User requested abort" }
            return s.wake
        }
        wake?()
    }

    var pendingAbort: String? { state.withLock { $0.abortReason } }

    func attach(_ wake: @escaping @Sendable () -> Void) {
        let pending = state.withLock { s -> Bool in
            s.wake = wake
            return s.abortReason != nil
        }
        if pending { wake() }
    }
}

/// `GraphEngine`: runs a graph from its root and streams the events.
public struct GraphEngine: Sendable {
    public let graph: RuntimeGraph
    public let config: GraphEngineConfig
    public let commands: GraphEngineCommands
    /// The run's context for nodes (user, app); the pool comes from `run(pool:)`.
    public let userId: String?
    public let appId: String?

    public init(graph: RuntimeGraph, config: GraphEngineConfig = GraphEngineConfig(), commands: GraphEngineCommands = GraphEngineCommands(),
                userId: String? = nil, appId: String? = nil) {
        self.graph = graph
        self.config = config
        self.commands = commands
        self.userId = userId
        self.appId = appId
    }

    /// Runs the graph over `pool` (the bootstrap values: `sys`, `env`, `conversation`, the start node's inputs). The stream
    /// ends after the terminal event. The run does not stop when the consumer goes away; use `commands.abort`.
    public func run(pool: VariablePool) -> AsyncStream<GraphEngineEvent> {
        let (stream, out) = AsyncStream<GraphEngineEvent>.makeStream(bufferingPolicy: .unbounded)
        let engine = self
        Task {
            var dispatcher = Dispatcher(engine: engine, pool: pool, out: out)
            await dispatcher.execute()
            out.finish()
        }
        return stream
    }
}

// MARK: - Dispatcher

/// A message to the dispatcher's mailbox (graphon's event queue).
enum DispatchMessage: Sendable {
    case node(GraphNodeEvent)
    /// A failed node whose retry interval has passed (graphon sleeps in the error handler).
    case retryReady(GraphNodeEvent, retryIndex: Int)
    /// A command arrived.
    case wake
}

/// The dispatcher and everything it owns (graphon's Dispatcher, EventHandler, GraphStateManager, EdgeProcessor,
/// SkipPropagator, ErrorHandler, GraphExecution, GraphRuntimeState and the execution limits layer).
struct Dispatcher {
    let engine: RuntimeGraphEngineRef
    let graph: RuntimeGraph
    let out: AsyncStream<GraphEngineEvent>.Continuation

    // GraphRuntimeState
    var pool: VariablePool
    var outputs = JSONObject()
    var llmUsage = LLMUsage.empty
    var nodeRunSteps = 0

    // Node and edge states, the frame's unfinished set, the ready queue.
    var nodeStates: [String: NodeState] = [:]
    var edgeStates: [String: NodeState] = [:]
    var unfinished = Set<String>()
    var readyQueue: [String] = []
    var running = 0

    // GraphExecution
    var executionIds: [String: String] = [:]
    var retryCounts: [String: Int] = [:]
    var exceptionsCount = 0
    var aborted = false
    var abortReason: String?
    var error: String?

    // ExecutionLimitsLayer
    var limitSteps = 0
    var limitAbortSent = false
    let startedAt = ContinuousClock.now

    var filter: ResponseStreamFilter

    init(engine: GraphEngine, pool: VariablePool, out: AsyncStream<GraphEngineEvent>.Continuation) {
        self.engine = RuntimeGraphEngineRef(engine)
        graph = engine.graph
        self.out = out
        self.pool = pool
        for id in graph.nodeIds { nodeStates[id] = graph.initiallySkippedNodes.contains(id) ? .skipped : .unknown }
        for id in graph.edgeIds { edgeStates[id] = graph.initiallySkippedEdges.contains(id) ? .skipped : .unknown }
        filter = ResponseStreamFilter(graph: graph)
    }

    var config: GraphEngineConfig { engine.value.config }

    mutating func execute() async {
        let (mailbox, post) = AsyncStream<DispatchMessage>.makeStream(bufferingPolicy: .unbounded)
        engine.value.commands.attach { post.yield(.wake) }
        emit(.runStarted)
        await withDiscardingTaskGroup { group in
            enqueue(graph.rootId)
            processCommands()
            if !shouldExit {
                launchReady(&group, post)
                for await message in mailbox {
                    handle(message, post)
                    if shouldExit { break }
                    launchReady(&group, post)
                }
            }
            group.cancelAll()
        }
        post.finish()
        emitTerminal()
        for e in filter.flush(state: filterState) { out.yield(e) }
    }

    var shouldExit: Bool { aborted || error != nil || unfinished.isEmpty }

    var filterState: ResponseStreamFilter.State { .init(pool: pool, nodeStates: nodeStates) }

    /// `EventManager.collect`: through the response stream filter to the stream; the execution limits layer sees it.
    mutating func emit(_ event: GraphEngineEvent) {
        for e in filter.onEvent(event, state: filterState) { out.yield(e) }
        limitsOnEvent(event)
    }

    // MARK: Ready queue and workers

    /// `GraphStateManager.enqueue_node`.
    mutating func enqueue(_ nodeId: String) {
        nodeStates[nodeId] = .taken
        unfinished.insert(nodeId)
        readyQueue.append(nodeId)
    }

    mutating func launchReady(_ group: inout DiscardingTaskGroup, _ post: AsyncStream<DispatchMessage>.Continuation) {
        while running < config.maxWorkers, !readyQueue.isEmpty {
            let nodeId = readyQueue.removeFirst()
            guard let node = graph.nodes[nodeId] else { continue }
            let executionId = executionIds[nodeId] ?? UUID().uuidString.lowercased()
            executionIds[nodeId] = executionId
            running += 1
            let context = NodeRunContext(pool: pool, userId: engine.value.userId, appId: engine.value.appId,
                                         isAborted: { [commands = engine.value.commands] in commands.pendingAbort != nil || Task.isCancelled })
            group.addTask {
                await NodeRunner.run(node, executionId: executionId, context: context) { event in post.yield(.node(event)) }
            }
        }
    }

    // MARK: Commands and limits

    mutating func processCommands() {
        if let reason = engine.value.commands.pendingAbort, !aborted {
            // GraphExecution.abort
            aborted = true
            abortReason = reason
            error = "Aborted: \(reason)"
        }
    }

    /// `ExecutionLimitsLayer.on_event`.
    mutating func limitsOnEvent(_ event: GraphEngineEvent) {
        guard !limitAbortSent, case .node(let e) = event else { return }
        switch e {
        case .started: limitSteps += 1
        case .succeeded, .failed:
            if limitSteps > config.maxSteps {
                limitAbortSent = true
                engine.value.commands.abort(reason: "Maximum execution steps exceeded: \(limitSteps) > \(config.maxSteps)")
            } else {
                let elapsed = SingleStepRun.seconds(ContinuousClock.now - startedAt)
                if elapsed > config.maxTimeSeconds {
                    limitAbortSent = true
                    engine.value.commands.abort(reason: "Maximum execution time exceeded: \(String(format: "%.2f", elapsed))s > \(Int(config.maxTimeSeconds))s")
                }
            }
        default: break
        }
    }

    // MARK: Event handling (EventHandler)

    mutating func handle(_ message: DispatchMessage, _ post: AsyncStream<DispatchMessage>.Continuation) {
        switch message {
        case .wake:
            processCommands()
        case .retryReady(let failed, let retryIndex):
            guard case .failed(let x, let nodeId, let startAt, _, let result, let error) = failed else { return }
            dispatch(.retry(executionId: x, nodeId: nodeId, startAt: startAt, result: result, error: error, retryIndex: retryIndex), post)
        case .node(let event):
            if event.result != nil { running -= 1 }
            dispatch(event, post)
            // Dispatcher._process_commands: after result events (and when idle).
            if event.result != nil { processCommands() }
        }
    }

    mutating func dispatch(_ event: GraphNodeEvent, _ post: AsyncStream<DispatchMessage>.Continuation) {
        switch event {
        case .started:
            // Retries run silently: only the first attempt's started event is collected.
            nodeRunSteps += 1
            if (retryCounts[event.nodeId] ?? 0) == 0 { emit(.node(event)) }
        case .streamChunk, .reasoningChunk, .retrieverResource:
            emit(.node(event))
        case .variableUpdated(_, _, let selector, let value):
            try? pool.add(selector, value)
            emit(.node(event))
        case .succeeded(_, let nodeId, _, _, let result):
            completeNode(event, result: result, followBranch: graph.executionType(nodeId) == .branch)
        case .exception(_, let nodeId, _, _, let result, _):
            let strategy = graph.nodes[nodeId]?.base.errorStrategy
            completeNode(event, result: result, followBranch: strategy == .failBranch)
        case .failed(let x, let nodeId, let startAt, let finishedAt, let result, let message):
            exceptionsCount += 1
            addUsage(result.llmUsage)
            guard let node = graph.nodes[nodeId] else { return }
            let retries = retryCounts[nodeId] ?? 0
            if node.retryEnabled, retries < node.base.retryConfig.maxRetries {
                // ErrorHandler._handle_retry: wait the interval, then a retry event (the node stays unfinished).
                let interval = Double(node.base.retryConfig.retryInterval) / 1000
                let retryIndex = retries + 1
                Task {
                    if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
                    post.yield(.retryReady(event, retryIndex: retryIndex))
                }
                return
            }
            switch node.base.errorStrategy {
            case nil:
                // _handle_abort: the run fails with the node's error.
                if error == nil { error = message }
                emit(.node(event))
                unfinished.remove(nodeId)
            case .failBranch?:
                var r = NodeRunResult(status: .exception, inputs: result.inputs, processData: result.processData,
                                      outputs: ["error_message": .string(result.error), "error_type": .string(result.errorType)],
                                      metadata: [MetadataKey.errorStrategy: .string(ErrorStrategy.failBranch.rawValue)])
                r.edgeSourceHandle = "fail-branch"
                dispatch(.exception(executionId: x, nodeId: nodeId, startAt: startAt, finishedAt: finishedAt, result: r, error: message), post)
            case .defaultValue?:
                var outputs = node.base.defaultValueDict
                outputs["error_message"] = .string(result.error)
                outputs["error_type"] = .string(result.errorType)
                let r = NodeRunResult(status: .exception, inputs: result.inputs, processData: result.processData, outputs: outputs,
                                      metadata: [MetadataKey.errorStrategy: .string(ErrorStrategy.defaultValue.rawValue)])
                dispatch(.exception(executionId: x, nodeId: nodeId, startAt: startAt, finishedAt: finishedAt, result: r, error: message), post)
            }
        case .retry(_, let nodeId, _, _, _, _):
            retryCounts[nodeId, default: 0] += 1
            unfinished.remove(nodeId)
            emit(.node(event))
            enqueue(nodeId)
        }
    }

    /// `EventHandler._complete_node`.
    mutating func completeNode(_ event: GraphNodeEvent, result: NodeRunResult, followBranch: Bool) {
        let nodeId = event.nodeId
        addUsage(result.llmUsage)
        for (name, value) in result.outputs {
            if let type = result.outputTypes[name] { try? pool.add([nodeId, name], Segment(type, value)) } else { try? pool.add([nodeId, name], value) }
        }
        do {
            let edgeEvents: [GraphEngineEvent]
            if followBranch {
                edgeEvents = try handleBranchCompletion(nodeId, selectedHandle: result.edgeSourceHandle)
            } else if graph.executionType(nodeId) == .branch {
                edgeEvents = try handleBranchCompletion(nodeId, selectedHandle: nil)
            } else {
                edgeEvents = processTakenEdges(graph.outgoing(nodeId))
            }
            for e in edgeEvents { emit(e) }
            for id in pendingReady { enqueue(id) }
            pendingReady = []
        } catch {
            // The dispatcher's loop fails the run on unexpected errors.
            if self.error == nil { self.error = "\(error)" }
        }
        if graph.executionType(nodeId) == .response {
            // merge_response_outputs: answers concatenate, anything else is set.
            for (k, v) in result.outputs {
                if k == "answer", let existing = outputs["answer"], existing.isTruthy {
                    outputs["answer"] = .string(PythonText.str(existing) + PythonText.str(v))
                } else {
                    outputs[k] = v
                }
            }
        }
        unfinished.remove(nodeId)
        emit(.node(event))
    }

    mutating func addUsage(_ usage: LLMUsage) {
        guard usage.totalTokens > 0 else { return }
        llmUsage = llmUsage.totalTokens == 0 ? usage : llmUsage.plus(usage)
    }

    // MARK: Traversal (EdgeProcessor, SkipPropagator, GraphStateManager)

    struct BranchError: Error, CustomStringConvertible {
        var description: String
    }

    mutating func handleBranchCompletion(_ nodeId: String, selectedHandle: String?) throws -> [GraphEngineEvent] {
        guard let handle = selectedHandle, !handle.isEmpty else {
            throw BranchError(description: "Branch node \(nodeId) completed without selecting a branch")
        }
        let outgoing = graph.outgoing(nodeId)
        let selected = outgoing.filter { $0.sourceHandle == handle }
        let unselected = outgoing.filter { $0.sourceHandle != handle }
        var events: [GraphEngineEvent] = []
        for e in unselected { events += skipEdgePath(e) }
        events += processTakenEdges(selected)
        return events
    }

    mutating func processTakenEdges(_ edges: [RuntimeGraph.Edge]) -> [GraphEngineEvent] {
        var events: [GraphEngineEvent] = []
        var ready: [String] = []
        for e in edges {
            edgeStates[e.id] = .taken
            if isNodeReady(e.head) { ready.append(e.head) }
            events.append(.edgeTaken(e))
        }
        // The edge events are collected before the ready nodes are enqueued (as graphon's `_complete_node`).
        pendingReady += ready
        return events
    }

    /// Nodes a taken edge made ready, enqueued after the edge events are collected.
    var pendingReady: [String] = []

    func isNodeReady(_ nodeId: String) -> Bool {
        let incoming = graph.incoming(nodeId)
        if incoming.isEmpty { return true }
        if incoming.contains(where: { edgeStates[$0.id] == .unknown }) { return false }
        return incoming.contains { edgeStates[$0.id] == .taken }
    }

    mutating func skipEdgePath(_ edge: RuntimeGraph.Edge) -> [GraphEngineEvent] {
        edgeStates[edge.id] = .skipped
        return [.edgeSkipped(edge)] + propagateSkip(from: edge)
    }

    /// `propagate_skip_from_edge`.
    mutating func propagateSkip(from edge: RuntimeGraph.Edge) -> [GraphEngineEvent] {
        let incoming = graph.incoming(edge.head)
        let states = Set(incoming.map { edgeStates[$0.id] ?? .unknown })
        if states.contains(.unknown) { return [] }
        if states.contains(.taken) {
            enqueue(edge.head)
            return []
        }
        // all skipped
        nodeStates[edge.head] = .skipped
        var events: [GraphEngineEvent] = []
        for e in graph.outgoing(edge.head) { events += skipEdgePath(e) }
        return events
    }

    // MARK: Terminal events

    var stats: GraphRunStats {
        GraphRunStats(outputs: outputs, totalTokens: llmUsage.totalTokens, totalSteps: nodeRunSteps, llmUsage: llmUsage,
                      exceptionsCount: exceptionsCount)
    }

    /// `GraphEngine._emit_terminal_events` (+ `run()` turning an error into `GraphRunFailedEvent`).
    mutating func emitTerminal() {
        if aborted {
            emit(.runAborted(reason: error ?? "Workflow execution aborted by user command", stats))
        } else if let error {
            emit(.runFailed(error: error, stats))
        } else if exceptionsCount > 0 {
            emit(.runPartialSucceeded(stats))
        } else {
            emit(.runSucceeded(stats))
        }
    }
}

/// The engine, boxed for the dispatcher (a struct holding a struct with the same name reads badly).
struct RuntimeGraphEngineRef: Sendable {
    let value: GraphEngine
    init(_ value: GraphEngine) { self.value = value }
}
