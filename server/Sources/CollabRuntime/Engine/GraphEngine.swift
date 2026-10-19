// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/graph_engine/graph_engine.py,
// orchestration/dispatcher.py, worker.py, worker_management/worker_pool.py, event_management/event_handlers.py,
// graph_traversal/edge_processor.py, graph_traversal/skip_propagator.py, graph_state_manager.py, error_handler.py,
// frames.py, ready_queue/, domain/graph_execution.py, layers/execution_limits.py, command_processing/command_handlers.py,
// graphon/runtime/graph_runtime_state.py (outputs, usage, steps), graphon/graph_events/graph.py. Containers:
// container_handlers.py, iteration_container_handler.py, loop_container_handler.py, graphon/runtime/container_state.py.
// See ../NOTICE.md.
//
// Shape: graphon runs a dispatcher thread, a pool of worker threads and a generator that polls collected events. Here
// one dispatcher task owns all run state (no locks); ready tasks run as child tasks (at most `maxWorkers` at a time, in
// ready-queue order) and send their events to the dispatcher's mailbox; collected events pass the response stream
// filter at once and go to the run's stream. Each node reads a copy of its frame's pool taken when it starts (everything
// it can read is written before it is enqueued).
//
// Containers (graphon 0.7.0's frames): an iteration or loop node suspends with a frame request; the engine runs each
// round in a child frame (its own node and edge states, unfinished set, outputs, usage and steps; iteration rounds on a
// copy of the parent's pool with `item` / `index`, loop rounds on the parent's pool) whose tasks share the one ready
// queue, and resumes the container node with more rounds or its outcome (a resume task). Events from inside a frame
// carry the container's id (`NodeScope`, `iteration_id` / `loop_id` + index in result metadata); the start nodes of
// frames are not collected.
//
// Paused runs drain active work before serializing frames and streaming state. Layers other than execution limits are not ported.

import Foundation
import Synchronization

/// `GraphEngineConfig` + Dify's `WORKFLOW_MAX_EXECUTION_STEPS` / `_TIME`.
public struct GraphEngineConfig: Sendable {
    /// Dify's `GRAPH_ENGINE_MAX_WORKERS` (10): tasks running at once (node runs and container resumes).
    public var maxWorkers: Int
    /// `WORKFLOW_MAX_EXECUTION_STEPS` (500): started nodes, those inside containers too.
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
    /// `GraphRunStartedEvent(reason=RESUMPTION)`.
    case runResumed
    /// `GraphRunPausedEvent`: active work has drained; persist the snapshot before exposing the pause.
    case runPaused(reasons: [PauseReason], snapshot: GraphEngineSnapshot, GraphRunStats)
    /// A node event (started, chunks, variable updates, container progress, succeeded / failed / exception, retry).
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
        case .runSucceeded, .runPartialSucceeded, .runFailed, .runAborted, .runPaused: return true
        default: return false
        }
    }
}

/// The run's totals at its end (the root frame's `GraphRuntimeState`: outputs, `total_tokens`, `node_run_steps`,
/// `llm_usage`; nodes inside containers count in their container's usage, not in the steps).
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
    public func run(pool: VariablePool) -> AsyncStream<GraphEngineEvent> { stream(pool: pool, snapshot: nil) }

    /// Rebuild this engine from the run's saved graph, never the subsequently edited draft.
    public func resume(_ snapshot: GraphEngineSnapshot) throws -> AsyncStream<GraphEngineEvent> {
        guard snapshot.state.graph == graph.config.json, snapshot.state.rootId == graph.rootId else {
            throw GraphEngineSnapshot.Invalid(description: "Runtime snapshot does not match this graph")
        }
        return stream(pool: VariablePool(), snapshot: snapshot)
    }

    private func stream(pool: VariablePool, snapshot: GraphEngineSnapshot?) -> AsyncStream<GraphEngineEvent> {
        let (stream, out) = AsyncStream<GraphEngineEvent>.makeStream(bufferingPolicy: .unbounded)
        let engine = self
        Task {
            var dispatcher = Dispatcher(engine: engine, pool: pool, out: out, snapshot: snapshot)
            await dispatcher.execute()
            out.finish()
        }
        return stream
    }
}

// MARK: - Frames, tasks, container runs

/// `ROOT_FRAME_ID`.
let rootFrameId = "root"

/// `ExecutionFrame` + its `GraphStateManager` and `GraphRuntimeState` (outputs, usage, steps): one run of the graph from a
/// root — the whole run, or one iteration / loop round.
struct ExecutionFrame: Codable, Sendable {
    let id: String
    var nodeStates: [String: NodeState]
    var edgeStates: [String: NodeState]
    var unfinished = Set<String>()
    /// The frame whose pool this frame reads and writes (itself; a loop round: its parent's).
    let poolId: String
    var outputs = JSONObject()
    var llmUsage = LLMUsage.empty
    var nodeRunSteps = 0
    /// `ContainerFrameState` (nil: the root frame).
    var container: ContainerFrame?

    /// `GraphRuntimeState.add_llm_usage`.
    mutating func addUsage(_ usage: LLMUsage) {
        guard usage.totalTokens > 0 else { return }
        llmUsage = llmUsage.totalTokens == 0 ? usage : llmUsage.plus(usage)
    }

    /// `merge_response_outputs`: answers concatenate, anything else is set.
    mutating func mergeResponseOutputs(_ o: JSONObject) {
        for (k, v) in o {
            if k == "answer", let existing = outputs["answer"], existing.isTruthy {
                outputs["answer"] = .string(PythonText.str(existing) + PythonText.str(v))
            } else {
                outputs[k] = v
            }
        }
    }
}

