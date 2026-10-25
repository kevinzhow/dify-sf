// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/enums.py,
// graphon/node_events/base.py, node.py, iteration.py and loop.py, graphon/graph_events/node.py, iteration.py and loop.py,
// graphon/nodes/container_effects.py. See NOTICE.md.

import Foundation

/// Built-in node types (`BuiltinNodeTypes`; node types are plain strings).
public enum NodeType {
    public static let start = "start"
    public static let end = "end"
    public static let answer = "answer"
    public static let llm = "llm"
    public static let knowledgeRetrieval = "knowledge-retrieval"
    public static let ifElse = "if-else"
    public static let code = "code"
    public static let templateTransform = "template-transform"
    public static let questionClassifier = "question-classifier"
    public static let httpRequest = "http-request"
    public static let tool = "tool"
    public static let datasource = "datasource"
    public static let variableAggregator = "variable-aggregator"
    public static let legacyVariableAggregator = "variable-assigner"
    public static let loop = "loop"
    public static let loopStart = "loop-start"
    public static let loopEnd = "loop-end"
    public static let iteration = "iteration"
    public static let iterationStart = "iteration-start"
    public static let parameterExtractor = "parameter-extractor"
    public static let variableAssigner = "assigner"
    public static let documentExtractor = "document-extractor"
    public static let listOperator = "list-operator"
    public static let humanInput = "human-input"
    /// Dify's start-like nodes (`is_start_node_type`): user input start and the triggers.
    public static let startTypes: Set<String> = ["start", "datasource", "trigger-webhook", "trigger-schedule", "trigger-plugin"]
}

/// `WorkflowNodeExecutionStatus`.
public enum NodeExecutionStatus: String, Sendable, Hashable, Codable {
    case pending, running, succeeded, failed, exception, stopped, paused, retry
}

/// `ErrorStrategy`.
public enum ErrorStrategy: String, Sendable, Hashable {
    case failBranch = "fail-branch"
    case defaultValue = "default-value"
}

/// `WorkflowNodeExecutionMetadataKey` values used so far.
public enum MetadataKey {
    public static let totalTokens = "total_tokens"
    public static let totalPrice = "total_price"
    public static let currency = "currency"
    public static let errorStrategy = "error_strategy"
    public static let iterationId = "iteration_id"
    public static let iterationIndex = "iteration_index"
    public static let loopId = "loop_id"
    public static let loopIndex = "loop_index"
    public static let iterationDurationMap = "iteration_duration_map"
    public static let loopDurationMap = "loop_duration_map"
    public static let loopVariableMap = "loop_variable_map"
    public static let completedReason = "completed_reason"
}

/// The two container kinds (iteration and loop nodes run their inner nodes in child frames).
public enum ContainerKind: String, Sendable, Hashable, Codable {
    case iteration, loop
}

/// The iteration and loop an event's node runs in (graphon's `in_iteration_id` / `in_loop_id`: the innermost of each
/// kind). Root-frame nodes have neither.
public struct NodeScope: Sendable, Hashable {
    public var iterationId: String?
    public var loopId: String?

    public init(iterationId: String? = nil, loopId: String? = nil) {
        self.iterationId = iterationId
        self.loopId = loopId
    }

    public static let root = NodeScope()
    public var isRoot: Bool { iterationId == nil && loopId == nil }
    /// The container the node is in as Dify's traces name it (`in_iteration_id or in_loop_id`).
    public var containerId: String? { iterationId ?? loopId }

    /// The scope a result's metadata records (the engine adds `iteration_id` / `loop_id` to results inside containers).
    public init(metadata: JSONObject) {
        iterationId = metadata[MetadataKey.iterationId]?.string
        loopId = metadata[MetadataKey.loopId]?.string
    }
}

/// `NodeExecutionType`: how the engine treats a node.
public enum NodeExecutionType: String, Sendable, Hashable {
    /// Regular nodes that run and produce outputs.
    case executable
    /// Answer and End: their templates are streamed in order (the response stream filter).
    case response
    /// Nodes that choose one outgoing handle (if-else, question classifier, fail-branch nodes).
    case branch
    /// Iteration and loop.
    case container
    /// Start nodes (entry points).
    case root
}

