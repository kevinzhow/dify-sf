import CollabRuntime
import CollabStore
import Foundation
import Vapor
import HTTPTypes

enum AgentTrace {
    static func redacted(_ value: JSONValue, secrets: [String], depth: Int = 0) -> JSONValue {
        guard depth < 40 else { return "[truncated]" }
        if let text = value.string {
            return .string(secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") })
        }
        if let array = value.array { return .array(array.map { redacted($0, secrets: secrets, depth: depth + 1) }) }
        if let object = value.object {
            var safe = JSONObject()
            for (key, value) in object {
                let label = secrets.filter { !$0.isEmpty }.reduce(key) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
                safe[label] = redacted(value, secrets: secrets, depth: depth + 1)
            }
            return .object(safe)
        }
        return value
    }

    static func project(run: String, node: String, event: Int, name: String, data: JSONObject, secrets: [String]) -> (record: JSONValue, log: JSONValue?) {
        let terminal = ["succeeded", "paused", "failed", "cancelled"].contains(name)
        let safe = redacted(.object(terminal ? JSONObject(data.filter { ["status", "error_type", "usage"].contains($0.key) }) : data), secrets: secrets)
        let key = "\(run):\(event)"
        let record: JSONValue = ["event_key": .string(key), "event": .string(name), "data": safe]
        guard ["thought", "tool_call", "model_call", "error"].contains(name) else { return (record, nil) }
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
        let inserted = try await store.appendAgentEvent(session: session, event: "\(run):\(event)",
            record: JSONValue.array([projected.record]).compactJSON(), log: projected.log.map { JSONValue.array([$0]).compactJSON() })
        if inserted, let log = projected.log, let channel = await runChannels.existing(session.workflowRunID) {
            await channel.publish(RunExecution.sse(["event": "agent_log", "workflow_run_id": .string(session.workflowRunID), "data": log]))
        }
    }
}


extension Routes {
    static let agentLogPreviewBytes = 256 << 10

    static func agentRecordPath(_ session: StoredAgentSession) -> String {
        "/v1/apps/\(session.docID)/workflow-runs/\(session.workflowRunID)/agent-records/\(session.executionID).jsonl"
    }

    /// UI records are bounded; the full redacted archive remains a downloadable, authorization-checked JSONL file.
    /// Stop at a complete JSON/UTF-8 record boundary. Never turn truncation into an execution failure.
    func agentLogPreview(_ session: StoredAgentSession) async throws -> JSONValue {
        let path = Self.agentRecordPath(session)
        let marker: JSONValue = ["message_id": .string(session.executionID + ":truncated"), "node_id": .string(session.nodeID),
            "label": "Record truncated", "status": "success", "data": ["truncated": true, "full_record_url": .string(path)],
            "metadata": ["event": "truncated"], "parent_id": .null]
        let reserve = marker.compactJSON().utf8.count + 2
        var logs: [JSONValue] = [], bytes = 2, after = 0
        while true {
            let rows = try await store.agentEventRecords(execution: session.executionID, after: after)
            if rows.isEmpty { return .array(logs) }
            for row in rows {
                after = row.ordinal
                guard let raw = row.log else { continue }
                for log in try JSONValue.parse(raw).array ?? [] {
                    let size = log.compactJSON().utf8.count + 1
                    if bytes + size + reserve > Self.agentLogPreviewBytes {
                        logs.append(marker)
                        return .array(logs)
                    }
                    logs.append(log); bytes += size
                }
            }
        }
    }

    func registerAgentRecords(on r: any RoutesBuilder) {
        r.get("v1", "apps", ":app", "workflow-runs", ":run", "agent-records", ":record") { req in
            await handle(req) {
                let user = try await self.authenticate(req)
                let app = try await self.appOfMode(req, user, ["workflow"])
                guard let run = req.parameters.get("run"), let filename = req.parameters.get("record"), filename.hasSuffix(".jsonl"),
                      let session = try await self.store.agentSession(execution: String(filename.dropLast(6))),
                      session.docID == app.id, session.workflowRunID == run,
                      try await self.store.workflowRun(doc: app.id, id: run) != nil else { throw ServerError.notFound }
                let store = self.store, execution = session.executionID
                let body = try Response.Body(stream: { writer in
                    var after = 0
                    while true {
                        try Task.checkCancellation()
                        let rows = try await store.agentEventRecords(execution: execution, after: after)
                        if rows.isEmpty { return }
                        for row in rows {
                            for record in try JSONValue.parse(row.record).array ?? [] { try await writer.write(record.compactJSON() + "\n") }
                            after = row.ordinal
                        }
                    }
                }, count: nil)
                return Response(status: .ok, headers: [.contentType: "application/x-ndjson; charset=utf-8",
                    .contentDisposition: "attachment; filename=agent-record.jsonl", .cacheControl: "no-store"], body: body)
            }
        }
    }
}
