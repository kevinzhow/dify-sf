// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/base/node.py
// (run, _dispatch, _build_run_failed_event). See ../NOTICE.md.

import Foundation
import Synchronization

/// What a node may use while it runs. The pool is the run's values as the node sees them.
public struct NodeRunContext: Sendable {
    public var pool: VariablePool
    public var executionId: String?
    /// The account that runs it (Dify's `user_id`), sent to model invocations.
    public var userId: String?
    public var appId: String?
    /// Abort (Dify's stop command); checked between stream chunks.
    public var isAborted: @Sendable () -> Bool

    public init(pool: VariablePool, executionId: String? = nil, userId: String? = nil, appId: String? = nil, isAborted: @escaping @Sendable () -> Bool = { false }) {
        self.pool = pool
        self.executionId = executionId
        self.userId = userId
        self.appId = appId
        self.isAborted = isAborted
    }
}

/// An error a node's `_run` raised, with the Python class name graphon reports as `error_type`.
public protocol NodeRunError: Error, CustomStringConvertible {
    var errorTypeName: String { get }
}

/// A generic node error (`LLMNodeError`, `ValueError`, ...).
public struct NodeError: NodeRunError, Sendable {
    public var errorTypeName: String
    public var message: String
    public init(_ type: String, _ message: String) {
        errorTypeName = type
        self.message = message
    }
    public var description: String { message }
}

/// A node implementation (graphon's `Node` subclasses).
public protocol RuntimeNode: Sendable {
    /// The node's id in the graph.
    var id: String { get }
    var nodeType: String { get }
    var base: BaseNodeData { get }

    /// `execution_type` (default `executable`). The engine promotes fail-branch nodes to `branch`.
    var executionType: NodeExecutionType { get }

    /// `retry`: whether the node's `retry_config` applies (graphon: LLM, code, HTTP request and tool nodes only).
    var retryEnabled: Bool { get }

    /// `blocks_variable_output`: the node must finish before these selectors can stream (the variable assigner writing
    /// a conversation variable an answer shows).
    func blocksVariableOutput(_ selectors: Set<[String]>) -> Bool

    /// `get_streaming_template`: the template a response node (answer, end) streams.
    var streamingTemplate: ResponseTemplate? { get }

    /// `get_streaming_text_selector`: the selector of a response node's text segments (`[node, "answer"]`).
    var streamingTextSelector: [String] { get }

    /// `_run`: emits stream events and, last, `.completed(result)`. Errors thrown here become a failed result
    /// (`error_type` = "WorkflowNodeError", as graphon's `run()` does for exceptions that escape `_run`).
    func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws

    /// `_extract_variable_selector_to_variable_mapping`: `"<node id>.<key>"` -> selector, for the single-step run.
    func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])]

    /// `_resume_container_events`: a container node (iteration, loop) that suspended with `.awaitContainer` continues with
    /// `result` (more rounds, or the outcome); it emits events as `run` does. Other nodes throw.
    func resume(_ result: ContainerResult, startAt: Date, context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws
}

/// A node resumed that does not support it (graphon's `TypeError`).
public struct ContainerResumeUnsupported: Error, CustomStringConvertible, Sendable {
    public var nodeId: String
    public var description: String { "Node \(nodeId) does not support container resume" }
}

extension RuntimeNode {
    public var title: String { base.title }
    public var executionType: NodeExecutionType { .executable }
    public var retryEnabled: Bool { false }
    public func blocksVariableOutput(_ selectors: Set<[String]>) -> Bool { false }
    public var streamingTemplate: ResponseTemplate? { nil }
    public var streamingTextSelector: [String] { [id, "answer"] }
    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] { [] }
    public func resume(_ result: ContainerResult, startAt: Date, context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        throw ContainerResumeUnsupported(nodeId: id)
    }
}

