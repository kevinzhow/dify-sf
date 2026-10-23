// Ported from Dify 1.17.1 (https://github.com/langgenius/dify): api/core/workflow/workflow_entry.py (single_step_run,
// mapping_user_inputs_to_variable_pool), api/services/workflow_service.py (run_draft_workflow_node,
// _handle_single_step_result, _apply_error_strategy, _populate_execution_result), api/core/workflow/system_variables.py,
// api/fields/workflow_run_fields.py (WorkflowRunNodeExecutionResponse). See NOTICE.md.

import Foundation

/// One node execution as Dify stores and answers it (`WorkflowNodeExecution` / `WorkflowRunNodeExecutionResponse`).
public struct NodeExecution: Sendable {
    public var id: String
    public var index = 1
    public var predecessorNodeId: String?
    public var nodeId: String
    public var nodeType: String
    public var title: String
    /// Nil when empty or when the node failed (Dify stores none then).
    public var inputs: JSONObject?
    public var processData: JSONObject?
    public var outputs: JSONObject?
    public var outputTypes: [String: SegmentType] = [:]
    public var status: NodeExecutionStatus
    public var error: String?
    /// Seconds.
    public var elapsedTime: Double
    public var metadata: JSONObject?
    public var createdAt: Date
    public var finishedAt: Date?

    public init(id: String, nodeId: String, nodeType: String, title: String, status: NodeExecutionStatus, elapsedTime: Double,
                createdAt: Date, finishedAt: Date?) {
        self.id = id
        self.nodeId = nodeId
        self.nodeType = nodeType
        self.title = title
        self.status = status
        self.elapsedTime = elapsedTime
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }

    /// `WorkflowRunNodeExecutionResponse` (Dify's field order). `createdByAccount` is Dify's `SimpleAccount`
    /// (`{id, name, email}`) or null.
    public func responseJSON(createdByAccount: JSONValue) -> JSONValue {
        func seconds(_ d: Date) -> JSONValue { .int(Int(d.timeIntervalSince1970.rounded(.down))) }
        var o = JSONObject()
        o["id"] = .string(id)
        o["index"] = .int(index)
        o["predecessor_node_id"] = predecessorNodeId.map(JSONValue.string) ?? .null
        o["node_id"] = .string(nodeId)
        o["node_type"] = .string(nodeType)
        o["title"] = .string(title)
        o["inputs"] = inputs.map(JSONValue.object) ?? .null
        o["process_data"] = processData.map(JSONValue.object) ?? .null
        o["outputs"] = outputs.map(JSONValue.object) ?? .null
        o["status"] = .string(status.rawValue)
        o["error"] = error.map(JSONValue.string) ?? .null
        o["elapsed_time"] = .double(elapsedTime)
        o["execution_metadata"] = .object(metadata ?? JSONObject())
        o["extras"] = .object(JSONObject())
        o["created_at"] = seconds(createdAt)
        o["created_by_role"] = createdByAccount == .null ? .null : "account"
        o["created_by_account"] = createdByAccount
        o["created_by_end_user"] = .null
        o["finished_at"] = finishedAt.map(seconds) ?? .null
        o["inputs_truncated"] = false
        o["outputs_truncated"] = false
        o["process_data_truncated"] = false
        return .object(o)
    }
}

/// Running one node of a draft on its own (Dify's "run this step"): Dify's `WorkflowService.run_draft_workflow_node` over
/// `WorkflowEntry.single_step_run`; the optional loader supplies cached inputs and the scoped file adapter resolves file identities.
public struct SingleStepRun: Sendable {
    public var graph: GraphConfig
    /// The draft's environment variables (`workflow.environment_variables`, secret values included).
    public var environmentVariables: [JSONValue]
    public var factory: any NodeFactory
    public var files: (any RuntimeFiles)?
    /// Dify's `VariableLoader` (draft variables): values the node reads that neither the request nor the pool has.
    public var variableLoader: (@Sendable ([[String]]) async throws -> [(selector: [String], segment: Segment)])?

    public init(graph: GraphConfig, environmentVariables: [JSONValue], factory: any NodeFactory,
                variableLoader: (@Sendable ([[String]]) async throws -> [(selector: [String], segment: Segment)])? = nil,
                files: (any RuntimeFiles)? = nil) {
        self.graph = graph
        self.environmentVariables = environmentVariables
        self.factory = factory
        self.variableLoader = variableLoader
        self.files = files
    }

    public struct NodeNotFound: Error, CustomStringConvertible, Sendable {
        public var nodeId: String
        public var description: String { "Node \(nodeId) not found" }
    }

