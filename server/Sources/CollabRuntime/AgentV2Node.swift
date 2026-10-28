// Dify 1.17.1 Agent v2 inline node. The server adapter owns durable operations, private configs and human forms.
import Foundation

public struct AgentNodeData: Sendable {
    public var base: BaseNodeData
    public var bindingID: String?
    public var agentID: String
    public var snapshotID: String
    public var task: String
    public var declarations: [AgentDeclaredOutput]
    public var modelInputs: AgentModelInputs
    public var raw: JSONObject

    public init(_ data: JSONObject) throws {
        guard data["version"] == "2", data["agent_node_kind"] == "dify_agent",
              data["agent_binding"]?["binding_type"] == "inline_agent" else {
            throw NodeDataError("Only inline Agent v2 nodes in workflows are supported")
        }
        guard let agent = data["agent_binding"]?["agent_id"]?.string, !agent.isEmpty,
              let snapshot = data["agent_binding"]?["current_snapshot_id"]?.string, !snapshot.isEmpty else {
            throw NodeDataError("An inline agent config is required")
        }
        if let task = data["agent_task"], task.string == nil { throw NodeDataError("agent_task must be text") }
        if let outputs = data["agent_declared_outputs"], outputs.array == nil {
            throw NodeDataError("agent_declared_outputs must be a list")
        }
        base = try BaseNodeData(data)
        agentID = agent; snapshotID = snapshot; bindingID = data["agent_binding"]?["id"]?.string
        task = data["agent_task"]?.string ?? ""
        guard task.utf8.count <= 256 << 10 else { throw NodeDataError("agent_task is too large") }
        declarations = try AgentDeclaredOutput.parse(data["agent_declared_outputs"]?.array ?? [])
        modelInputs = try AgentModelInputs(data["agent_model"])
        raw = data
    }

    public var outputSchema: JSONValue? {
        guard !declarations.isEmpty else { return nil }
        var properties: JSONObject = ["text": ["type": "string", "description": "Free-form text answer."]]
        var required: [JSONValue] = []
        for output in declarations {
            properties[output.name] = Self.schema(output.json)
            if output.required { required.append(.string(output.name)) }
        }
        return ["type": "object", "properties": .object(properties), "required": .array(required)]
    }

    static func schema(_ declaration: JSONObject) -> JSONValue {
        let type = declaration["type"]?.string ?? "string"
        var schema: JSONObject = ["type": .string(type == "file" ? "object" : type)]
        if let description = declaration["description"]?.string { schema["description"] = .string(description) }
        if type == "file" {
            schema["type"] = "string"
            schema["x-dify-sf-file"] = declaration["file"]?.object.map(JSONValue.object) ?? [:]
        }
        if type == "array" { schema["items"] = Self.schema(declaration["array_item"]?.object ?? ["type": "object"]) }
        if type == "object", let children = declaration["children"]?.array, !children.isEmpty {
            var properties: JSONObject = [:]
            var required: [JSONValue] = []
            for child in children {
                guard let object = child.object, let name = object["name"]?.string else { continue }
                properties[name] = Self.schema(object)
                if object["required"] != false { required.append(.string(name)) }
            }
            schema["properties"] = .object(properties); schema["required"] = .array(required)
        }
        return .object(schema)
    }

    /// Dify's Agent marker parser accepts actual workflow IDs, including hyphens. Reserved namespaces are not previous nodes.
    public static func selectors(_ task: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: #"\{\{#([^#]+)#\}\}"#)
        let reserved: Set<String> = ["sys", "env", "conversation", "rag", "current", "last_run", "error_message", "$output"]
        var seen = Set<[String]>()
        return regex.matches(in: task, range: NSRange(task.startIndex..., in: task)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: task) else { return nil }
            let parts = task[range].split(separator: ".").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard parts.count >= 2, !reserved.contains(parts[0]), seen.insert(parts).inserted else { return nil }
            return parts
        }
    }
}

public enum AgentNodeDecision: Sendable {
    case completed(NodeRunResult)
    /// The server has prepared one durable pending question; the engine must commit the whole pause before ACK.
    case pause(formID: String, usage: LLMUsage = .empty)
}

public protocol AgentRuntime: Sendable {
    func prepare(nodeID: String, data: AgentNodeData) async throws
    func run(nodeID: String, data: AgentNodeData, context: NodeRunContext) async throws -> AgentNodeDecision
}

public struct AgentV2Node: RuntimeNode {
    public var id: String
    public var data: AgentNodeData
    public var runtime: any AgentRuntime
    public var base: BaseNodeData { data.base }
    public var nodeType: String { "agent" }
    public var executionType: NodeExecutionType { .branch }

    public init(id: String, data: AgentNodeData, runtime: any AgentRuntime) {
        self.id = id; self.data = data; self.runtime = runtime
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        switch try await runtime.run(nodeID: id, data: data, context: context) {
        case .completed(let result): await emit(.completed(result))
        case .pause(let form, let usage):
            if usage.totalTokens > 0 { await emit(.usageDelta(usage)) }
            await emit(.pauseRequested(.hitlRequired(sessionId: form, nodeId: id, nodeTitle: base.title)))
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var seen = Set<[String]>()
        return (AgentNodeData.selectors(data.task) + data.modelInputs.selectors)
            .filter { seen.insert($0).inserted }.map { ("\(id)." + $0.joined(separator: "."), $0) }
    }
}