/// Creates nodes from graph configs (graphon's `NodeFactory`, Dify's `DifyNodeFactory`).
public protocol NodeFactory: Sendable {
    /// Throws `UnsupportedNodeType` for types this runtime does not implement, `NodeDataError` for invalid data, and
    /// what preparing the node's resources throws (an LLM node's model: credentials, schema).
    func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode
}

public struct UnsupportedNodeType: Error, CustomStringConvertible, Sendable {
    public var nodeType: String
    public init(nodeType: String) { self.nodeType = nodeType }
    public var description: String { "Node type \(nodeType) is not supported by this runtime yet" }
}

/// What nodes call outside the runtime (Dify's model runtime, code sandbox, SSRF-proxied HTTP). Nil = not configured:
/// nodes that need it fail when they are created.
public struct RuntimeServices: Sendable {
    /// Models (Dify's plugin daemon).
    public var models: (any ModelRuntime)?
    /// Jinja2 rendering (Dify: through the code sandbox).
    public var jinja2: (any Jinja2TemplateRenderer)?
    /// The code sandbox (Dify's `dify-sandbox`).
    public var codeExecutor: (any CodeExecutor)?
    /// HTTP for the HTTP request node (Dify: through `ssrf_proxy`).
    public var http: (any RuntimeHTTPClient)?
    public var humanInput: (any HumanInputRuntime)?
    public var agent: (any AgentRuntime)?
    public var memory: (any ConversationMemory)?
    public var files: (any RuntimeFiles)?
    public var tools: (any ToolRuntime)?

    public init(models: (any ModelRuntime)? = nil, jinja2: (any Jinja2TemplateRenderer)? = nil, codeExecutor: (any CodeExecutor)? = nil,
                http: (any RuntimeHTTPClient)? = nil, humanInput: (any HumanInputRuntime)? = nil, files: (any RuntimeFiles)? = nil, memory: (any ConversationMemory)? = nil, tools: (any ToolRuntime)? = nil) {
        self.models = models
        self.jinja2 = jinja2
        self.codeExecutor = codeExecutor
        self.http = http
        self.humanInput = humanInput
        self.files = files
        self.memory = memory
        self.tools = tools
    }

    public func requireModels() throws -> any ModelRuntime {
        guard let models else { throw ServiceNotConfigured(service: .models) }
        return models
    }
}

/// A node needs a service the server was not configured with (creating the node fails).
public struct ServiceNotConfigured: Error, CustomStringConvertible, Sendable {
    public enum Service: String, Sendable { case tools = "tool runtime", models = "model runtime", codeSandbox = "code sandbox", http = "HTTP client", humanInput = "human input" }
    public var service: Service
    public init(service: Service) { self.service = service }
    public var description: String { "This server has no \(service.rawValue) configured" }
}

/// The node types implemented so far (Dify's `DifyNodeFactory` over graphon's node classes). Each type's `make...` lives
/// next to its node.
public struct BuiltinNodeFactory: NodeFactory {
    public var services: RuntimeServices

    public init(services: RuntimeServices) {
        self.services = services
    }

    public init(models: any ModelRuntime, jinja2: (any Jinja2TemplateRenderer)? = nil) {
        services = RuntimeServices(models: models, jinja2: jinja2)
    }

    public var models: (any ModelRuntime)? { services.models }
    public var jinja2: (any Jinja2TemplateRenderer)? { services.jinja2 }

    public static let supportedTypes: [String] = [
        NodeType.tool, NodeType.start, NodeType.end, NodeType.answer, NodeType.llm, NodeType.ifElse, NodeType.variableAggregator,
        NodeType.legacyVariableAggregator, NodeType.variableAssigner, NodeType.templateTransform, NodeType.code,
        NodeType.httpRequest, NodeType.listOperator, NodeType.parameterExtractor, NodeType.questionClassifier,
        NodeType.iteration, NodeType.iterationStart, NodeType.loop, NodeType.loopStart, NodeType.loopEnd,
    ]