/// `IterationFrameState` / `LoopFrameState`.
struct ContainerFrame: Codable, Sendable {
    var kind: ContainerKind
    var invocationId: String
    var index: Int
    var startedAt: Date
    var errors: [String] = []
    var reachedBreak = false
}

/// `IterationRunState`.
struct IterationRun: Codable, Sendable {
    let invocationId: String
    let frameId: String
    let nodeId: String
    let startedAt: Date
    let items: [JSONValue]
    let rootNodeId: String
    let outputSelector: [String]
    let errorHandleMode: ErrorHandleMode
    let flattenOutput: Bool
    let parallelNums: Int
    /// index -> the round's output (`None` = `.null`).
    var outputs: [Int: JSONValue] = [:]
    var durationMap = JSONObject()
    var usage = LLMUsage.empty
    var scheduledCount = 0
    var completedCount = 0
    var resumePending = false
    var errors: [String] = []
}

/// `LoopRunState`.
struct LoopRun: Sendable {
    let invocationId: String
    let frameId: String
    let nodeId: String
    let startedAt: Date
    let inputs: JSONObject
    var outputs: JSONObject
    let loopCount: Int
    let rootNodeId: String
    let loopVariableSelectors: [(key: String, selector: [String])]
    let loopNodeIds: Set<String>
    var durationMap = JSONObject()
    var variableMap = JSONObject()
    var usage = LLMUsage.empty
    var completedCount = 0
    var reachedBreak = false
}

/// `ContainerRunState`: one suspended container node.
enum ContainerRun: Codable, Sendable {
    case iteration(IterationRun)
    case loop(LoopRun)

    var frameId: String {
        switch self {
        case .iteration(let r): return r.frameId
        case .loop(let r): return r.frameId
        }
    }

    var nodeId: String {
        switch self {
        case .iteration(let r): return r.nodeId
        case .loop(let r): return r.nodeId
        }
    }

    var startedAt: Date {
        switch self {
        case .iteration(let r): return r.startedAt
        case .loop(let r): return r.startedAt
        }
    }
}

/// `StartTask` / `ResumeTask`.
enum ReadyTask: Codable, Sendable {
    case start(frameId: String, nodeId: String)
    case resume(invocationId: String, result: ContainerResult)
}

/// `(frame_id, node_id)`: the key of a node execution (`GraphExecution.node_executions`).
struct FrameNode: Hashable, Codable, Sendable {
    var frameId: String
    var nodeId: String
}

/// A message to the dispatcher's mailbox (graphon's event queue).
enum DispatchMessage: Sendable {
    /// `TaskEvent`.
    case node(frameId: String, GraphNodeEvent)
    /// `ContainerAwaitTask` (`invocationId` nil: the node's first request; the dispatcher creates its run state).
    case containerAwait(frameId: String, nodeId: String, invocationId: String?, request: ContainerRequest, startAt: Date)
    /// A task ended (the worker is free); a resumed container that did not suspend again is done.
    case taskDone(invocationId: String?, suspended: Bool)
    /// A failed node whose retry interval has passed (graphon sleeps in the error handler).
    case retryReady(frameId: String, GraphNodeEvent, retryIndex: Int)
    /// A command arrived.
    case wake
}

/// A container frame's bookkeeping failed (graphon's `TypeError` / `ValueError` in a container handler).
struct ContainerError: Error, CustomStringConvertible {
    var description: String
}

// MARK: - Dispatcher

/// The dispatcher and everything it owns (graphon's Dispatcher, EventHandler, FrameRegistry, GraphStateManagers,
/// EdgeProcessor, SkipPropagator, ErrorHandler, container handlers, GraphExecution, GraphRuntimeStates and the
/// execution limits layer).
struct Dispatcher {
    let engine: RuntimeGraphEngineRef
    let graph: RuntimeGraph
    let out: AsyncStream<GraphEngineEvent>.Continuation

    var frames: [String: ExecutionFrame] = [:]
    /// Pools by owning frame.
    var pools: [String: VariablePool] = [:]
    var readyQueue: [ReadyTask] = []
    var readyHead = 0
    var running = 0
    var containerRuns: [String: ContainerRun] = [:]

    // GraphExecution
    var executionIds: [FrameNode: String] = [:]
    var retryCounts: [FrameNode: Int] = [:]
    var exceptionsCount = 0
    var aborted = false
    var pauseReasons: [PauseReason] = []
    var pendingRetries = 0
    var resuming = false
    var error: String?

    // ExecutionLimitsLayer
    var limitSteps = 0
    var limitAbortSent = false
    let startedAt = ContinuousClock.now

    var filter: ResponseStreamFilter

    init(engine: GraphEngine, pool: VariablePool, out: AsyncStream<GraphEngineEvent>.Continuation, snapshot: GraphEngineSnapshot? = nil) {
        self.engine = RuntimeGraphEngineRef(engine)
        graph = engine.graph
        self.out = out
        var nodeStates: [String: NodeState] = [:], edgeStates: [String: NodeState] = [:]
        for id in graph.nodeIds { nodeStates[id] = graph.initiallySkippedNodes.contains(id) ? .skipped : .unknown }
        for id in graph.edgeIds { edgeStates[id] = graph.initiallySkippedEdges.contains(id) ? .skipped : .unknown }
        frames[rootFrameId] = ExecutionFrame(id: rootFrameId, nodeStates: nodeStates, edgeStates: edgeStates, poolId: rootFrameId)
        pools[rootFrameId] = pool
        filter = ResponseStreamFilter(graph: graph)
        if let snapshot {
            let state = snapshot.state
            frames = state.frames
            pools = state.pools
            readyQueue = state.ready
            containerRuns = state.containers
            executionIds = state.executionIds
            retryCounts = state.retryCounts
            exceptionsCount = state.exceptionsCount
            filter.restore(state.filter)
            resuming = true
        }
    }

