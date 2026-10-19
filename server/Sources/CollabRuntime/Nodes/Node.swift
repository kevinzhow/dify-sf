// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/base/node.py
// (run, _dispatch, _build_run_failed_event). See ../NOTICE.md.

import Foundation

/// What a node may use while it runs. The pool is the run's values as the node sees them.
public struct NodeRunContext: Sendable {
    public var pool: VariablePool
    /// The account that runs it (Dify's `user_id`), sent to model invocations.
    public var userId: String?
    public var appId: String?
    /// Abort (Dify's stop command); checked between stream chunks.
    public var isAborted: @Sendable () -> Bool

    public init(pool: VariablePool, userId: String? = nil, appId: String? = nil, isAborted: @escaping @Sendable () -> Bool = { false }) {
        self.pool = pool
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

    /// `_run`: emits stream events and, last, `.completed(result)`. Errors thrown here become a failed result
    /// (`error_type` = "WorkflowNodeError", as graphon's `run()` does for exceptions that escape `_run`).
    func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws

    /// `_extract_variable_selector_to_variable_mapping`: `"<node id>.<key>"` -> selector, for the single-step run.
    func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])]
}

extension RuntimeNode {
    public var title: String { base.title }
}

/// Creates nodes from graph configs (graphon's `NodeFactory`, Dify's `DifyNodeFactory`).
public protocol NodeFactory: Sendable {
    /// Throws `UnsupportedNodeType` for types this runtime does not implement, `NodeDataError` for invalid data, and
    /// what preparing the node's resources throws (an LLM node's model: credentials, schema).
    func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode
}

public struct UnsupportedNodeType: Error, CustomStringConvertible, Sendable {
    public var nodeType: String
    public var description: String { "Node type \(nodeType) is not supported by this runtime yet" }
}

/// The node types implemented so far.
public struct BuiltinNodeFactory: NodeFactory {
    public var models: any ModelRuntime
    public var jinja2: (any Jinja2TemplateRenderer)?

    public init(models: any ModelRuntime, jinja2: (any Jinja2TemplateRenderer)? = nil) {
        self.models = models
        self.jinja2 = jinja2
    }

    public static let supportedTypes: [String] = [NodeType.llm]

    public func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        switch config.type {
        case NodeType.llm:
            let data = try LLMNodeData(config.data)
            let (instance, schema) = try await LLMNode.prepareModel(data.model, models: models)
            return LLMNode(id: config.id, data: data, instance: instance, schema: schema, models: models, jinja2: jinja2)
        default: throw UnsupportedNodeType(nodeType: config.type)
        }
    }
}

/// `Node.run()`: the started event, the node's events (stream chunks as they come), and the succeeded or failed event.
public enum NodeRunner {
    public static func run(_ node: any RuntimeNode, executionId: String, context: NodeRunContext,
                           emit: @escaping @Sendable (GraphNodeEvent) async -> Void) async {
        let startAt = Date()
        await emit(.started(executionId: executionId, nodeId: node.id, nodeType: node.nodeType, title: node.title, startAt: startAt))
        do {
            try await node.run(context) { event in
                switch event {
                case .streamChunk(let selector, let chunk, let isFinal):
                    await emit(.streamChunk(executionId: executionId, nodeId: node.id, selector: selector, chunk: chunk, isFinal: isFinal))
                case .streamReasoning(_, let chunk, let isFinal):
                    await emit(.reasoningChunk(executionId: executionId, nodeId: node.id, selector: [node.id, "reasoning_content"],
                                               chunk: chunk, isFinal: isFinal))
                case .retrieverResource(let resources, let context):
                    await emit(.retrieverResource(executionId: executionId, nodeId: node.id, resources: resources, context: context))
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
        } catch {
            let r = NodeRunResult(status: .failed, error: "\(error)", errorType: "WorkflowNodeError")
            await emit(.failed(executionId: executionId, nodeId: node.id, startAt: startAt, finishedAt: Date(), result: r, error: r.error))
        }
    }
}
