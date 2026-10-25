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
    var formIds: Set<String>
    /// The pause the snapshot described, by its database generation: a later pause is another generation and must not be
    /// filtered by this one (two resumes can re-pause inside the same second).
    var pauseGeneration: Int?
    var chat: StoredChatMessage? = nil
}

struct ChatReasoningCursor: Sendable {
    var nodeId: String
    var bytes: Int
}

extension Routes {
    func registerRunEvents(on r: any RoutesBuilder) {
        r.get("v1", "workflow", ":runId", "events") { req in
            await handle(req) { try await workflowRunEvents(req) }
        }
    }

    private func workflowRunEvents(_ req: Request) async throws -> Response {
        guard let runId = req.parameters.get("runId"), !runId.isEmpty,
              let run = try await store.workflowRun(id: runId) else { throw ServerError.notFound }
        if run.endUserId != nil {
            let caller = try await publicCaller(req)
            guard run.docId == caller.app.id, run.endUserId == caller.endUser.id else { throw ServerError.notFound }
        } else {
            let p = try await authenticate(req)
            guard run.createdBy == p.id else { throw ServerError.notFound }
        }
        let query = query(req)
        // Dify's default is no snapshot: a client asking only for live events must not receive history.
        let includeSnapshot = query["include_state_snapshot"] == "true"
        let continueOnPause = query["continue_on_pause"] == "true"

        // A run that already ended is answered from its record **before** any live channel exists: a query for history
        // must not allocate a channel and a keep-alive pinger that nothing would ever close.
        if ["succeeded", "failed", "stopped", "partial-succeeded"].contains(run.status) {
            // One frame and close, whatever was asked: there is nothing left to follow.
            return try Self.streaming(try await terminalFrames(run))
        }

        // Subscribe first, then read the persisted state; the frames published from the mark on are the window this
        // response has to reconcile with the snapshot.
        let live = await runChannels.channel(runId, pingSeconds: config.ssePingSeconds)
        let mark = await live.published
        // TEST ONLY (`testDefect: slowStateRead`): widen the window between subscribing and reading the persisted state, so
        // a test can end the run inside it instead of racing.
        if config.testDefect == "slowStateRead" { try? await Task.sleep(for: .milliseconds(400)) }
        let state = try await store.workflowRun(id: runId) ?? run
        let terminal = ["succeeded", "failed", "stopped", "partial-succeeded"].contains(state.status)

        if terminal {
            // The run ended between this read and the subscription: one frame and close — and the channel this request
            // allocated is released here, or it would keep a pinger for a run nobody can follow any more.
            await live.finish()
            await runChannels.remove(runId)
            return try Self.streaming(try await terminalFrames(state))
        }

        var snapshot = SnapshotFrames(frames: [], nodeIds: [], formIds: [], pauseGeneration: nil)
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
        let body = try Response.Body(stream: { writer in
            for frame in replay { try await writer.write(frame) }
            var index = mark
            for await frame in subscription {
                let isWindow = index < coveredUpTo
                let generation = await live.pauseGeneration(at: index)
                let chatOffset = await live.chatOffset(at: index)
                let reasoning = await live.chatReasoning(at: index)
                index += 1
                guard let reconciled = Self.reconcileChatFrame(frame, snapshot: covered, answerOffset: chatOffset, reasoning: reasoning) else { continue }
                if isWindow && Self.isCovered(reconciled, snapshot: covered, pauseGeneration: generation) { continue }
                try await writer.write(reconciled)
                if frame.contains("\"event\":\"message_end\"") { break }
                if state.type != "chat" && frame.contains("\"event\":\"workflow_finished\"") { break }
                if frame.contains("\"event\":\"workflow_paused\"") && !continueOnPause { break }
            }
        }, count: nil)
        return Response(status: .ok, headers: Self.eventHeaders, body: body)
    }

    /// Coverage belongs to the durable text revision, not its publication time. A chunk can be committed before the
    /// snapshot read and published after `coveredUpTo`; its monotonic byte cursor still proves it is already included.
    static func reconcileChatFrame(_ frame: String, snapshot: SnapshotFrames, answerOffset: Int?, reasoning: ChatReasoningCursor?) -> String? {
        guard let message = snapshot.chat else { return frame }
        if let answerOffset, answerOffset <= message.answer.utf8.count { return nil }
        if let reasoning, let text = (try? JSONValue.parse(message.reasoning))?[reasoning.nodeId]?.string,
           reasoning.bytes <= text.utf8.count {
            guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
                  var value = (try? JSONValue.parse(Data(line.dropFirst(6).utf8)))?.object,
                  var data = value["data"]?.object, data["is_final"]?.bool == true else { return nil }
            // Preserve completion of reasoning without appending the same last text a second time.
            data["reasoning"] = ""; value["data"] = .object(data)
            return RunExecution.sse(.object(value))
        }
        return frame
    }