/// `NodeState`: of a node or an edge during a run.
public enum NodeState: String, Sendable, Hashable, Codable {
    case unknown, taken, skipped
}

/// `NodeRunResult`: what a node produced. Mappings keep Python's dict order.
public struct NodeRunResult: Sendable, Codable {
    public var status: NodeExecutionStatus = .pending
    public var inputs = JSONObject()
    public var processData = JSONObject()
    public var outputs = JSONObject()
    public var metadata = JSONObject()
    public var llmUsage: LLMUsage = .empty
    public var edgeSourceHandle = "source"
    public var error = ""
    public var errorType = ""
    public var retryIndex = 0
    /// The segment types of outputs whose type is not what their value implies (graphon's nodes return `Segment`s: an
    /// aggregator's `output` keeps its variable's type, a list operator's empty `result` is still `array[string]`). The
    /// engine stores these outputs with that type.
    public var outputTypes: [String: SegmentType] = [:]

    public init(status: NodeExecutionStatus = .pending, inputs: JSONObject = JSONObject(), processData: JSONObject = JSONObject(),
                outputs: JSONObject = JSONObject(), metadata: JSONObject = JSONObject(), llmUsage: LLMUsage = .empty,
                error: String = "", errorType: String = "") {
        self.status = status
        self.inputs = inputs
        self.processData = processData
        self.outputs = outputs
        self.metadata = metadata
        self.llmUsage = llmUsage
        self.error = error
        self.errorType = errorType
    }
}

/// What a node's `_run` yields (`graphon/node_events`).
public enum NodeEvent: Sendable {
    /// Usage spent before a node pauses; counted once in its frame and retained by the snapshot.
    case usageDelta(LLMUsage)
    /// `StreamChunkEvent`: a piece of a streamed output (`selector` = `[node, "text"]`).
    case streamChunk(selector: [String], chunk: String, isFinal: Bool)
    /// `StreamReasoningEvent`: a piece of streamed reasoning (`[node, "reasoning_content"]`).
    case streamReasoning(selector: [String], chunk: String, isFinal: Bool)
    /// `RunRetrieverResourceEvent`: the context an LLM node read.
    case retrieverResource(resources: [JSONValue], context: String)
    /// `VariableUpdatedEvent`: the node changed a variable (a conversation variable, by the variable assigner); the engine
    /// writes it to the pool before downstream nodes run.
    case variableUpdated(selector: [String], value: Segment)
    /// `IterationStartedEvent` / `LoopStartedEvent`.
    case containerStarted(kind: ContainerKind, startAt: Date, inputs: JSONObject, metadata: JSONObject)
    /// `IterationNextEvent` / `LoopNextEvent` (`preOutput`: `pre_iteration_output` / `pre_loop_output`).
    case containerNext(kind: ContainerKind, index: Int, preOutput: JSONObject)
    /// `IterationSucceededEvent` / `IterationFailedEvent` / `LoopSucceededEvent` / `LoopFailedEvent` (failed: `error` set).
    case containerCompleted(kind: ContainerKind, startAt: Date, inputs: JSONObject, outputs: JSONObject, metadata: JSONObject, steps: Int,
                            error: String?)
    /// `IterationFrameRequest` / `LoopFrameRequest`: a container node suspends; the engine runs the child frames and
    /// resumes the node with the outcome (`RuntimeNode.resume`). Nothing may follow it.
    case awaitContainer(ContainerRequest)
    /// `StreamCompletedEvent`: the node's result.
    case completed(NodeRunResult)
    /// `PauseRequestedEvent`: no completed result; resume reruns this node with the same execution id.
    case pauseRequested(PauseReason)
}

/// `IterationNode.error_handle_mode` (`ErrorHandleMode`).
public enum ErrorHandleMode: String, Sendable, Hashable, Codable {
    case terminated
    case continueOnError = "continue-on-error"
    case removeAbnormalOutput = "remove-abnormal-output"
}

