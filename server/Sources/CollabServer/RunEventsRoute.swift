import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// `GET /v1/workflow/{runId}/events` — Dify's reconnect endpoint (protocol 1.16).
///
/// Winnie's scheme, which this follows: subscribe to the live channel **first**, then rebuild the state from what is
/// stored (the run, its node executions, its pause and forms); there is no table of frames. A run this process is not
/// executing is served from those records alone, and one that already ended answers a single `workflow_finished` and
/// closes. `close_on_pause` (the default) ends the stream at the pause, so a client reconnects again after the resume;
/// `continue_on_pause=true` keeps it open across the resume.
/// What a snapshot describes, so a reconnect can drop exactly the live frames it already sent.
struct SnapshotFrames: Sendable {
    var frames: [String]
    var nodeIds: Set<String>
    var pause: Bool
}

extension Routes {
    func registerRunEvents(on r: any RoutesBuilder) {
        r.get("v1", "workflow", ":runId", "events") { req in
            await handle(req) { try await workflowRunEvents(req) }
        }
    }

    private func workflowRunEvents(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        guard let runId = req.parameters.get("runId"), !runId.isEmpty,
              let run = try await store.workflowRun(id: runId),
              // Dify's events endpoint is narrower than the run detail: only the account that created the run.
              run.createdBy == p.id else {
            throw ServerError.notFound
        }
        let query = query(req)
        // Dify's default is no snapshot: a client asking only for live events must not receive history.
        let includeSnapshot = query["include_state_snapshot"] == "true"
        let continueOnPause = query["continue_on_pause"] == "true"

        // Subscribe first, then read the persisted state; the frames published from the mark on are the window this
        // response has to reconcile with the snapshot.
        let live = await runChannels.channel(runId)
        let mark = await live.published
        let state = try await store.workflowRun(id: runId) ?? run
        let terminal = ["succeeded", "failed", "stopped", "partial-succeeded"].contains(state.status)

        if terminal {
            // One frame and close, whatever was asked: there is nothing left to follow.
            return try Self.streaming([RunExecution.sse(try finishedFrame(state))])
        }

        var snapshot = SnapshotFrames(frames: [], nodeIds: [], pause: false)
        if includeSnapshot {
            snapshot = try await snapshotFrames(state, paused: state.status == "paused")
        }
        if state.status == "paused" && !continueOnPause {
            return try Self.streaming(snapshot.frames)
        }

        // Everything published before the snapshot was built is already described by it; everything after is new. Only the
        // buffered window is filtered, so a later pause or a later node execution is never swallowed.
        let coveredUpTo = await live.published
        let subscription = await live.subscribe(replay: true, from: mark)
        let replay = snapshot.frames
        let covered = snapshot
        let window = coveredUpTo - mark
        let body = try Response.Body(stream: { writer in
            for frame in replay { try await writer.write(frame) }
            var consumed = 0
            for await frame in subscription {
                let isWindow = consumed < window
                consumed += 1
                if isWindow && Self.isCovered(frame, snapshot: covered) { continue }
                try await writer.write(frame)
                if frame.contains("\"event\":\"workflow_finished\"") { break }
                if frame.contains("\"event\":\"workflow_paused\"") && !continueOnPause { break }
            }
        }, count: nil)
        return Response(status: .ok, headers: Self.eventHeaders, body: body)
    }

    /// Whether a live frame repeats something the snapshot already carried.
    static func isCovered(_ frame: String, snapshot: SnapshotFrames) -> Bool {
        guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
              let parsed = try? JSONValue.parse(Data(line.dropFirst(6).utf8)),
              let event = parsed["event"]?.string else { return false }
        if snapshot.pause && event == "workflow_paused" { return true }
        if event == "node_started" || event == "node_finished",
           let id = parsed["data"]?["id"]?.string, snapshot.nodeIds.contains(id) { return true }
        return false
    }

