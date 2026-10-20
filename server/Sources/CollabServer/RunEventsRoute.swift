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
        let includeSnapshot = query["include_state_snapshot"] != "false"
        let continueOnPause = query["continue_on_pause"] == "true"
        let terminal = ["succeeded", "failed", "stopped", "partial-succeeded"].contains(run.status)

        // A run this process is executing: its channel already holds every frame, replay included, so following it is the
        // snapshot. Nothing is rebuilt and nothing is duplicated.
        if !terminal, run.status != "paused", let live = await runChannels.existing(runId) {
            let subscription = await live.subscribe()
            return try Self.streaming(subscription, headers: Self.eventHeaders)
        }

        // A paused run (or one this process does not execute): subscribe first — creating the channel if the resume will
        // need it — then rebuild the state from the records.
        let live = run.status == "paused" && continueOnPause ? await runChannels.channel(runId) : await runChannels.existing(runId)
        let subscription = await live?.subscribe()

        // A finished run: one frame and close, as Dify does — no snapshot, nothing will ever follow.
        if terminal {
            return try Self.streaming([RunExecution.sse(try finishedFrame(run))])
        }
        var snapshot: [String] = []
        if includeSnapshot {
            snapshot = try await snapshotFrames(run, paused: run.status == "paused")
        }
        let closeAtPause = run.status == "paused" && !continueOnPause
        if closeAtPause || subscription == nil {
            return try Self.streaming(snapshot)
        }
        let replay = snapshot
        let body = try Response.Body(stream: { writer in
            for frame in replay { try await writer.write(frame) }
            if let subscription {
                for await frame in subscription { try await writer.write(frame) }
            }
        }, count: nil)
        return Response(status: .ok, headers: Self.eventHeaders, body: body)
    }

    /// The state rebuilt from the records: the run's start, one pair of frames per recorded node execution, and, for a
    /// paused run, the forms still waiting with the pause that names them.
    private func snapshotFrames(_ run: StoredWorkflowRun, paused: Bool) async throws -> [String] {
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
        if paused, let pause = (try? await store.openPauses(workflowRunId: run.id))?.first ?? nil {
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
        return frames
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