/// `IterationFrameRequest`: run the iteration rounds `indexes` (each in a child frame from `rootNodeId`).
public struct IterationFrameRequest: Sendable, Codable {
    public var items: [JSONValue]
    public var rootNodeId: String
    public var indexes: [Int]
    public var outputSelector: [String]
    public var errorHandleMode: ErrorHandleMode
    public var flattenOutput: Bool
    public var parallelNums: Int

    public init(items: [JSONValue], rootNodeId: String, indexes: [Int], outputSelector: [String], errorHandleMode: ErrorHandleMode,
                flattenOutput: Bool, parallelNums: Int) {
        self.items = items
        self.rootNodeId = rootNodeId
        self.indexes = indexes
        self.outputSelector = outputSelector
        self.errorHandleMode = errorHandleMode
        self.flattenOutput = flattenOutput
        self.parallelNums = parallelNums
    }
}

/// `LoopFrameRequest`: run loop round `index` (a child frame from `rootNodeId` over the parent's pool).
public struct LoopFrameRequest: Sendable {
    public var inputs: JSONObject
    public var outputs: JSONObject
    public var loopCount: Int
    public var rootNodeId: String
    /// label -> `[loop node, label]`, in the node's order.
    public var loopVariableSelectors: [(key: String, selector: [String])]
    /// The nodes inside the loop (`data.loop_id`).
    public var loopNodeIds: Set<String>
    public var index: Int
    /// The loop variables' first values, written to the pool before the first round. graphon's loop node writes them
    /// into the shared pool itself while it runs; here nodes read a copy, so the engine writes them.
    public var initialVariables: [(selector: [String], value: JSONValue)]

    public init(inputs: JSONObject, outputs: JSONObject, loopCount: Int, rootNodeId: String,
                loopVariableSelectors: [(key: String, selector: [String])], loopNodeIds: Set<String>, index: Int,
                initialVariables: [(selector: [String], value: JSONValue)] = []) {
        self.inputs = inputs
        self.outputs = outputs
        self.loopCount = loopCount
        self.rootNodeId = rootNodeId
        self.loopVariableSelectors = loopVariableSelectors
        self.loopNodeIds = loopNodeIds
        self.index = index
        self.initialVariables = initialVariables
    }
}

/// `ContainerAwaitRequest`.
public enum ContainerRequest: Sendable, Codable {
    case iteration(IterationFrameRequest)
    case loop(LoopFrameRequest)

    public var kind: ContainerKind {
        switch self {
        case .iteration: return .iteration
        case .loop: return .loop
        }
    }
}

/// `ContainerExecutionResult`: a container's outcome (`metadata`: the completed event's, `result`: the node's result).
public struct ContainerExecutionResult: Sendable, Codable {
    public var metadata: JSONObject
    public var steps: Int
    public var result: NodeRunResult

    public init(metadata: JSONObject, steps: Int, result: NodeRunResult) {
        self.metadata = metadata
        self.steps = steps
        self.result = result
    }
}

/// `ContainerRunResult`: what a suspended container node is resumed with: more rounds to run, or its outcome.
public enum ContainerResult: Sendable, Codable {
    case request(ContainerRequest)
    case finished(ContainerExecutionResult)
}

