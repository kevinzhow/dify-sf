// Ported from Dify 1.17.1 (https://github.com/langgenius/dify, Apache-2.0 with Dify's conditions):
// api/core/app/apps/workflow_app_runner.py (_prepare_single_node_execution, _get_graph_and_variable_pool_for_single_node_run),
// api/core/workflow/system_variables.py (default_system_variables). See NOTICE.md.

import Foundation

/// Dify's iteration / loop single run ("run this step" of a container): the container node with its inner nodes and
/// start node as a graph rooted at the container, over a pool of the default system variables, the environment, the
/// draft variables the nodes read and the request's inputs. The engine then runs it like a draft run.
public struct ContainerSingleRun: Sendable {
    /// The draft's whole graph.
    public var graph: GraphConfig
    /// The draft's environment variables (`workflow.environment_variables`, secret values included).
    public var environmentVariables: [JSONValue]
    public var factory: any NodeFactory
    /// Dify's `VariableLoader` (draft variables): values the nodes read that neither the request nor the pool has.
    public var variableLoader: (@Sendable ([[String]]) async throws -> [(selector: [String], segment: Segment)])?

    public init(graph: GraphConfig, environmentVariables: [JSONValue], factory: any NodeFactory,
                variableLoader: (@Sendable ([[String]]) async throws -> [(selector: [String], segment: Segment)])? = nil) {
        self.graph = graph
        self.environmentVariables = environmentVariables
        self.factory = factory
        self.variableLoader = variableLoader
    }

    public struct Prepared: Sendable {
        public var graph: RuntimeGraph
        public var pool: VariablePool
        /// The system variables (`sys.*` inputs of the run record).
        public var system: [(String, JSONValue)]
    }

    /// `ValueError`s Dify raises before anything runs.
    public struct InvalidInput: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// The nodes of the container (`node_type_filter_key` = `iteration_id` / `loop_id`), the container and its start node;
    /// the edges between them.
    public static func filteredGraph(_ graph: GraphConfig, nodeId: String, kind: ContainerKind) throws -> GraphConfig {
        let key = kind == .iteration ? "iteration_id" : "loop_id"
        let all = graph.json["nodes"]?.array ?? []
        let main = all.first { $0["id"]?.string == nodeId }
        let startId = main?["data"]?["start_node_id"]?.string
        let nodes = all.filter { n in
            let id = n["id"]?.string
            return id == nodeId || n["data"]?[key]?.string == nodeId || (startId != nil && id == startId)
        }
        let ids = Set(nodes.compactMap { $0["id"]?.string })
        let edges = (graph.json["edges"]?.array ?? []).filter { e in
            let s = e["source"], t = e["target"]
            return (s == nil || s == .null || s?.string.map(ids.contains) == true) && (t == nil || t == .null || t?.string.map(ids.contains) == true)
        }
        var json = graph.json.object ?? [:]
        json["nodes"] = .array(nodes)
        json["edges"] = .array(edges)
        return try GraphConfig(json: .object(json))
    }

    public func prepare(nodeId: String, kind: ContainerKind, userInputs: JSONObject, runId: String) async throws -> Prepared {
        let label = kind == .iteration ? "iteration" : "loop"
        let filtered = try Self.filteredGraph(graph, nodeId: nodeId, kind: kind)
        guard let target = filtered.node(nodeId) else { throw InvalidInput("\(label) node id not found in workflow graph") }
        guard target.type == (kind == .iteration ? NodeType.iteration : NodeType.loop) else {
            throw InvalidInput("Node \(nodeId) is not a \(label) node")
        }
        // default_system_variables() + the environment.
        let system = WorkflowBootstrap.systemVariables([("workflow_execution_id", .string(runId))])
        let environment = try environmentVariables.map(WorkflowBootstrap.variable)
        var pool = try WorkflowBootstrap.pool(system: system, environment: environment, conversation: [], rootId: nodeId, inputs: [:])

        // Dify extracts selectors from workflow.graph_dict, before constructing the filtered execution graph.
        // Nested descendants are absent from that filtered graph but can still reference external inputs.
        let mapping = try await ContainerVariableMapping.mapping(containerId: nodeId, graph: graph, factory: factory)
        // load_into_variable_pool, then mapping_user_inputs_to_variable_pool.
        if let variableLoader {
            let missing = try DraftVariableRules.selectorsToLoad(mapping: mapping, userInputs: userInputs, pool: pool)
            if !missing.isEmpty {
                for (selector, segment) in try await variableLoader(missing) where selector.count == VariablePool.selectorsLength {
                    try pool.add(selector, segment)
                }
            }
        }
        do { try SingleStepRun.mapUserInputs(mapping, userInputs, &pool) } catch let e as SingleStepRun.InvalidInput {
            throw InvalidInput(e.description)
        }
        let runtimeGraph = try await RuntimeGraph.build(filtered, rootId: nodeId, factory: factory, skipValidation: true)
        return Prepared(graph: runtimeGraph, pool: pool, system: system)
    }
}
