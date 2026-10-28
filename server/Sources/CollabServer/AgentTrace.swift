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
        let safe = redacted(.object(terminal ? JSONObject(data.filter { ["status", "error_type", "usage", "partial"].contains($0.key) }) : data), secrets: secrets)
        let key = "\(run):\(event)"
        let record: JSONValue = ["event_key": .string(key), "event": .string(name), "data": safe]
        guard ["run_started", "thought", "tool_call", "model_call", "progress", "budget_notice", "commentary", "plan", "model_retry", "compaction", "error"].contains(name) else { return (record, nil) }
        let label = name == "tool_call" ? (safe["name"]?.string ?? "Tool") : name
        let log: JSONValue = ["message_id": .string(key), "node_id": .string(node), "label": .string(label),
            "status": name == "error" ? "failed" : (data["phase"] == "started" ? "start" : "success"),
            "data": safe, "metadata": ["event": .string(name), "event_id": .int(event)], "parent_id": .null]
        return (record, log)
    }
}

/// Reasoning chunks are one logical stream. An incomplete secret prefix is masked
/// immediately, including its continuation in later events. This intentionally
/// over-redacts an ambiguous suffix rather than publishing it until a later event
/// proves it sensitive. No raw suffix is ever committed or broadcast.
struct AgentReasoningRedactor: Sendable {
    private struct Pattern: Sendable {
        let chars: [Unicode.Scalar]
        let failure: [Int]
        init(_ value: String) {
            chars = Array(value.unicodeScalars)
            var table = Array(repeating: 0, count: chars.count), matched = 0
            for index in chars.indices.dropFirst() {
                while matched > 0 && chars[index] != chars[matched] { matched = table[matched - 1] }
                if chars[index] == chars[matched] { matched += 1 }
                table[index] = matched
            }
            failure = table
        }
    }
    private let patterns: [Pattern]
    private var prefixes: [Int]

    init(secrets: [String]) {
        patterns = Array(Set(secrets.filter { !$0.isEmpty })).sorted().map(Pattern.init)
        prefixes = Array(repeating: 0, count: patterns.count)
    }

    mutating func redact(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        guard !chars.isEmpty else { return text }
        // KMP plus range-difference marking is linear per secret, including
        // adversarial overlapping matches and very long repetitive fragments.
        var ranges = Array(repeating: 0, count: chars.count + 1)
        for (index, pattern) in patterns.enumerated() {
            let secret = pattern.chars, previous = prefixes[index]
            var continuation = 0
            while previous > 0 && continuation < chars.count && previous + continuation < secret.count &&
                    chars[continuation] == secret[previous + continuation] { continuation += 1 }
            if continuation > 0 { ranges[0] += 1; ranges[continuation] -= 1 }
            var matched = previous
            for (position, char) in chars.enumerated() {
                while matched > 0 && secret[matched] != char { matched = pattern.failure[matched - 1] }
                if secret[matched] == char { matched += 1 }
                if matched == secret.count {
                    ranges[max(0, position - secret.count + 1)] += 1
                    ranges[position + 1] -= 1
                    matched = pattern.failure[matched - 1]
                }
            }
            prefixes[index] = matched
            if matched > 0 { ranges[max(0, chars.count - matched)] += 1; ranges[chars.count] -= 1 }
        }
        var result = "", inMask = false, coverage = 0
        for (index, char) in chars.enumerated() {
            coverage += ranges[index]
            if coverage > 0 {
                if !inMask { result += "[redacted]" }
                inMask = true
            } else { result.unicodeScalars.append(char); inMask = false }
        }
        return result
    }
}

/// One writer for the whole operation, across HTTP reconnections. Prepare state
/// by value and advance only after persistence succeeds, just like the SSE cursor.
actor AgentTraceWriter {
    private var reasoning: AgentReasoningRedactor
    let secrets: [String]
    init(secrets: [String]) { self.secrets = secrets; reasoning = .init(secrets: secrets) }

    func record(routes: Routes, session: StoredAgentSession, run: String, event: Int, name: String, data: JSONObject) async throws {
        var next = reasoning
        var safe = AgentTrace.redacted(.object(data), secrets: secrets).object ?? [:]
        if ["thought", "commentary"].contains(name), let text = data["text"]?.string { safe["text"] = .string(next.redact(text)) }
        try await routes.recordAgentEvent(session: session, run: run, event: event, name: name, data: safe, secrets: [])
        reasoning = next
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
        let reserve = marker.compactJSON().utf8.count + 4
        let budget = (Self.agentLogPreviewBytes - reserve) / 2
        var head: [JSONValue] = [], bytes = 0, after = 0, lastHead = 0, omitted = false
        headLoop: while true {
            let rows = try await store.agentEventRecords(execution: session.executionID, after: after)
            if rows.isEmpty { return .array(head) }
            for row in rows {
                after = row.ordinal
                guard let raw = row.log else { continue }
                let logs = try JSONValue.parse(raw).array ?? []
                let size = logs.reduce(0) { $0 + $1.compactJSON().utf8.count + 1 }
                if bytes + size > budget { omitted = true; break headLoop }
                head += logs; bytes += size; lastHead = row.ordinal
            }
        }
        var tail: [JSONValue] = [], tailBytes = 0, before = Int.max
        tailLoop: while true {
            let rows = try await store.agentEventRecordsBefore(execution: session.executionID, before: before)
            if rows.isEmpty { omitted = false; break }
            for row in rows {
                before = row.ordinal
                if row.ordinal <= lastHead { omitted = false; break tailLoop }
                guard let raw = row.log else { continue }
                let logs = try JSONValue.parse(raw).array ?? []
                let size = logs.reduce(0) { $0 + $1.compactJSON().utf8.count + 1 }
                if tailBytes + size > budget { break tailLoop }
                tail.insert(contentsOf: logs, at: 0); tailBytes += size
            }
        }
        return .array(head + (omitted ? [marker] : []) + tail)
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
