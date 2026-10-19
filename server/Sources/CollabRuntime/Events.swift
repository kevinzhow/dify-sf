// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/enums.py,
// graphon/node_events/base.py and node.py, graphon/graph_events/node.py. See NOTICE.md.

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
public enum NodeExecutionStatus: String, Sendable, Hashable {
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
    public static let loopId = "loop_id"
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
public enum NodeState: String, Sendable, Hashable {
    case unknown, taken, skipped
}

/// `NodeRunResult`: what a node produced. Mappings keep Python's dict order.
public struct NodeRunResult: Sendable {
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
    /// `StreamChunkEvent`: a piece of a streamed output (`selector` = `[node, "text"]`).
    case streamChunk(selector: [String], chunk: String, isFinal: Bool)
    /// `StreamReasoningEvent`: a piece of streamed reasoning (`[node, "reasoning_content"]`).
    case streamReasoning(selector: [String], chunk: String, isFinal: Bool)
    /// `RunRetrieverResourceEvent`: the context an LLM node read.
    case retrieverResource(resources: [JSONValue], context: String)
    /// `VariableUpdatedEvent`: the node changed a variable (a conversation variable, by the variable assigner); the engine
    /// writes it to the pool before downstream nodes run.
    case variableUpdated(selector: [String], value: Segment)
    /// `StreamCompletedEvent`: the node's result.
    case completed(NodeRunResult)
}

/// What the engine sees of a running node (`graphon/graph_events/node.py`), with the node execution id.
public enum GraphNodeEvent: Sendable {
    case started(executionId: String, nodeId: String, nodeType: String, title: String, startAt: Date)
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

    /// The final result of `succeeded` / `failed` (`is_node_result_event`).
    public var result: NodeRunResult? {
        switch self {
        case .succeeded(_, _, _, _, let r), .failed(_, _, _, _, let r, _), .exception(_, _, _, _, let r, _): return r
        default: return nil
        }
    }

    public var nodeId: String {
        switch self {
        case .started(_, let n, _, _, _), .streamChunk(_, let n, _, _, _), .reasoningChunk(_, let n, _, _, _),
             .retrieverResource(_, let n, _, _), .variableUpdated(_, let n, _, _), .succeeded(_, let n, _, _, _),
             .failed(_, let n, _, _, _, _), .exception(_, let n, _, _, _, _), .retry(_, let n, _, _, _, _):
            return n
        }
    }

    public var executionId: String {
        switch self {
        case .started(let x, _, _, _, _), .streamChunk(let x, _, _, _, _), .reasoningChunk(let x, _, _, _, _),
             .retrieverResource(let x, _, _, _), .variableUpdated(let x, _, _, _), .succeeded(let x, _, _, _, _),
             .failed(let x, _, _, _, _, _), .exception(let x, _, _, _, _, _), .retry(let x, _, _, _, _, _):
            return x
        }
    }
}
