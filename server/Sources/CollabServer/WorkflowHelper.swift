// Planner -> per-node builder port of fixed Dify 8387590 generator/runner.py. All proposed data is validated,
// never executed or written by generation. The editor applies it via the normal optimistic DSL replacement.
import CollabRuntime
import Foundation

extension HelperGenerator {
    func generateWorkflow(body: JSONValue, instruction: String) async throws -> JSONValue {
        let requested = body["mode"]?.string ?? "workflow"
        guard ["workflow", "advanced-chat", "auto"].contains(requested) else { throw NodeError("GeneratorInputError", "Invalid workflow mode") }
        let current = body["current_graph"] ?? .null
        let user = "# Mode\n\(requested)\n\n# User instruction\n\(instruction)\n\n# Existing graph\n\(current.compactJSON())\n\n# Ideal output\n\(body["ideal_output"]?.string ?? "")\n# Installed tools (no other tools are available)\n\(body["available_tools"]?.compactJSON() ?? "[]")\nReturn the JSON plan now."
        let plan = try Self.object(await invoke(system: WorkflowHelperPrompts.PLANNER_SYSTEM_PROMPT, text: user))
        guard let nodes = plan["nodes"]?.array, !nodes.isEmpty, nodes.count <= 50, let edges = plan["edges"]?.array, !edges.isEmpty else {
            throw NodeError("INVALID_GRAPH", "The planner must return 1–50 nodes and nonempty edges")
        }
        let ids = nodes.compactMap { $0["id"]?.string }
        guard ids.count == nodes.count, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else {
            throw NodeError("INVALID_GRAPH", "Planner node ids must be unique and nonempty")
        }
        let byId = Dictionary(uniqueKeysWithValues: zip(ids, nodes))
        let mode = requested == "auto" ? (nodes.contains { $0["node_type"]?.string == "answer" } ? "advanced-chat" : "workflow") : requested
        let terminal = mode == "advanced-chat" ? "answer" : "end"
        guard nodes.filter({ $0["node_type"]?.string == "start" }).count == 1,
              nodes.contains(where: { $0["node_type"]?.string == terminal }) else { throw NodeError("MISSING_TERMINAL", "Plan requires one start and a matching terminal") }
        for edge in edges {
            guard let source = edge["source"]?.string, let target = edge["target"]?.string,
                  byId[source] != nil, byId[target] != nil,
                  byId[source]?["parent"]?.string.flatMap({ $0.isEmpty ? nil : $0 }) == byId[target]?["parent"]?.string.flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw NodeError("DANGLING_EDGE", "Plan edges must connect existing nodes in the same container")
            }
        }
        // Detect cycles per scope before generating configurations; loops must use the loop container.
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted else { throw NodeError("CYCLE_DETECTED", "Use a loop container instead of a graph cycle") }
            for edge in edges where edge["source"]?.string == id { try visit(edge["target"]!.string!) }
            visiting.remove(id); visited.insert(id)
        }
        for id in ids { try visit(id) }
        var graphNodes: [JSONValue] = [], graphEdges: [JSONValue] = []
        let old = Dictionary((current["nodes"]?.array ?? []).compactMap { node in node["id"]?.string.map { ($0, node) } }, uniquingKeysWith: { _, b in b })
        for (index, node) in nodes.enumerated() {
            try Task.checkCancellation()
            let id = ids[index], type = node["node_type"]?.string ?? ""
            guard let snippet = WorkflowHelperPrompts.snippets[type] else { throw NodeError("UNKNOWN_NODE_TYPE", "No supported schema for \(type)") }
            var config: JSONObject
            if node["action"]?.string == "keep", let existing = old[id]?["data"]?.object {
                config = existing
            } else {
                let context: JSONValue = ["target": node, "instruction": .string(instruction), "mode": .string(mode),
                    "selected_model": ["provider": .string(model.provider), "name": .string(model.modelName), "mode": "chat", "completion_params": .object(model.parameters)],
                    "plan": plan, "available_tools":body["available_tools"] ?? [], "existing_config": old[id]?["data"] ?? .null, "ideal_output": body["ideal_output"] ?? .null]
                guard let built = try Self.object(await invoke(system: WorkflowHelperPrompts._NODE_BUILDER_HEAD + snippet, text: context.compactJSON()))["config"]?.object else {
                    throw NodeError("INVALID_GRAPH", "The node builder returned no config")
                }
                config = built
            }
            config["type"] = .string(type); config["title"] = node["label"] ?? .string(type)
            if type == "tool" {
                guard (body["available_tools"]?.array ?? []).contains(where: { tool in
                    tool["provider_id"] == config["provider_id"] && tool["tool_name"] == config["tool_name"] && tool["provider_type"] == (config["provider_type"] ?? "builtin")
                }) else { throw NodeError("UNKNOWN_TOOL","The generated tool is not installed or belongs to the current workflow") }
            }
            if ["llm", "question-classifier", "parameter-extractor"].contains(type) {
                config["model"] = ["provider": .string(model.provider), "name": .string(model.modelName), "mode": "chat", "completion_params": .object(model.parameters)]
            }
            if type == "start", let inputs = plan["start_inputs"]?.array, !inputs.isEmpty { config["variables"] = .array(inputs) }
            var wrapper: JSONObject = ["id": .string(id), "type": "custom", "data": .object(config),
                "position": old[id]?["position"] ?? ["x": .int(index * 320), "y": 0]]
            if let parent = node["parent"]?.string, !parent.isEmpty {
                guard let container = byId[parent]?["node_type"]?.string, ["iteration", "loop"].contains(container) else {
                    throw NodeError("INVALID_GRAPH", "A child must refer to an iteration/loop parent")
                }
                var ancestor: String? = parent, seen = Set([id])
                while let a = ancestor {
                    guard seen.insert(a).inserted else { throw NodeError("CYCLE_DETECTED", "Container parent cycle") }
                    ancestor = byId[a]?["parent"]?.string
                }
                wrapper["parentId"] = .string(parent); wrapper["extent"] = "parent"
                config[container == "iteration" ? "isInIteration" : "isInLoop"] = true
                config[container == "iteration" ? "iteration_id" : "loop_id"] = .string(parent)
                wrapper["data"] = .object(config)
            }
            graphNodes.append(.object(wrapper))
        }
        for edge in edges {
            let source = edge["source"]!.string!, target = edge["target"]!.string!
            graphEdges.append(["id": .string("\(source)-\(target)-\(graphEdges.count)"), "source": .string(source), "target": .string(target),
                "type": "custom", "sourceHandle": edge["source_handle"] ?? "source", "targetHandle": "target", "data": [:]])
        }
        // Container roots are an engine concern and cannot be invented by the model.
        for (index, node) in nodes.enumerated() where ["iteration", "loop"].contains(node["node_type"]?.string ?? "") {
            let id = ids[index], type = node["node_type"]!.string!, startId = id + "-start"
            guard !Set(ids).contains(startId) else { throw NodeError("INVALID_GRAPH", "Synthetic container start id collision") }
            let children = nodes.filter { $0["parent"]?.string == id }
            let roots = children.filter { child in !edges.contains { $0["target"]?.string == child["id"]?.string } }
            guard !children.isEmpty, !roots.isEmpty else { throw NodeError("INVALID_GRAPH", "Container requires executable children") }
            var wrapper = graphNodes[index].object!, config = wrapper["data"]!.object!
            config["start_node_id"] = .string(startId); wrapper["data"] = .object(config)
            wrapper["width"] = 800; wrapper["height"] = 400; graphNodes[index] = .object(wrapper)
            graphNodes.append(["id": .string(startId), "type": "custom", "parentId": .string(id), "extent": "parent", "position": ["x": 24, "y": 68],
                "data": ["type": .string(type + "-start"), "title": "", "desc": "", "isInIteration": .bool(type == "iteration"), "isInLoop": .bool(type == "loop"),
                         type == "iteration" ? "iteration_id" : "loop_id": .string(id)]])
            for root in roots {
                graphEdges.append(["id": .string(startId + "-" + root["id"]!.string!), "source": .string(startId), "target": root["id"]!, "sourceHandle": "source", "targetHandle": "target", "type": "custom", "data": [:]])
            }
        }
        let graph: JSONValue = ["nodes": .array(graphNodes), "edges": .array(graphEdges), "viewport": current["viewport"] ?? ["x": 0, "y": 0, "zoom": 1]]
        try Self.validateReferences(graph, ids:Set(graphNodes.compactMap { $0["id"]?.string }))
        let config = try GraphConfig(json: graph)
        let rootId = try RuntimeGraph.defaultRootId(config)
        _ = try await RuntimeGraph.build(config, rootId: rootId, factory: BuiltinNodeFactory(services: RuntimeServices()))
        return ["graph": graph, "mode": .string(mode), "message": plan["description"] ?? "", "app_name": plan["app_name"] ?? "", "icon": plan["icon"] ?? "", "error": "", "errors": []]
    }
    static func validateReferences(_ value: JSONValue, ids: Set<String>, key: String = "") throws {
        if let text=value.string {
            let regex=try NSRegularExpression(pattern:#"\{\{#([^.#]+)\."#)
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                if let range=Range(match.range(at:1),in:text) {
                    let id=String(text[range])
                    guard ids.contains(id) || ["sys","env","conversation"].contains(id) else { throw NodeError("UNKNOWN_NODE_REFERENCE","Unknown template node \(id)") }
                }
            }
        }
        if let array=value.array {
            if key.contains("selector"), let first=array.first?.string, !["sys","env","conversation"].contains(first), !ids.contains(first) {
                throw NodeError("UNKNOWN_NODE_REFERENCE","Unknown selector node \(first)")
            }
            for child in array { try validateReferences(child,ids:ids,key:key) }
        }
        if let object=value.object { for (name,child) in object { try validateReferences(child,ids:ids,key:name) } }
    }

}