    public func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        switch config.type {
        case NodeType.tool:
            guard let runtime = services.tools else { throw ServiceNotConfigured(service: .tools) }
            return try ToolNode(id: config.id, data: config.data, runtime: runtime, files: services.files)
        case "agent":
            guard let runtime = services.agent else { throw UnsupportedNodeType(nodeType: config.type) }
            let data = try AgentNodeData(config.data)
            try await runtime.prepare(nodeID: config.id, data: data)
            return AgentV2Node(id: config.id, data: data, runtime: runtime)
        case NodeType.humanInput:
            guard let runtime = services.humanInput else { throw ServiceNotConfigured(service: .humanInput) }
            return try HumanInputNode(id: config.id, data: config.data, runtime: runtime)
        case NodeType.start: return try StartNode(id: config.id, data: config.data)
        case NodeType.end: return try EndNode(id: config.id, data: config.data)
        case NodeType.answer: return try AnswerNode(id: config.id, data: config.data)
        case NodeType.llm:
            let data = try LLMNodeData(config.data)
            let models = try services.requireModels()
            let (instance, schema) = try await LLMNode.prepareModel(data.model, models: models)
            return LLMNode(id: config.id, data: data, instance: instance, schema: schema, models: models, jinja2: services.jinja2, files: services.files, memory: services.memory)
        case NodeType.ifElse: return try await makeIfElse(config, graph: graph)
        case NodeType.variableAggregator, NodeType.legacyVariableAggregator: return try await makeVariableAggregator(config, graph: graph)
        case NodeType.variableAssigner: return try await makeVariableAssigner(config, graph: graph)
        case NodeType.templateTransform: return try await makeTemplateTransform(config, graph: graph)
        case NodeType.code: return try await makeCode(config, graph: graph)
        case NodeType.httpRequest: return try await makeHTTPRequest(config, graph: graph)
        case NodeType.listOperator: return try await makeListOperator(config, graph: graph)
        case NodeType.parameterExtractor: return try await makeParameterExtractor(config, graph: graph)
        case NodeType.questionClassifier: return try await makeQuestionClassifier(config, graph: graph)
        case NodeType.iteration: return try IterationNode(id: config.id, data: config.data)
        case NodeType.iterationStart: return try ContainerStartNode(id: config.id, data: config.data, nodeType: NodeType.iterationStart)
        case NodeType.loop: return try LoopNode(id: config.id, data: config.data, graph: graph)
        case NodeType.loopStart: return try ContainerStartNode(id: config.id, data: config.data, nodeType: NodeType.loopStart)
        case NodeType.loopEnd: return try ContainerStartNode(id: config.id, data: config.data, nodeType: NodeType.loopEnd)
        default: throw UnsupportedNodeType(nodeType: config.type)
        }
    }
}

/// `Node.run()`: the started event, the node's events (stream chunks as they come), and the succeeded or failed event; and
/// `Node.resume_container()` for container nodes. A container node that suspends (`.awaitContainer`) ends its task with
/// `onAwait` instead of a result.
public enum NodeRunner {
    public typealias AwaitHandler = @Sendable (ContainerRequest, Date) async -> Void

    public static func run(_ node: any RuntimeNode, executionId: String, context: NodeRunContext,
                           emit: @escaping @Sendable (GraphNodeEvent) async -> Void, onAwait: AwaitHandler? = nil) async {
        var context = context
        context.executionId = executionId
        let startAt = Date()
        await emit(.started(executionId: executionId, nodeId: node.id, nodeType: node.nodeType, title: node.title, startAt: startAt, scope: .root))
        let state = SuspendState()
        do {
            try await node.run(context) { event in
                await forward(event, node: node, executionId: executionId, startAt: startAt, state: state, emit: emit, onAwait: onAwait)
            }
        } catch {
            if state.suspended { return }
            let r = NodeRunResult(status: .failed, error: "\(error)", errorType: "WorkflowNodeError")
            await emit(.failed(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: r, error: r.error))
        }
    }

