import CollabRuntime
import CollabStore
import Foundation

enum AgentTrace {
    static func redacted(_ value: JSONValue, secrets: [String], depth: Int = 0) -> JSONValue {
        guard depth < 40 else { return "[truncated]" }
        if let text = value.string {
            return .string(secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") })
        }
        if let array = value.array { return .array(array.map { redacted($0, secrets: secrets, depth: depth + 1) }) }
        if let object = value.object { return .object(JSONObject(object.map { ($0.key, redacted($0.value, secrets: secrets, depth: depth + 1)) })) }
        return value
    }

    static func project(run: String, node: String, event: Int, name: String, data: JSONObject, secrets: [String]) -> (record: JSONValue, log: JSONValue?) {
        let terminal = ["succeeded", "paused", "failed", "cancelled"].contains(name)
        let safe = redacted(.object(terminal ? JSONObject(data.filter { ["status", "error_type", "usage"].contains($0.key) }) : data), secrets: secrets)
        let key = "\(run):\(event)"
        let record: JSONValue = ["event_key": .string(key), "event": .string(name), "data": safe]
        guard ["thought", "tool_call", "usage", "error"].contains(name) else { return (record, nil) }
        let label = name == "tool_call" ? (data["name"]?.string ?? "Tool") : name
        let log: JSONValue = ["message_id": .string(key), "node_id": .string(node), "label": .string(label),
            "status": name == "error" ? "failed" : (data["phase"] == "started" ? "start" : "success"),
            "data": safe, "metadata": ["event": .string(name), "event_id": .int(event)], "parent_id": .null]
        return (record, log)
    }
}

extension Routes {
    func recordAgentEvent(session: StoredAgentSession, run: String, event: Int, name: String, data: JSONObject, secrets: [String]) async throws {
        let projected = AgentTrace.project(run: run, node: session.nodeID, event: event, name: name, data: data, secrets: secrets)
        try await store.appendAgentEvent(session: session, event: "\(run):\(event)",
            record: JSONValue.array([projected.record]).compactJSON(), log: projected.log.map { JSONValue.array([$0]).compactJSON() })
        if let log = projected.log, let channel = await runChannels.existing(session.workflowRunID) {
            await channel.publish(RunExecution.sse(["event": "agent_log", "workflow_run_id": .string(session.workflowRunID), "data": log]))
        }
    }
}