/// What the engine sees of a running node (`graphon/graph_events/node.py`), with the node execution id.
public enum GraphNodeEvent: Sendable {
    case usageDelta(executionId: String, nodeId: String, usage: LLMUsage)
    case pauseRequested(executionId: String, nodeId: String, reason: PauseReason)
    /// `scope`: the iteration / loop the node runs in (set by the engine).
    case started(executionId: String, nodeId: String, nodeType: String, title: String, startAt: Date, scope: NodeScope)
    case streamChunk(executionId: String, nodeId: String, selector: [String], chunk: String, isFinal: Bool)
    case reasoningChunk(executionId: String, nodeId: String, selector: [String], chunk: String, isFinal: Bool)
    case retrieverResource(executionId: String, nodeId: String, resources: [JSONValue], context: String)
    case variableUpdated(executionId: String, nodeId: String, selector: [String], value: Segment)
    case succeeded(executionId: String, nodeId: String, startAt: Date, finishedAt: Date, result: NodeRunResult)
    case failed(executionId: String, nodeId: String, startAt: Date, finishedAt: Date, result: NodeRunResult, error: String)
    /// `NodeRunExceptionEvent`: a failure an error strategy turned into outputs (the engine makes these).
    case exception(executionId: String, nodeId: String, startAt: Date, finishedAt: Date, result: NodeRunResult, error: String)
    /// `NodeRunRetryEvent`: a failed attempt that is retried (`retryIndex` from 1; the engine makes these).
    case retry(executionId: String, nodeId: String, startAt: Date, result: NodeRunResult, error: String, retryIndex: Int)
    /// `NodeRunIterationStartedEvent` / `NodeRunLoopStartedEvent`.
    case containerStarted(executionId: String, nodeId: String, kind: ContainerKind, startAt: Date, inputs: JSONObject, metadata: JSONObject)
    /// `NodeRunIterationNextEvent` / `NodeRunLoopNextEvent`.
    case containerNext(executionId: String, nodeId: String, kind: ContainerKind, index: Int, preOutput: JSONObject)
    /// `NodeRunIterationSucceededEvent` / `...FailedEvent` / `NodeRunLoopSucceededEvent` / `...FailedEvent` (`error` set
    /// when failed).
    case containerCompleted(executionId: String, nodeId: String, kind: ContainerKind, startAt: Date, inputs: JSONObject, outputs: JSONObject,
                            metadata: JSONObject, steps: Int, error: String?)

    /// The final result of `succeeded` / `failed` (`is_node_result_event`).
    public var result: NodeRunResult? {
        switch self {
        case .succeeded(_, _, _, _, let r), .failed(_, _, _, _, let r, _), .exception(_, _, _, _, let r, _): return r
        default: return nil
        }
    }

    public var nodeId: String {
        switch self {
        case .usageDelta(_, let n, _), .pauseRequested(_, let n, _), .started(_, let n, _, _, _, _), .streamChunk(_, let n, _, _, _), .reasoningChunk(_, let n, _, _, _),
             .retrieverResource(_, let n, _, _), .variableUpdated(_, let n, _, _), .succeeded(_, let n, _, _, _),
             .failed(_, let n, _, _, _, _), .exception(_, let n, _, _, _, _), .retry(_, let n, _, _, _, _),
             .containerStarted(_, let n, _, _, _, _), .containerNext(_, let n, _, _, _), .containerCompleted(_, let n, _, _, _, _, _, _, _):
            return n
        }
    }

    public var executionId: String {
        switch self {
        case .usageDelta(let x, _, _), .pauseRequested(let x, _, _), .started(let x, _, _, _, _, _), .streamChunk(let x, _, _, _, _), .reasoningChunk(let x, _, _, _, _),
             .retrieverResource(let x, _, _, _), .variableUpdated(let x, _, _, _), .succeeded(let x, _, _, _, _),
             .failed(let x, _, _, _, _, _), .exception(let x, _, _, _, _, _), .retry(let x, _, _, _, _, _),
             .containerStarted(let x, _, _, _, _, _), .containerNext(let x, _, _, _, _), .containerCompleted(let x, _, _, _, _, _, _, _, _):
            return x
        }
    }

    /// The iteration / loop the node runs in: the started event's scope, else what a result's metadata records (root
    /// for the other events).
    public var scope: NodeScope {
        switch self {
        case .started(_, _, _, _, _, let s): return s
        case .succeeded(_, _, _, _, let r), .failed(_, _, _, _, let r, _), .exception(_, _, _, _, let r, _), .retry(_, _, _, let r, _, _):
            return NodeScope(metadata: r.metadata)
        default: return .root
        }
    }
}