    var config: GraphEngineConfig { engine.value.config }
    var root: ExecutionFrame { frames[rootFrameId]! }

    mutating func execute() async {
        let (mailbox, post) = AsyncStream<DispatchMessage>.makeStream(bufferingPolicy: .unbounded)
        engine.value.commands.attach { post.yield(.wake) }
        emit(resuming ? .runResumed : .runStarted)
        await withDiscardingTaskGroup { group in
            if !resuming { enqueue(rootFrameId, graph.rootId) }
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
        if !pauseReasons.isEmpty, !aborted, error == nil {
            // Flush first: the durable positions must include everything already delivered to the consumer.
            for e in filter.flush(state: filterState) { out.yield(e) }
            emit(.runPaused(reasons: pauseReasons, snapshot: GraphEngineSnapshot(self), stats))
        } else {
            emitTerminal()
            for e in filter.flush(state: filterState) { out.yield(e) }
        }
    }

    var shouldExit: Bool {
        aborted || error != nil || root.unfinished.isEmpty || (!pauseReasons.isEmpty && running == 0 && pendingRetries == 0)
    }

    var filterState: ResponseStreamFilter.State { .init(pool: pools[rootFrameId]!, nodeStates: root.nodeStates) }

    /// `EventManager.collect`: through the response stream filter to the stream; the execution limits layer sees it.
    mutating func emit(_ event: GraphEngineEvent) {
        for e in filter.onEvent(event, state: filterState) { out.yield(e) }
        limitsOnEvent(event)
    }

    // MARK: Ready queue and workers

    /// `GraphStateManager.enqueue_node`.
    mutating func enqueue(_ frameId: String, _ nodeId: String) {
        frames[frameId]!.nodeStates[nodeId] = .taken
        frames[frameId]!.unfinished.insert(nodeId)
        readyQueue.append(.start(frameId: frameId, nodeId: nodeId))
    }

    /// `enqueue_ready_task(ResumeTask(...))`.
    mutating func enqueueResume(_ invocationId: String, _ result: ContainerResult) {
        readyQueue.append(.resume(invocationId: invocationId, result: result))
    }

    func executionId(_ key: FrameNode) -> String? { executionIds[key] }

    /// `get_or_create_node_execution(frame_id, node_id).execution_id`.
    mutating func bindExecutionId(_ key: FrameNode) -> String {
        if let x = executionIds[key] { return x }
        let x = UUID().uuidString.lowercased()
        executionIds[key] = x
        return x
    }

    mutating func popReady() -> ReadyTask? {
        guard readyHead < readyQueue.count else { return nil }
        let t = readyQueue[readyHead]
        readyHead += 1
        if readyHead > 256, readyHead * 2 > readyQueue.count {
            readyQueue.removeFirst(readyHead)
            readyHead = 0
        }
        return t
    }

    mutating func launchReady(_ group: inout DiscardingTaskGroup, _ post: AsyncStream<DispatchMessage>.Continuation) {
        guard pauseReasons.isEmpty else { return }
        while running < config.maxWorkers, let task = popReady() {
            switch task {
            case .start(let frameId, let nodeId):
                guard let node = graph.nodes[nodeId], let frame = frames[frameId] else { continue }
                frames[frameId]!.nodeStates[nodeId] = .taken
                let executionId = bindExecutionId(FrameNode(frameId: frameId, nodeId: nodeId))
                running += 1
                let context = nodeContext(pools[frame.poolId] ?? VariablePool())
                group.addTask {
                    let suspended = SuspendFlag()
                    await NodeRunner.run(node, executionId: executionId, context: context, emit: { event in post.yield(.node(frameId: frameId, event)) },
                                         onAwait: { request, startAt in
                                             suspended.set()
                                             post.yield(.containerAwait(frameId: frameId, nodeId: nodeId, invocationId: nil, request: request,
                                                                        startAt: startAt))
                                         })
                    post.yield(.taskDone(invocationId: nil, suspended: suspended.value))
                }
            case .resume(let invocationId, let result):
                guard let run = containerRuns[invocationId], let node = graph.nodes[run.nodeId], let frame = frames[run.frameId] else { continue }
                let frameId = run.frameId, nodeId = run.nodeId
                let executionId = bindExecutionId(FrameNode(frameId: frameId, nodeId: nodeId))
                running += 1
                let context = nodeContext(pools[frame.poolId] ?? VariablePool())
                let startAt = run.startedAt
                group.addTask {
                    let suspended = SuspendFlag()
                    await NodeRunner.resume(node, executionId: executionId, startAt: startAt, result: result, context: context,
                                            emit: { event in post.yield(.node(frameId: frameId, event)) },
                                            onAwait: { request, startAt in
                                                suspended.set()
                                                post.yield(.containerAwait(frameId: frameId, nodeId: nodeId, invocationId: invocationId,
                                                                           request: request, startAt: startAt))
                                            })
                    post.yield(.taskDone(invocationId: invocationId, suspended: suspended.value))
                }
            }
        }
    }

    func nodeContext(_ pool: VariablePool) -> NodeRunContext {
        NodeRunContext(pool: pool, userId: engine.value.userId, appId: engine.value.appId,
                       isAborted: { [commands = engine.value.commands] in commands.pendingAbort != nil || Task.isCancelled })
    }

    // MARK: Commands and limits

    mutating func processCommands() {
        if let reason = engine.value.commands.pendingAbort, !aborted {
            // GraphExecution.abort
            aborted = true
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

    // MARK: Messages (Dispatcher._dispatch_task)

    mutating func handle(_ message: DispatchMessage, _ post: AsyncStream<DispatchMessage>.Continuation) {
        switch message {
        case .wake:
            processCommands()
        case .taskDone(let invocationId, let suspended):
            running -= 1
            // The worker pops a resumed container's run once its node finished.
            if let invocationId, !suspended { containerRuns[invocationId] = nil }
        case .retryReady(let frameId, let failed, let retryIndex):
            pendingRetries -= 1
            guard frames[frameId] != nil, case .failed(let x, let nodeId, let startAt, _, let result, let error) = failed else { return }
            dispatchEvent(frameId, .retry(executionId: x, nodeId: nodeId, startAt: startAt, result: result, error: error, retryIndex: retryIndex), post)
            completeFrameIfContainer(frameId)
        case .containerAwait(let frameId, let nodeId, let invocationId, let request, let startAt):
            startContainer(frameId: frameId, nodeId: nodeId, invocationId: invocationId, request: request, startAt: startAt)
        case .node(let frameId, let event):
            guard frames[frameId] != nil else { return }
            dispatchEvent(frameId, event, post)
            completeFrameIfContainer(frameId)
            // Dispatcher._process_commands: after result events (and when idle).
            if event.result != nil { processCommands() }
        }
    }

    /// `EventHandler.dispatch`'s tail: the innermost container handler completes the frame once nothing in it is unfinished.
    mutating func completeFrameIfContainer(_ frameId: String) {
        guard let frame = frames[frameId], let container = frame.container, frame.unfinished.isEmpty else { return }
        switch container.kind {
        case .iteration: completeIterationFrame(frameId)
        case .loop: completeLoopFrame(frameId)
        }
    }

    // MARK: Event handling (EventHandler)

    /// `_dispatch_event`: every container frame around the event's frame prepares it (scope, metadata, loop end), then it
    /// is handled.
    mutating func dispatchEvent(_ frameId: String, _ event: GraphNodeEvent, _ post: AsyncStream<DispatchMessage>.Continuation) {
        var e = event
        var current = frameId
        while current != rootFrameId, let frame = frames[current], let container = frame.container {
            guard let run = containerRuns[container.invocationId] else { break }
            prepareFrameEvent(current, container, run, &e)
            current = run.frameId
        }
        dispatch(frameId, e, post)
    }

    /// `IterationContainerHandler.prepare_frame_event` / `LoopContainerHandler.prepare_frame_event`.
    mutating func prepareFrameEvent(_ frameId: String, _ container: ContainerFrame, _ run: ContainerRun, _ e: inout GraphNodeEvent) {
        let (idKey, indexKey) = container.kind == .iteration ? (MetadataKey.iterationId, MetadataKey.iterationIndex)
                                                             : (MetadataKey.loopId, MetadataKey.loopIndex)
        func tag(_ r: NodeRunResult) -> NodeRunResult {
            guard r.metadata[idKey] == nil else { return r }
            var r = r
            r.metadata[idKey] = .string(run.nodeId)
            r.metadata[indexKey] = .int(container.index)
            return r
        }
        switch e {
        case .started(let x, let n, let t, let title, let at, var scope):
            if container.kind == .iteration { if scope.iterationId == nil { scope.iterationId = run.nodeId } } else if scope.loopId == nil {
                scope.loopId = run.nodeId
            }
            e = .started(executionId: x, nodeId: n, nodeType: t, title: title, startAt: at, scope: scope)
        case .succeeded(let x, let n, let a, let b, let r):
            e = .succeeded(executionId: x, nodeId: n, startAt: a, finishedAt: b, result: tag(r))
            if container.kind == .loop, graph.nodes[n]?.nodeType == NodeType.loopEnd, case .loop(let loop) = run, loop.loopNodeIds.contains(n) {
                frames[frameId]?.container?.reachedBreak = true
            }
        case .failed(let x, let n, let a, let b, let r, let err):
            e = .failed(executionId: x, nodeId: n, startAt: a, finishedAt: b, result: tag(r), error: err)
        case .exception(let x, let n, let a, let b, let r, let err):
            e = .exception(executionId: x, nodeId: n, startAt: a, finishedAt: b, result: tag(r), error: err)
        case .retry(let x, let n, let a, let r, let err, let i):
            e = .retry(executionId: x, nodeId: n, startAt: a, result: tag(r), error: err, retryIndex: i)
        default:
            break
        }
    }

    /// `_collect`: inside a container frame, the frame's start node is not collected (`should_collect`).
    mutating func collect(_ frameId: String, _ event: GraphNodeEvent) {
        if let container = frames[frameId]?.container {
            let type = graph.nodes[event.nodeId]?.nodeType
            if container.kind == .iteration, type == NodeType.iterationStart { return }
            if container.kind == .loop, type == NodeType.loopStart { return }
        }
        emit(.node(event))
    }

    mutating func dispatch(_ frameId: String, _ event: GraphNodeEvent, _ post: AsyncStream<DispatchMessage>.Continuation) {
        let key = FrameNode(frameId: frameId, nodeId: event.nodeId)
        switch event {
        case .pauseRequested(_, let nodeId, let reason):
            pauseReasons.append(reason)
            frames[frameId]!.nodeStates[nodeId] = .unknown
            readyQueue.append(.start(frameId: frameId, nodeId: nodeId))
            collect(frameId, event)
        case .started:
            // Retries run silently: only the first attempt's started event is collected.
            frames[frameId]!.nodeRunSteps += 1
            if (retryCounts[key] ?? 0) == 0 { collect(frameId, event) }
        case .streamChunk, .reasoningChunk, .retrieverResource, .containerStarted, .containerNext, .containerCompleted:
            collect(frameId, event)
        case .variableUpdated(_, _, let selector, let value):
            if let poolId = frames[frameId]?.poolId { try? pools[poolId]?.add(selector, value) }
            collect(frameId, event)
        case .succeeded(_, let nodeId, _, _, let result):
            completeNode(frameId, event, result: result, followBranch: graph.executionType(nodeId) == .branch)
        case .exception(_, let nodeId, _, _, let result, _):
            let strategy = graph.nodes[nodeId]?.base.errorStrategy
            completeNode(frameId, event, result: result, followBranch: strategy == .failBranch)
        case .failed(let x, let nodeId, let startAt, let finishedAt, let result, let message):
            exceptionsCount += 1
            frames[frameId]!.addUsage(result.llmUsage)
            guard let node = graph.nodes[nodeId] else { return }
            let retries = retryCounts[key] ?? 0
            if node.retryEnabled, retries < node.base.retryConfig.maxRetries {
                // ErrorHandler._handle_retry: wait the interval, then a retry event (the node stays unfinished).
                let interval = Double(node.base.retryConfig.retryInterval) / 1000
                let retryIndex = retries + 1
                pendingRetries += 1
                Task {
                    if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
                    post.yield(.retryReady(frameId: frameId, event, retryIndex: retryIndex))
                }
                return
            }
            switch node.base.errorStrategy {
            case nil:
                // _handle_abort: inside a container the frame records the failure, else the run fails with the node's error.
                if frames[frameId]!.container != nil {
                    frames[frameId]!.container!.errors.append(message)
                } else if error == nil {
                    error = message
                }
                collect(frameId, event)
                frames[frameId]!.unfinished.remove(nodeId)
            case .failBranch?:
                var r = NodeRunResult(status: .exception, inputs: result.inputs, processData: result.processData,
                                      outputs: ["error_message": .string(result.error), "error_type": .string(result.errorType)],
                                      metadata: [MetadataKey.errorStrategy: .string(ErrorStrategy.failBranch.rawValue)])
                r.edgeSourceHandle = "fail-branch"
                dispatchEvent(frameId, .exception(executionId: x, nodeId: nodeId, startAt: startAt, finishedAt: finishedAt, result: r, error: message), post)
            case .defaultValue?:
                var outputs = node.base.defaultValueDict
                outputs["error_message"] = .string(result.error)
                outputs["error_type"] = .string(result.errorType)
                let r = NodeRunResult(status: .exception, inputs: result.inputs, processData: result.processData, outputs: outputs,
                                      metadata: [MetadataKey.errorStrategy: .string(ErrorStrategy.defaultValue.rawValue)])
                dispatchEvent(frameId, .exception(executionId: x, nodeId: nodeId, startAt: startAt, finishedAt: finishedAt, result: r, error: message), post)
            }
        case .retry(_, let nodeId, _, _, _, _):
            retryCounts[key, default: 0] += 1
            frames[frameId]!.unfinished.remove(nodeId)
            collect(frameId, event)
            enqueue(frameId, nodeId)
        }
    }

    /// `EventHandler._complete_node`.
    mutating func completeNode(_ frameId: String, _ event: GraphNodeEvent, result: NodeRunResult, followBranch: Bool) {
        let nodeId = event.nodeId
        frames[frameId]!.addUsage(result.llmUsage)
        let poolId = frames[frameId]!.poolId
        for (name, value) in result.outputs {
            if let type = result.outputTypes[name] { try? pools[poolId]?.add([nodeId, name], Segment(type, value)) } else {
                try? pools[poolId]?.add([nodeId, name], value)
            }
        }
        do {
            var traversal = Traversal(graph: graph, frame: frames[frameId]!)
            if followBranch {
                try traversal.handleBranchCompletion(nodeId, selectedHandle: result.edgeSourceHandle)
            } else if graph.executionType(nodeId) == .branch {
                try traversal.handleBranchCompletion(nodeId, selectedHandle: nil)
            } else {
                traversal.processTakenEdges(graph.outgoing(nodeId))
            }
            frames[frameId]!.nodeStates = traversal.frame.nodeStates
            frames[frameId]!.edgeStates = traversal.frame.edgeStates
            // Skip propagation may enqueue nodes; taken edges make nodes ready: both after the edge events are collected.
            for e in traversal.events { emit(e) }
            for id in traversal.ready { enqueue(frameId, id) }
        } catch {
            // The dispatcher's loop fails the run on unexpected errors.
            if self.error == nil { self.error = "\(error)" }
        }
        if graph.executionType(nodeId) == .response { frames[frameId]!.mergeResponseOutputs(result.outputs) }
        frames[frameId]!.unfinished.remove(nodeId)
        collect(frameId, event)
    }

    // MARK: Containers (EventHandler.start_container, the container handlers)

    /// `EventHandler.start_container` (+ the worker creating the run state on a node's first request).
    mutating func startContainer(frameId: String, nodeId: String, invocationId: String?, request: ContainerRequest, startAt: Date) {
        let invocation: String
        if let invocationId { invocation = invocationId } else {
            invocation = UUID().uuidString.lowercased()
            switch request {
            case .iteration(let r):
                containerRuns[invocation] = .iteration(IterationRun(
                    invocationId: invocation, frameId: frameId, nodeId: nodeId, startedAt: startAt, items: r.items, rootNodeId: r.rootNodeId,
                    outputSelector: r.outputSelector, errorHandleMode: r.errorHandleMode, flattenOutput: r.flattenOutput, parallelNums: r.parallelNums))
            case .loop(let r):
                containerRuns[invocation] = .loop(LoopRun(
                    invocationId: invocation, frameId: frameId, nodeId: nodeId, startedAt: startAt, inputs: r.inputs, outputs: r.outputs,
                    loopCount: r.loopCount, rootNodeId: r.rootNodeId, loopVariableSelectors: r.loopVariableSelectors, loopNodeIds: r.loopNodeIds))
            }
        }
        switch (containerRuns[invocation], request) {
        case (.iteration?, .iteration(let r)): iterationStartAwait(invocation, r)
        case (.loop?, .loop(let r)): loopStartAwait(invocation, r)
        default:
            let result = NodeRunResult(status: .failed, error: "container handler cannot handle \(request.kind.rawValue) request",
                                       errorType: "TypeError")
            enqueueResume(invocation, .finished(ContainerExecutionResult(metadata: [:], steps: 0, result: result)))
        }
    }

    /// `_root_runtime_state().put_container_run`.
    mutating func putIteration(_ run: IterationRun) { containerRuns[run.invocationId] = .iteration(run) }
    mutating func putLoop(_ run: LoopRun) { containerRuns[run.invocationId] = .loop(run) }

    func iterationRun(_ invocation: String) -> IterationRun? {
        if case .iteration(let r)? = containerRuns[invocation] { return r }
        return nil
    }

    func loopRun(_ invocation: String) -> LoopRun? {
        if case .loop(let r)? = containerRuns[invocation] { return r }
        return nil
    }

    /// `FrameRegistry.remove` + `pop_container_frame`.
    mutating func removeFrame(_ frameId: String) {
        guard let frame = frames.removeValue(forKey: frameId) else { return }
        if frame.poolId == frameId { pools[frameId] = nil }
        executionIds = executionIds.filter { $0.key.frameId != frameId }
        retryCounts = retryCounts.filter { $0.key.frameId != frameId }
    }

    /// A child frame over the whole graph from `rootNodeId`: nothing taken or skipped yet.
    mutating func materializeChildFrame(_ id: String, poolId: String, container: ContainerFrame) {
        var nodeStates: [String: NodeState] = [:], edgeStates: [String: NodeState] = [:]
        for n in graph.nodeIds { nodeStates[n] = .unknown }
        for e in graph.edgeIds { edgeStates[e] = .unknown }
        frames[id] = ExecutionFrame(id: id, nodeStates: nodeStates, edgeStates: edgeStates, poolId: poolId, container: container)
    }

    // MARK: Iteration (IterationContainerHandler)

    /// `start_container`'s failure path: the handler raised (here: a frame's root is not in the graph, which
    /// `FrameRegistry.materialize_child_frame` raises as `Graph.init` does); the container node fails with the error.
    mutating func failContainerStart(_ invocation: String, _ error: String) {
        let result = NodeRunResult(status: .failed, error: error, errorType: "ValueError")
        enqueueResume(invocation, .finished(ContainerExecutionResult(metadata: [:], steps: 0, result: result)))
    }

    func missingRoot(_ rootNodeId: String) -> String? {
        graph.nodes[rootNodeId] == nil ? "Root node id \(rootNodeId) not found in the graph" : nil
    }

    mutating func iterationStartAwait(_ invocation: String, _ request: IterationFrameRequest) {
        guard var run = iterationRun(invocation) else { return }
        run.resumePending = false
        putIteration(run)
        if finishFailedIterationIfReady(run) { return }
        if !request.indexes.isEmpty, let error = missingRoot(run.rootNodeId) {
            run.scheduledCount = max(run.scheduledCount, request.indexes[0] + 1)
            putIteration(run)
            failContainerStart(invocation, error)
            return
        }
        for index in request.indexes {
            run.scheduledCount = max(run.scheduledCount, index + 1)
            putIteration(run)
            startIterationFrame(run, index: index)
        }
        requestIterationFrames(run)
    }

    mutating func startIterationFrame(_ run: IterationRun, index: Int) {
        guard let parent = frames[run.frameId] else { return }
        var pool = pools[parent.poolId] ?? VariablePool()
        try? pool.add([run.nodeId, "index"], .int(index))
        try? pool.add([run.nodeId, "item"], run.items[index])
        let childId = "\(run.invocationId):iteration:\(index)"
        pools[childId] = pool
        materializeChildFrame(childId, poolId: childId,
                              container: ContainerFrame(kind: .iteration, invocationId: run.invocationId, index: index, startedAt: .now))
        enqueue(childId, run.rootNodeId)
    }

    mutating func completeIterationFrame(_ frameId: String) {
        guard let frame = frames[frameId], let container = frame.container, var run = iterationRun(container.invocationId) else { return }
        if let error = container.errors.first {
            run = completeIterationStep(frame, container, run, output: .null, store: run.errorHandleMode == .continueOnError)
            switch run.errorHandleMode {
            case .terminated:
                run.errors.append(error)
                putIteration(run)
                _ = finishFailedIterationIfReady(run)
            case .continueOnError, .removeAbnormalOutput:
                continueOrCompleteIteration(run)
            }
        } else {
            let output = pools[frame.poolId]?.get(run.outputSelector)?.value ?? .null
            run = completeIterationStep(frame, container, run, output: output, store: true)
            continueOrCompleteIteration(run)
        }
        removeFrame(frameId)
    }

    mutating func completeIterationStep(_ frame: ExecutionFrame, _ container: ContainerFrame, _ run: IterationRun, output: JSONValue,
                                        store: Bool) -> IterationRun {
        var run = run
        run.durationMap[String(container.index)] = .double(max(0, Date().timeIntervalSince(container.startedAt)))
        if store { run.outputs[container.index] = output }
        if container.errors.isEmpty, container.index == run.items.count - 1 {
            frames[run.frameId]?.mergeResponseOutputs(frame.outputs)
        }
        run.usage = run.usage.plus(frame.llmUsage)
        run.completedCount += 1
        putIteration(run)
        return run
    }

    mutating func continueOrCompleteIteration(_ run: IterationRun) {
        if finishFailedIterationIfReady(run) { return }
        if run.completedCount >= run.items.count {
            enqueueResume(run.invocationId, .finished(buildIterationResult(run, status: .succeeded)))
            return
        }
        requestIterationFrames(run)
    }

    mutating func finishFailedIterationIfReady(_ run: IterationRun) -> Bool {
        guard let error = run.errors.first else { return false }
        if run.completedCount < run.scheduledCount || run.resumePending { return true }
        var run = run
        run.resumePending = true
        putIteration(run)
        enqueueResume(run.invocationId, .finished(buildIterationResult(run, status: .failed, error: error)))
        return true
    }

    mutating func requestIterationFrames(_ run: IterationRun) {
        if run.resumePending || run.scheduledCount >= run.items.count { return }
        let active = run.scheduledCount - run.completedCount
        let capacity = max(run.parallelNums - active, 0)
        if capacity == 0 { return }
        let end = min(run.items.count, run.scheduledCount + capacity)
        var run = run
        run.resumePending = true
        putIteration(run)
        enqueueResume(run.invocationId, .request(.iteration(IterationFrameRequest(
            items: run.items, rootNodeId: run.rootNodeId, indexes: Array(run.scheduledCount..<end), outputSelector: run.outputSelector,
            errorHandleMode: run.errorHandleMode, flattenOutput: run.flattenOutput, parallelNums: run.parallelNums))))
    }

    func buildIterationResult(_ run: IterationRun, status: NodeExecutionStatus, error: String = "") -> ContainerExecutionResult {
        let ordered = run.outputs.keys.sorted().map { run.outputs[$0]! }
        let outputs: JSONObject = ["output": .array(Self.flatten(ordered, enabled: run.flattenOutput))]
        let metadata: JSONObject = [MetadataKey.totalTokens: .int(run.usage.totalTokens), MetadataKey.totalPrice: .string(run.usage.totalPrice.text),
                                    MetadataKey.currency: .string(run.usage.currency), MetadataKey.iterationDurationMap: .object(run.durationMap)]
        var result = NodeRunResult(status: status, inputs: ["iterator_selector": .array(run.items)], outputs: outputs, metadata: metadata,
                                   llmUsage: run.usage, error: error)
        result.errorType = ""
        return ContainerExecutionResult(metadata: metadata, steps: run.items.count, result: result)
    }

    /// `_flatten_outputs_if_needed`: when every non-null output is a list, one list of their items (nulls dropped).
    static func flatten(_ outputs: [JSONValue], enabled: Bool) -> [JSONValue] {
        guard enabled else { return outputs }
        let nonEmpty = outputs.filter { $0 != .null }
        if nonEmpty.isEmpty { return outputs }
        guard nonEmpty.allSatisfy({ $0.array != nil }) else { return outputs }
        var flat: [JSONValue] = []
        for o in outputs {
            if let a = o.array { flat += a } else if o != .null { flat.append(o) }
        }
        return flat
    }

    // MARK: Loop (LoopContainerHandler)

    func loopNode(_ run: LoopRun) -> LoopNode? { graph.nodes[run.nodeId] as? LoopNode }

    /// `_loop_break_conditions_reached` over the pool of the loop's frame.
    func breakConditionsReached(_ run: LoopRun) throws -> Bool {
        guard let node = loopNode(run), !node.breakConditions.isEmpty, let parent = frames[run.frameId] else { return false }
        return try ConditionProcessor.process(pool: pools[parent.poolId] ?? VariablePool(), conditions: node.breakConditions,
                                              logicalOperator: node.logicalOperator).finalResult
    }

    mutating func loopStartAwait(_ invocation: String, _ request: LoopFrameRequest) {
        guard var run = loopRun(invocation), let parent = frames[run.frameId] else { return }
        for (selector, value) in request.initialVariables { try? pools[parent.poolId]?.add(selector, value) }
        if (try? breakConditionsReached(run)) == true {
            run.reachedBreak = true
            putLoop(run)
            enqueueResume(invocation, .finished(completeLoop(run, steps: 0)))
            return
        }
        // _start_loop_frame: the inner nodes' values of the last round go; the round shares the parent's pool.
        for nodeId in request.loopNodeIds { pools[parent.poolId]?.remove([nodeId]) }
        if let error = missingRoot(request.rootNodeId) {
            failContainerStart(invocation, error)
            return
        }
        let childId = "\(invocation):loop:\(request.index)"
        materializeChildFrame(childId, poolId: parent.poolId,
                              container: ContainerFrame(kind: .loop, invocationId: invocation, index: request.index, startedAt: .now))
        enqueue(childId, request.rootNodeId)
    }

    mutating func completeLoopFrame(_ frameId: String) {
        guard let frame = frames[frameId], let container = frame.container, let run = loopRun(container.invocationId) else { return }
        do {
            try completeReadyLoopFrame(frame, container, run)
        } catch {
            enqueueResume(run.invocationId, .finished(failLoop(loopRun(run.invocationId) ?? run, error: "\(error)")))
        }
        removeFrame(frameId)
    }

    mutating func completeReadyLoopFrame(_ frame: ExecutionFrame, _ container: ContainerFrame, _ run: LoopRun) throws {
        var run = try completeLoopStep(frame, container, run)
        if let error = container.errors.first {
            enqueueResume(run.invocationId, .finished(failLoop(run, error: error)))
            return
        }
        if container.reachedBreak {
            run.reachedBreak = true
            putLoop(run)
        } else if try breakConditionsReached(run) {
            run.reachedBreak = true
            putLoop(run)
        }
        if run.reachedBreak || run.completedCount >= run.loopCount {
            enqueueResume(run.invocationId, .finished(completeLoop(run, steps: run.loopCount)))
            return
        }
        enqueueResume(run.invocationId, .request(.loop(LoopFrameRequest(
            inputs: run.inputs, outputs: run.outputs, loopCount: run.loopCount, rootNodeId: run.rootNodeId,
            loopVariableSelectors: run.loopVariableSelectors, loopNodeIds: run.loopNodeIds, index: run.completedCount))))
    }

    mutating func completeLoopStep(_ frame: ExecutionFrame, _ container: ContainerFrame, _ run: LoopRun) throws -> LoopRun {
        var values = JSONObject()
        let pool = pools[frame.poolId] ?? VariablePool()
        for (key, selector) in run.loopVariableSelectors {
            guard let segment = pool.get(selector) else { throw ContainerError(description: "loop variable \(key) is missing") }
            values[key] = segment.value
        }
        var run = run
        run.completedCount += 1
        run.usage = run.usage.plus(frame.llmUsage)
        run.durationMap[String(container.index)] = .double(max(0, Date().timeIntervalSince(container.startedAt)))
        run.variableMap[String(container.index)] = .object(values)
        if container.errors.isEmpty { frames[run.frameId]?.mergeResponseOutputs(frame.outputs) }
        for (k, v) in values { run.outputs[k] = v }
        run.outputs["loop_round"] = .int(container.index + 1)
        putLoop(run)
        return run
    }

    func loopMetadata(_ run: LoopRun) -> JSONObject {
        [MetadataKey.totalTokens: .int(run.usage.totalTokens), MetadataKey.totalPrice: .string(run.usage.totalPrice.text),
         MetadataKey.currency: .string(run.usage.currency), MetadataKey.loopDurationMap: .object(run.durationMap),
         MetadataKey.loopVariableMap: .object(run.variableMap)]
    }

    func completeLoop(_ run: LoopRun, steps: Int) -> ContainerExecutionResult {
        let metadata = loopMetadata(run)
        var eventMetadata = metadata
        eventMetadata[MetadataKey.completedReason] = run.reachedBreak ? "loop_break" : "loop_completed"
        let result = NodeRunResult(status: .succeeded, inputs: run.inputs, outputs: run.outputs, metadata: metadata, llmUsage: run.usage)
        return ContainerExecutionResult(metadata: eventMetadata, steps: steps, result: result)
    }

    func failLoop(_ run: LoopRun, error: String) -> ContainerExecutionResult {
        let metadata = loopMetadata(run)
        var eventMetadata = metadata
        eventMetadata[MetadataKey.completedReason] = "error"
        let result = NodeRunResult(status: .failed, inputs: run.inputs, metadata: metadata, llmUsage: run.usage, error: error)
        return ContainerExecutionResult(metadata: eventMetadata, steps: run.loopCount, result: result)
    }

    // MARK: Terminal events

    var stats: GraphRunStats {
        let r = root
        return GraphRunStats(outputs: r.outputs, totalTokens: r.llmUsage.totalTokens, totalSteps: r.nodeRunSteps, llmUsage: r.llmUsage,
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

/// Graph traversal over one frame's node and edge states (`EdgeProcessor`, `SkipPropagator`, the frame's
/// `GraphStateManager`): the edge events to collect and the nodes made ready, in graphon's order.
struct Traversal {
    let graph: RuntimeGraph
    var frame: ExecutionFrame
    var events: [GraphEngineEvent] = []
    /// Nodes to enqueue after the edge events are collected (skip propagation's first, as graphon enqueues them while it
    /// walks).
    var ready: [String] = []

    init(graph: RuntimeGraph, frame: ExecutionFrame) {
        self.graph = graph
        self.frame = frame
    }

    struct BranchError: Error, CustomStringConvertible {
        var description: String
    }

    mutating func handleBranchCompletion(_ nodeId: String, selectedHandle: String?) throws {
        guard let handle = selectedHandle, !handle.isEmpty else {
            throw BranchError(description: "Branch node \(nodeId) completed without selecting a branch")
        }
        let outgoing = graph.outgoing(nodeId)
        let selected = outgoing.filter { $0.sourceHandle == handle }
        let unselected = outgoing.filter { $0.sourceHandle != handle }
        for e in unselected { skipEdgePath(e) }
        processTakenEdges(selected)
    }

    mutating func processTakenEdges(_ edges: [RuntimeGraph.Edge]) {
        var readyNow: [String] = []
        for e in edges {
            frame.edgeStates[e.id] = .taken
            if isNodeReady(e.head) { readyNow.append(e.head) }
            events.append(.edgeTaken(e))
        }
        ready += readyNow
    }

    func isNodeReady(_ nodeId: String) -> Bool {
        let incoming = graph.incoming(nodeId)
        if incoming.isEmpty { return true }
        if incoming.contains(where: { frame.edgeStates[$0.id] == .unknown }) { return false }
        return incoming.contains { frame.edgeStates[$0.id] == .taken }
    }

    mutating func skipEdgePath(_ edge: RuntimeGraph.Edge) {
        frame.edgeStates[edge.id] = .skipped
        events.append(.edgeSkipped(edge))
        propagateSkip(from: edge)
    }

    /// `propagate_skip_from_edge`.
    mutating func propagateSkip(from edge: RuntimeGraph.Edge) {
        let incoming = graph.incoming(edge.head)
        let states = Set(incoming.map { frame.edgeStates[$0.id] ?? .unknown })
        if states.contains(.unknown) { return }
        if states.contains(.taken) {
            frame.nodeStates[edge.head] = .taken
            ready.append(edge.head)
            return
        }
        // all skipped
        frame.nodeStates[edge.head] = .skipped
        for e in graph.outgoing(edge.head) { skipEdgePath(e) }
    }
}

/// Whether a node task suspended (set from its await handler, read after its run returns).
final class SuspendFlag: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

/// The engine, boxed for the dispatcher (a struct holding a struct with the same name reads badly).
struct RuntimeGraphEngineRef: Sendable {
    let value: GraphEngine
    init(_ value: GraphEngine) { self.value = value }
}