    /// A request the runtime refuses before running anything (Dify answers these as errors, not as a failed execution).
    public struct InvalidInput: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// Runs `nodeId` with `userInputs` (Dify's `inputs`: keys `#node.var#` or `node.#node.var#`): every event goes to
    /// `emit`; the answer is the execution to store and return.
    public func run(nodeId: String, userInputs: JSONObject, userId: String?, appId: String?, executionId: String = UUID().uuidString.lowercased(),
                    emit: @escaping @Sendable (GraphNodeEvent) async -> Void = { _ in }) async throws -> NodeExecution {
        guard let config = graph.node(nodeId) else { throw NodeNotFound(nodeId: nodeId) }
        if config.type == NodeType.loop || config.type == NodeType.iteration {
            throw InvalidInput(description: "Loop and Iteration nodes must use their engine-backed debug endpoints")
        }
        let startedAt = Date()
        let clock = ContinuousClock.now

        // Pool: a start node gets its inputs (P2); every other node the default system variables and the environment.
        var pool = VariablePool()
        if NodeType.startTypes.contains(config.type) {
            throw UnsupportedNodeType(nodeType: config.type)
        }
        try pool.add([VariablePool.systemNodeId, "workflow_run_id"], .string(UUID().uuidString.lowercased()))
        for v in environmentVariables {
            guard let name = v["name"]?.string else { continue }
            try pool.add([VariablePool.environmentNodeId, name], v["value"] ?? .null)
        }

        let node = try await factory.createNode(config, graph: graph)
        var mapping = node.variableMapping(graph: graph)
        // inject_default_system_variable_mappings: an LLM node with memory reads sys.query.
        if config.type == NodeType.llm, config.data["memory"]?.object != nil, !mapping.contains(where: { $0.key == "\(nodeId).#sys.query#" }) {
            mapping.append(("\(nodeId).#sys.query#", ["sys", "query"]))
        }
        // load_into_variable_pool: what the inputs and the pool lack comes from the draft variables.
        if let variableLoader {
            let missing = try DraftVariableRules.selectorsToLoad(mapping: mapping, userInputs: userInputs, pool: pool)
            if !missing.isEmpty {
                for (selector, segment) in try await variableLoader(missing) where selector.count == VariablePool.selectorsLength {
                    try pool.add(selector, segment)
                }
            }
        }
        if pool.get([VariablePool.systemNodeId, "files"]) == nil { try pool.add([VariablePool.systemNodeId, "files"], .array([])) }
        var canonicalInputs = userInputs
        if let files {
            for (key, value) in userInputs { canonicalInputs[key] = try await files.canonicalize(value, allowInputMappings: true) }
        }
        try Self.mapUserInputs(mapping, canonicalInputs, &pool)

        let box = ResultBox()
        await NodeRunner.run(node, executionId: executionId, context: NodeRunContext(pool: pool, userId: userId, appId: appId)) { event in
            if let r = event.result { await box.set(r) }
            await emit(event)
        }
        guard var result = await box.result else { throw InvalidInput(description: "Node execution failed - no result returned") }
        if result.status == .failed, let strategy = node.base.errorStrategy {
            result = Self.applyErrorStrategy(strategy, node.base, result)
        }
        var execution = NodeExecution(id: executionId, nodeId: nodeId, nodeType: node.nodeType, title: node.title, status: .failed,
                                      elapsedTime: Self.seconds(ContinuousClock.now - clock), createdAt: startedAt, finishedAt: Date())
        if result.status == .succeeded || result.status == .exception {
            execution.inputs = result.inputs.isEmpty ? nil : result.inputs
            execution.processData = result.processData.isEmpty ? nil : result.processData
            execution.outputs = result.outputs.isEmpty ? nil : result.outputs
            execution.outputTypes = result.outputTypes
            execution.metadata = result.metadata
            execution.status = result.status
            if result.status == .exception { execution.error = result.error }
        } else {
            execution.status = .failed
            execution.error = result.error
        }
        return execution
    }

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    actor ResultBox {
        var result: NodeRunResult?
        func set(_ r: NodeRunResult) { if result == nil { result = r } }
    }

    /// `_apply_error_strategy`: a failed node with an error strategy ends as `exception` with `error_message`,
    /// `error_type` (and the default values).
    static func applyErrorStrategy(_ s: ErrorStrategy, _ base: BaseNodeData, _ r: NodeRunResult) -> NodeRunResult {
        var outputs: JSONObject = ["error_message": .string(r.error), "error_type": .string(r.errorType)]
        if s == .defaultValue { outputs = outputs.merging(base.defaultValueDict) }
        return NodeRunResult(status: .exception, inputs: r.inputs, outputs: outputs, metadata: [MetadataKey.errorStrategy: .string(s.rawValue)],
                             error: r.error)
    }

    /// `WorkflowEntry.mapping_user_inputs_to_variable_pool`.
    public static func mapUserInputs(_ mapping: [(key: String, selector: [String])], _ inputs: JSONObject, _ pool: inout VariablePool) throws {
        for (nodeVariable, selector) in mapping {
            let parts = nodeVariable.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let key = parts.dropFirst().joined(separator: ".")
            if inputs[key] == nil && inputs[nodeVariable] == nil && pool.get(selector) == nil {
                throw InvalidInput(description: "Variable key \(nodeVariable) not found in user inputs.")
            }
            if pool.get(selector) != nil && selector.first == VariablePool.environmentNodeId { continue }
            guard let nodeId = selector.first else { continue }
            var value = inputs[nodeVariable]
            if value == nil || !value!.isTruthy { value = inputs[key] }
            guard let input = value, input != .null else { continue }
            if nodeId == VariablePool.environmentNodeId { continue }
            var keys = Array(selector.dropFirst())
            var v = input
            if keys.count == 2 && keys[0] == "structured_output" {
                v = .object([keys[1]: input])
                keys = [keys[0]]
                if case .object(let current)? = pool.get([nodeId] + keys)?.value, case .object(let add) = v {
                    v = .object(current.merging(add))
                }
            }
            do { try pool.add([nodeId] + keys, v) } catch let e as VariablePool.InvalidSelector {
                throw InvalidInput(description: e.description)
            }
        }
    }
}