    /// The state rebuilt from the records: the run's start, one pair of frames per recorded node execution, and, for a
    /// paused run, the forms still waiting with the pause that names them.
    private func snapshotFrames(_ run: StoredWorkflowRun, paused: Bool) async throws -> SnapshotFrames {
        var frames: [String] = []
        let account: JSONValue = ["id": .string(run.createdBy ?? ""), "name": .string(run.createdByName ?? ""),
                                  "email": .string(run.createdByEmail ?? "")]
        frames.append(RunExecution.sse(["event": "workflow_started", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                                "data": ["id": .string(run.id), "workflow_id": .string(run.workflowId),
                                         "inputs": (try? JSONValue.parse(run.inputs)) ?? .object([:]),
                                         "created_at": .int(Int(run.createdAt.timeIntervalSince1970)), "created_by": account,
                                         "reason": "initial"]]))
        let executions = (try? await store.nodeExecutions(doc: run.docId, run: run.id)) ?? []
        for e in executions {
            let finished = e.finishedAt ?? run.finishedAt ?? run.createdAt
            let start = finished.addingTimeInterval(-e.elapsedTime)
            frames.append(RunExecution.sse(["event": "node_started", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                                    "data": ["id": .string(e.id), "node_id": .string(e.nodeId), "node_type": .string(e.nodeType),
                                             "title": .string(e.title), "index": .int(e.index), "created_at": .int(Int(start.timeIntervalSince1970))]]))
            frames.append(RunExecution.sse(["event": "node_finished", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                                    "data": ["id": .string(e.id), "node_id": .string(e.nodeId), "node_type": .string(e.nodeType),
                                             "title": .string(e.title), "index": .int(e.index), "status": .string(e.status),
                                             "inputs": (e.inputs.flatMap { try? JSONValue.parse($0) }) ?? .object([:]), "inputs_truncated": false,
                                             "outputs": (e.outputs.flatMap { try? JSONValue.parse($0) }) ?? .object([:]), "outputs_truncated": false,
                                             "error": e.error.map(JSONValue.string) ?? .null, "elapsed_time": .double(e.elapsedTime),
                                             "created_at": .int(Int(start.timeIntervalSince1970)),
                                             "finished_at": .int(Int(finished.timeIntervalSince1970))]]))
        }
        var coveredNodes = Set<String>()
        for e in executions { coveredNodes.insert(e.id) }
        var coveredPause = false
        if paused, let pause = (try? await store.openPauses(workflowRunId: run.id))?.first ?? nil {
            coveredPause = true
            let forms = (try? await store.humanInputForms(workflowRunId: run.id)) ?? []
            let waiting = forms.filter { $0.status == .waiting && pause.executionIds.contains($0.executionId) }
            for form in waiting {
                frames.append(RunExecution.sse(["event": "human_input_required", "workflow_run_id": .string(run.id),
                                        "task_id": .string(run.id), "data": [
                                            "form_id": .string(form.id), "node_id": .string(form.nodeId),
                                            "node_title": .string(form.nodeTitle), "form_content": .string(form.formContent),
                                            "inputs": (try? JSONValue.parse(form.inputs)) ?? .array([]),
                                            "actions": (try? JSONValue.parse(form.actions)) ?? .array([]),
                                            "display_in_ui": .bool(form.displayInUi), "form_token": .string(form.token),
                                            "approval_channels": .array([]),
                                            "resolved_default_values": form.resolvedDefaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
                                            "expiration_time": form.expirationTime.map { .int($0) } ?? .null]]))
            }
            frames.append(RunExecution.sse(["event": "workflow_paused", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                                    "data": ["workflow_run_id": .string(run.id),
                                             "paused_nodes": .array(waiting.map { .object(["node_id": .string($0.nodeId),
                                                                                             "node_title": .string($0.nodeTitle),
                                                                                             "form_id": .string($0.id)]) }),
                                             "reasons": .array(waiting.map { .object(["TYPE": .string("human_input_required"),
                                                                                      "node_id": .string($0.nodeId)]) }),
                                             "outputs": .object([:]), "status": "paused",
                                             "created_at": .double(pause.createdAt.timeIntervalSince1970),
                                             "elapsed_time": .double(pause.elapsedTime),
                                             "total_tokens": .int(pause.totalTokens), "total_steps": .int(pause.totalSteps)]]))
        }
        return SnapshotFrames(frames: frames, nodeIds: coveredNodes, pause: coveredPause)
    }

    private func finishedFrame(_ run: StoredWorkflowRun) throws -> JSONValue {
        let account: JSONValue = ["id": .string(run.createdBy ?? ""), "name": .string(run.createdByName ?? ""),
                                  "email": .string(run.createdByEmail ?? "")]
        return ["event": "workflow_finished", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                "data": ["id": .string(run.id), "workflow_id": .string(run.workflowId), "status": .string(run.status),
                         "outputs": (try? JSONValue.parse(run.outputs ?? "{}")) ?? .object([:]),
                         "error": run.error.map(JSONValue.string) ?? .null, "elapsed_time": .double(run.elapsedTime),
                         "total_tokens": .int(run.totalTokens), "total_steps": .int(run.totalSteps),
                         "created_by": account, "created_at": .int(Int(run.createdAt.timeIntervalSince1970)),
                         "finished_at": run.finishedAt.map { .int(Int($0.timeIntervalSince1970)) } ?? .null,
                         "exceptions_count": .int(run.exceptionsCount), "files": []]]
    }

    static var eventHeaders: HTTPFields {
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
        return headers
    }

    static func streaming(_ frames: [String]) throws -> Response {
        let body = try Response.Body(stream: { writer in
            for frame in frames { try await writer.write(frame) }
        }, count: nil)
        return Response(status: .ok, headers: eventHeaders, body: body)
    }

    static func streaming(_ frames: AsyncStream<String>, headers: HTTPFields) throws -> Response {
        let body = try Response.Body(stream: { writer in
            for await frame in frames { try await writer.write(frame) }
        }, count: nil)
        return Response(status: .ok, headers: headers, body: body)
    }
}