    /// `resume_container(result, started_at)`: no started event; errors become a failed result.
    public static func resume(_ node: any RuntimeNode, executionId: String, startAt: Date, result: ContainerResult, context: NodeRunContext,
                              emit: @escaping @Sendable (GraphNodeEvent) async -> Void, onAwait: AwaitHandler? = nil) async {
        var context = context
        context.executionId = executionId
        let state = SuspendState()
        do {
            try await node.resume(result, startAt: startAt, context: context) { event in
                await forward(event, node: node, executionId: executionId, startAt: startAt, state: state, emit: emit, onAwait: onAwait)
            }
        } catch {
            if state.suspended { return }
            let r = NodeRunResult(status: .failed, error: "\(error)", errorType: "WorkflowNodeError")
            await emit(.failed(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: r, error: r.error))
        }
    }

    /// Whether the node suspended (later events are dropped: graphon's worker stops reading the generator).
    final class SuspendState: Sendable {
        private let flag = Mutex(false)
        var suspended: Bool { flag.withLock { $0 } }
        func suspend() { flag.withLock { $0 = true } }
    }

    static func forward(_ event: NodeEvent, node: any RuntimeNode, executionId: String, startAt: Date, state: SuspendState,
                        emit: @Sendable (GraphNodeEvent) async -> Void, onAwait: AwaitHandler?) async {
        if state.suspended { return }
        switch event {
        case .streamChunk(let selector, let chunk, let isFinal):
            await emit(.streamChunk(executionId: executionId, nodeId: node.id, selector: selector, chunk: chunk, isFinal: isFinal))
        case .streamReasoning(_, let chunk, let isFinal):
            await emit(.reasoningChunk(executionId: executionId, nodeId: node.id, selector: [node.id, "reasoning_content"],
                                       chunk: chunk, isFinal: isFinal))
        case .retrieverResource(let resources, let context):
            await emit(.retrieverResource(executionId: executionId, nodeId: node.id, resources: resources, context: context))
        case .variableUpdated(let selector, let value):
            await emit(.variableUpdated(executionId: executionId, nodeId: node.id, selector: selector, value: value))
        case .containerStarted(let kind, let at, let inputs, let metadata):
            await emit(.containerStarted(executionId: executionId, nodeId: node.id, kind: kind, startAt: at, inputs: inputs, metadata: metadata))
        case .containerNext(let kind, let index, let pre):
            await emit(.containerNext(executionId: executionId, nodeId: node.id, kind: kind, index: index, preOutput: pre))
        case .containerCompleted(let kind, let at, let inputs, let outputs, let metadata, let steps, let error):
            await emit(.containerCompleted(executionId: executionId, nodeId: node.id, kind: kind, startAt: at, inputs: inputs, outputs: outputs,
                                           metadata: metadata, steps: steps, error: error))
        case .awaitContainer(let request):
            state.suspend()
            if let onAwait {
                await onAwait(request, startAt)
            } else {
                // Outside the engine (a single-step run) nothing can run the child frames.
                let r = NodeRunResult(status: .failed, error: "container await request emitted outside the graph engine",
                                      errorType: "RuntimeError")
                await emit(.failed(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: r, error: r.error))
            }
        case .usageDelta(let usage):
            await emit(.usageDelta(executionId: executionId, nodeId: node.id, usage: usage))
        case .pauseRequested(let reason):
            state.suspend()
            await emit(.pauseRequested(executionId: executionId, nodeId: node.id, reason: reason))
        case .completed(let result):
            switch result.status {
            case .succeeded:
                await emit(.succeeded(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: result))
            case .failed:
                await emit(.failed(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: result,
                                   error: result.error))
            default:
                let r = NodeRunResult(status: .failed, error: "Node \(node.id) does not support status \(result.status.rawValue)",
                                      errorType: "WorkflowNodeError")
                await emit(.failed(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: r, error: r.error))
            }
        }
    }
}