    /// Whether a live frame repeats something the snapshot already carried.
    static func isCovered(_ frame: String, snapshot: SnapshotFrames, pauseGeneration: Int?) -> Bool {
        guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
              let parsed = try? JSONValue.parse(Data(line.dropFirst(6).utf8)),
              let event = parsed["event"]?.string else { return false }
        switch event {
        case "workflow_paused":
            // Only the pause this snapshot described, identified by its generation on the channel.
            if let described = snapshot.pauseGeneration, let pauseGeneration, described == pauseGeneration { return true }
        case "human_input_required":
            if let formId = parsed["data"]?["form_id"]?.string, snapshot.formIds.contains(formId) { return true }
        case "node_started", "node_finished":
            if let id = parsed["data"]?["id"]?.string, snapshot.nodeIds.contains(id) { return true }
        default:
            break
        }
        return false
    }

    /// The state rebuilt from the records: the run's start, one pair of frames per recorded node execution, and, for a
    /// paused run, the forms still waiting with the pause that names them.
    private func snapshotFrames(_ run: StoredWorkflowRun, paused: Bool) async throws -> SnapshotFrames {
        var frames: [String] = []
        let account: JSONValue = run.endUserId.map { ["id": .string($0)] } ?? ["id": .string(run.createdBy ?? ""), "name": .string(run.createdByName ?? ""),
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
                                             "inputs": (e.inputs.flatMap { try? JSONValue.parse($0) }) ?? .object([:]),
                                             "inputs_truncated": false,
                                             "outputs": (e.outputs.flatMap { try? JSONValue.parse($0) }) ?? .object([:]),
                                             "execution_metadata": e.executionMetadata.flatMap { try? JSONValue.parse($0) } ?? [:],
                                             "outputs_truncated": false, "error": e.error.map(JSONValue.string) ?? .null,
                                             "elapsed_time": .double(e.elapsedTime),
                                             "created_at": .int(Int(start.timeIntervalSince1970)),
                                             "finished_at": .int(Int(finished.timeIntervalSince1970))]]))
        }
        for session in try await store.agentTraceSessions(run: run.id) {
            let usage = try JSONValue.parse(session.usage)
            if !executions.contains(where: { $0.id == session.executionID }), let started = usage["node_started"],
               started["id"] == .string(session.executionID), started["node_id"] == .string(session.nodeID) {
                frames.append(RunExecution.sse(["event": "node_started", "workflow_run_id": .string(run.id),
                                               "task_id": .string(run.id), "data": started]))
            }
            for log in usage["agent_log"]?.array ?? [] {
                frames.append(RunExecution.sse(["event": "agent_log", "workflow_run_id": .string(run.id), "data": log]))
            }
        }
        var pauseGeneration: Int?
        var waiting: [StoredHumanInputForm] = []
        if paused, let pause = (try? await store.openPauses(workflowRunId: run.id))?.first ?? nil {
            pauseGeneration = pause.generation
            let forms = (try? await store.humanInputForms(workflowRunId: run.id)) ?? []
            for form in forms where form.status == .waiting && pause.executionIds.contains(form.executionId) {
                waiting.append(await refreshedHumanInputForm(form, pause: pause, run: run))
            }
            for form in waiting {
                frames.append(RunExecution.sse(["event": "human_input_required", "workflow_run_id": .string(run.id),
                                        "task_id": .string(run.id),
                                        "data": RunStreamEncoder.humanInputRequiredData(
                                            form, inputs: Self.resolvedInputs(form, pauseSnapshot: pause.snapshot))]))
            }
            // The same projection the live stream uses, so the two paths cannot drift.
            frames.append(RunExecution.sse(["event": "workflow_paused", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                                    // Dify's replay reports the pause with the run's own start and no elapsed time: its
                                    // converter stamps the replay's clock when the snapshot is built, so the resumed
                                    // round's clock only appears on the live frame. The outputs are the record's.
                                    // The reasons carry the same resolved inputs the live pause sent (an iteration item's
                                    // select options included), so a reconnect shows what the pause showed.
                                    "data": RunStreamEncoder.workflowPausedData(
                                        runId: run.id, forms: waiting, stats: pauseStats(pause),
                                        createdAt: run.createdAt, elapsed: 0,
                                        inputs: waiting.map { Self.resolvedInputs($0, pauseSnapshot: pause.snapshot) })]))
        }
        var projected: [String] = []
        for frame in frames {
            guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
                  let value = try? JSONValue.parse(Data(line.dropFirst(6).utf8)) else { projected.append(frame); continue }
            projected.append(RunExecution.sse(await projectRuntimeFiles(value, userId: run.executionAccountId ?? run.createdBy ?? "", endUserId: run.endUserId)))
        }
        let chat = try await store.chatMessage(runId: run.id)
        if let chat {
            projected = projected.map { frame in
                guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
                      var value = (try? JSONValue.parse(Data(line.dropFirst(6).utf8)))?.object else { return frame }
                value["conversation_id"] = .string(chat.conversationId); value["message_id"] = .string(chat.id)
                return RunExecution.sse(.object(value))
            }
            projected.append(RunExecution.sse(await chatReplaceFrame(chat)))
        }
        return SnapshotFrames(frames: projected, nodeIds: Set(executions.map(\.id)), formIds: Set(waiting.map(\.id)),
                              pauseGeneration: pauseGeneration, chat: chat)
    }

    /// Ends a run that has **no engine** to report it: a paused run the user stopped, a pause whose resume could not be
    /// prepared, a run past its global deadline, an app's waiting runs when it is deleted. The durable row is written
    /// first by the caller (the store), then this publishes exactly one `workflow_finished` on the run's channel and
    /// releases it, so a connection that is already attached ends here instead of waiting for frames nobody will send.
    @discardableResult
    func finishRunWithoutEngine(_ runId: String) async -> Bool {
        guard let run = try? await store.workflowRun(id: runId) else { return false }
        let terminal: JSONValue
        do { terminal = try await finishedFrame(run) } catch { return false }
        let channel = await runChannels.channel(runId, pingSeconds: config.ssePingSeconds)
        try? await store.closeChatTurn(runId: runId)
        await channel.publish(RunExecution.sse(terminal))
        if let chat = try? await store.chatMessage(runId: runId) {
            await channel.publish(RunExecution.sse(await chatEndFrame(chat)))
        }
        await channel.finish()
        await runChannels.remove(runId)
        return true
    }

    func terminalFrames(_ run: StoredWorkflowRun) async throws -> [String] {
        var frames: [String] = []
        if let message = try await store.chatMessage(runId: run.id) {
            frames.append(RunExecution.sse(await chatReplaceFrame(message)))
            frames.append(RunExecution.sse(try await finishedFrame(run)))
            frames.append(RunExecution.sse(await chatEndFrame(message)))
        } else { frames.append(RunExecution.sse(try await finishedFrame(run))) }
        return frames
    }

    /// The outputs and totals a pause carried, as the live frame reports them (the pause row keeps both).
    private func pauseStats(_ pause: StoredWorkflowPause) -> GraphRunStats {
        GraphRunStats(outputs: (try? JSONValue.parse(pause.outputs))?.object ?? [:], totalTokens: pause.totalTokens,
                      totalSteps: pause.totalSteps)
    }

    func finishedFrame(_ run: StoredWorkflowRun) async throws -> JSONValue {
        let account: JSONValue = run.endUserId.map { ["id": .string($0)] } ?? ["id": .string(run.createdBy ?? ""), "name": .string(run.createdByName ?? ""),
                                  "email": .string(run.createdByEmail ?? "")]
        var terminal: JSONObject = ["event": "workflow_finished", "workflow_run_id": .string(run.id), "task_id": .string(run.id),
                "data": ["id": .string(run.id), "workflow_id": .string(run.workflowId), "status": .string(run.status),
                         "outputs": (try? JSONValue.parse(run.outputs ?? "{}")) ?? .object([:]),
                         "error": run.error.map(JSONValue.string) ?? .null, "elapsed_time": .double(run.elapsedTime),
                         "total_tokens": .int(run.totalTokens), "total_steps": .int(run.totalSteps),
                         "created_by": account, "created_at": .int(Int(run.createdAt.timeIntervalSince1970)),
                         "finished_at": run.finishedAt.map { .int(Int($0.timeIntervalSince1970)) } ?? .null,
                         "exceptions_count": .int(run.exceptionsCount), "files": []]]
        if let chat = try await store.chatMessage(runId: run.id) {
            terminal["message_id"] = .string(chat.id); terminal["conversation_id"] = .string(chat.conversationId)
            terminal["created_at"] = .int(Int(chat.createdAt.timeIntervalSince1970))
        }
        return await projectRuntimeFiles(.object(terminal), userId: run.executionAccountId ?? run.createdBy ?? "", endUserId: run.endUserId)
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
