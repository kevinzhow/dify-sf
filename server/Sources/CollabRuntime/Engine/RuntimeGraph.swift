// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/graph/graph.py (Graph.init,
// _build_edges, _promote_fail_branch_nodes, _mark_inactive_root_branches), graphon/graph/edge.py,
// graphon/graph/validation.py. See ../NOTICE.md.

/// A graph ready to run: node instances, edges with graphon's ids (`edge_<n>`, in the config's order), the root, and
/// the execution type of every node (fail-branch nodes promoted to branches).
public struct RuntimeGraph: Sendable {
    public struct Edge: Sendable, Hashable {
        public var id: String
        /// Source node.
        public var tail: String
        /// Target node.
        public var head: String
        public var sourceHandle: String
    }

    public let config: GraphConfig
    public let nodes: [String: any RuntimeNode]
    /// Node ids in the config's order.
    public let nodeIds: [String]
    public let edges: [String: Edge]
    public let edgeIds: [String]
    public let inEdges: [String: [String]]
    public let outEdges: [String: [String]]
    public let rootId: String
    public let executionTypes: [String: NodeExecutionType]
    /// Nodes and edges of inactive root branches (other start nodes), skipped before the run.
    public let initiallySkippedNodes: Set<String>
    public let initiallySkippedEdges: Set<String>

    /// `GraphValidationError`.
    public struct ValidationError: Error, CustomStringConvertible, Sendable {
        public var issues: [(code: String, message: String)]
        public var description: String { issues.map { "[\($0.code)] \($0.message)" }.joined(separator: "; ") }
    }

    public func node(_ id: String) -> (any RuntimeNode)? { nodes[id] }
    public func executionType(_ id: String) -> NodeExecutionType { executionTypes[id] ?? .executable }
    public func outgoing(_ id: String) -> [Edge] { (outEdges[id] ?? []).compactMap { edges[$0] } }
    public func incoming(_ id: String) -> [Edge] { (inEdges[id] ?? []).compactMap { edges[$0] } }

    /// `Graph.init(graph_config, node_factory, root_node_id)`.
    public static func build(_ config: GraphConfig, rootId: String, factory: any NodeFactory) async throws -> RuntimeGraph {
        guard !config.nodes.isEmpty else { throw GraphConfig.Invalid(description: "Graph must have at least one node") }
        guard config.node(rootId) != nil else { throw GraphConfig.Invalid(description: "Root node id \(rootId) not found in the graph") }

        // _build_edges: the counter advances also for edges skipped for a non-string handle.
        var edges: [String: Edge] = [:], edgeIds: [String] = [], inEdges: [String: [String]] = [:], outEdges: [String: [String]] = [:]
        var counter = 0
        for e in config.json["edges"]?.array ?? [] {
            guard let source = e["source"]?.string, let target = e["target"]?.string else { continue }
            let id = "edge_\(counter)"
            counter += 1
            let handle: String
            switch e["sourceHandle"] {
            case nil: handle = "source"
            case .string(let h)?: handle = h
            default: continue
            }
            edges[id] = Edge(id: id, tail: source, head: target, sourceHandle: handle)
            edgeIds.append(id)
            outEdges[source, default: []].append(id)
            inEdges[target, default: []].append(id)
        }

        // Node ids are unique in a valid graph; a later duplicate replaces the earlier (Python's dict).
        var nodes: [String: any RuntimeNode] = [:], nodeIds: [String] = []
        for n in config.nodes {
            let node = try await factory.createNode(n, graph: config)
            if nodes[n.id] == nil { nodeIds.append(n.id) }
            nodes[n.id] = node
        }

        var types: [String: NodeExecutionType] = [:]
        for (id, node) in nodes {
            types[id] = node.base.errorStrategy == .failBranch ? .branch : node.executionType
        }

        // _mark_inactive_root_branches.
        var skippedNodes = Set<String>(), skippedEdges = Set<String>()
        let roots = nodeIds.filter { types[$0] == .root }
        if roots.count > 1, roots.contains(rootId) {
            for r in roots where r != rootId { skippedNodes.insert(r) }
            func markDownstream(_ id: String) {
                guard skippedNodes.contains(id) else { return }
                for eid in outEdges[id] ?? [] {
                    guard let edge = edges[eid] else { continue }
                    skippedEdges.insert(eid)
                    guard nodes[edge.head] != nil else { continue }
                    if (inEdges[edge.head] ?? []).allSatisfy({ skippedEdges.contains($0) }) {
                        skippedNodes.insert(edge.head)
                        markDownstream(edge.head)
                    }
                }
            }
            for r in roots where r != rootId { markDownstream(r) }
        }

        let graph = RuntimeGraph(config: config, nodes: nodes, nodeIds: nodeIds, edges: edges, edgeIds: edgeIds, inEdges: inEdges,
                                 outEdges: outEdges, rootId: rootId, executionTypes: types, initiallySkippedNodes: skippedNodes,
                                 initiallySkippedEdges: skippedEdges)
        try graph.validate()
        return graph
    }

    /// The default validators: edge endpoints exist, the root is a root (or a container's start node).
    func validate() throws {
        var issues: [(String, String)] = []
        for id in edgeIds {
            let e = edges[id]!
            if nodes[e.tail] == nil { issues.append(("MISSING_NODE", "Edge \(id) references unknown source node '\(e.tail)'.")) }
            if nodes[e.head] == nil { issues.append(("MISSING_NODE", "Edge \(id) references unknown target node '\(e.head)'.")) }
        }
        if let root = nodes[rootId], executionType(rootId) != .root,
           root.nodeType != NodeType.iterationStart, root.nodeType != NodeType.loopStart {
            issues.append(("INVALID_ROOT", "Root node '\(rootId)' must declare execution type 'root'."))
        }
        if !issues.isEmpty { throw ValidationError(issues: issues) }
    }

    /// Dify's `get_default_root_node_id`: the first start-like node.
    public static func defaultRootId(_ config: GraphConfig) throws -> String {
        guard let n = config.nodes.first(where: { NodeType.startTypes.contains($0.type) }) else {
            throw GraphConfig.Invalid(description: "Unable to determine default root node ID from workflow graph")
        }
        return n.id
    }
}
