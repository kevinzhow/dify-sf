import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Logging
import Synchronization
import Vapor

/// Whole draft runs (protocol 1.14): Dify 1.17.1's `POST /apps/{app}/workflows/draft/run` (an SSE stream in Dify's event
/// format), the stop command, the run history and a run's detail and node executions. A run reads the document at one
/// seq, runs the graph on the Swift engine (`CollabRuntime.GraphEngine`) in its own task (a client that goes away does
/// not stop it; the stop command does) and writes only run records (`workflow_runs`, `workflow_node_executions`), never
/// ops.
extension Routes {
    func registerRuns(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.post(":app", "workflows", "draft", "run") { req in await handle(req) { try await runDraft(req) } }
        apps.post(":app", "workflow-runs", "tasks", ":task", "stop") { req in await handle(req) { try await stopRun(req) } }
        apps.get(":app", "workflow-runs") { req in await handle(req) { try await listRuns(req) } }
    }

    /// The services nodes call: models (plugin daemon) when configured, the code sandbox (Jinja2 too) and HTTP through the
    /// SSRF proxy.
    func runtimeServices(appId: String) -> RuntimeServices {
        var services = config.runtimeServices.services(models: nil)
        if runtimeConfigured {
            let daemon = PluginDaemonClient(baseURL: config.pluginDaemonURL, key: config.pluginDaemonKey, tenant: config.pluginDaemonTenant,
                                            timeoutSeconds: config.pluginDaemonTimeoutSeconds)
            let routes = self
            services.models = PluginDaemonModelRuntime(daemon: daemon, credentialsOf: { provider, model, type in
                try await routes.currentCredentials(provider: provider, model: model, modelType: type)
            }, appId: appId)
        }
        return services
    }

    /// The services for one workflow run: `runtimeServices`, plus the human-input adapter bound to this run. The adapter
    /// needs the run id and the ledger the run persists from, so it cannot live in `runtimeServices` (which is shared by
    /// the single-node and container paths, and by graphs built before a run exists).
    func runServices(appId: String, runId: String, docId: String, userId: String, pending: PendingHumanInputForms,
                     decisions: [String: StoredHumanInputForm] = [:]) -> RuntimeServices {
        var services = runtimeServices(appId: appId)
        services.humanInput = ServerHumanInputRuntime(store: store, workflowRunId: runId, docId: docId, userId: userId,
                                                      pending: pending, decisions: decisions,
                                                      // Draft runs are Dify's debugger; published runs come with M5.
                                                      isDebugger: true)
        return services
    }

    /// Errors preparing a graph (before anything runs), as the single node run answers them.
    func preparationError(_ error: any Error) -> ServerError {
        switch error {
        case let e as UnsupportedNodeType:
            return .http(status: 400, code: "unsupported_node_type", message: e.description)
        case let e as ServiceNotConfigured where e.service == .models:
            return .http(status: 400, code: "model_runtime_not_configured",
                         message: "This server has no model runtime (COLLAB_PLUGIN_DAEMON_URL is not set)")
        case let e as ServiceNotConfigured:
            return .http(status: 400, code: "runtime_service_not_configured", message: e.description)
        case let e as NodeDataError: return Self.invalidParam(e.description)
        case let e as any NodeRunError: return Self.invalidParam(e.description)
        case let e as RuntimeGraph.ValidationError: return Self.invalidParam(e.description)
        case let e as GraphConfig.Invalid: return Self.invalidParam(e.description)
        case let e as WorkflowBootstrap.InvalidInput: return Self.invalidParam(e.description)
        case let e as ServerError: return e
        default: return .unavailable("\(error)")
        }
    }

    /// The draft at its current seq as Dify's workflow (graph, environment and conversation variables).
    func draftWorkflow(_ appId: String, viewer: String) async throws -> (seq: Int, workflow: JSONValue) {
        let snapshot = try await registry.sequencer(appId).currentSnapshot()
        let metadata = try await currentMetadata(appId, viewer: viewer)
        let secrets: [String: String]
        do { secrets = try await store.secrets(appId) } catch { throw ServerError.unavailable("\(error)") }
        let exported = try JSONValue.parse(try WireJSON.encode(try DifyDSL.exportValue(snapshot.doc, metadata: metadata, secrets: secrets)))
        return (snapshot.seq, exported["workflow"] ?? .null)
    }

    // MARK: - POST /v1/apps/{app}/workflows/draft/run

    /// `POST /v1/apps/{app}/workflows/draft/run` `{"inputs": {...}, "files": [...]}` (edit; workflow apps): Dify's draft run.
    /// Answers an SSE stream of Dify's events (`data: {...}` lines; `event: ping` while idle) until `workflow_finished`.
    private func runDraft(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, ["workflow"])
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw ServerError.badRequest("the body must be a JSON object")
        }
        guard let inputsValue = b["inputs"], inputsValue != .null else { throw Self.invalidParam("missing inputs") }
        guard case .object(let rawInputs) = inputsValue else { throw ServerError.badRequest("inputs must be an object") }
        if let files = b["files"], files != .null {
            guard case .array(let list) = files else { throw ServerError.badRequest("files must be a list") }
            if !list.isEmpty { throw Self.invalidParam("file inputs are not supported by this server yet") }
        }

        // One consistent read: the document at seq N, rendered as Dify's workflow.
        let (seq, workflow) = try await draftWorkflow(a.id, viewer: p.id)
        let runId = UUID().uuidString.lowercased()
        let prepared: PreparedRun
        let pending = PendingHumanInputForms()
        do {
            prepared = try await PreparedRun.make(workflow: workflow, rawInputs: rawInputs,
                                                  services: runServices(appId: a.id, runId: runId, docId: a.id, userId: p.id,
                                                                        pending: pending),
                                                  userId: p.id, appId: a.id, workflowId: a.id, runId: runId)
        } catch {
            throw preparationError(error)
        }

        return try await startRun(appId: a.id, principal: p, seq: seq, workflow: workflow, runId: runId, graph: prepared.graph,
                                  pool: prepared.pool, workflowInputs: prepared.workflowInputs, nodeTriggeredFrom: "workflow-run",
                                  pendingForms: pending)
    }

    /// Records the run (`workflow_runs`, `debugging`), starts it in its own task and answers its SSE stream.
    func startRun(appId: String, principal p: Principal, seq: Int, workflow: JSONValue, runId: String, graph: RuntimeGraph, pool: VariablePool,
                  workflowInputs: JSONObject, nodeTriggeredFrom: String,
                  pendingForms: PendingHumanInputForms = PendingHumanInputForms()) async throws -> Response {
        // Dify's task id is a separate uuid; here it is the run's id (clients read it from the events).
        let taskId = runId
        let account: JSONValue = ["id": .string(p.id), "name": .string(p.account.name), "email": .string(p.account.email)]
        var stored = StoredWorkflowRun(id: runId, docId: appId, docSeq: seq, workflowId: appId, type: "workflow", triggeredFrom: "debugging",
                                       version: "draft", graph: (workflow["graph"] ?? .null).compactJSON(),
                                       inputs: JSONValue.object(workflowInputs).compactJSON(), status: "running", createdBy: p.id,
                                       createdAt: Date())
        stored.createdByName = p.account.name
        do { try await store.insertWorkflowRun(stored) } catch { throw ServerError.unavailable("\(error)") }

        let channel = await runChannels.channel(runId, pingSeconds: config.ssePingSeconds)
        let commands = GraphEngineCommands()
        let lease = UUID().uuidString.lowercased()
        await runs.add(taskId, WorkflowRunRegistry.Active(appId: appId, runId: runId, commands: commands, lease: lease))
        let encoder = RunStreamEncoder(taskId: taskId, runId: runId, workflowId: appId, graph: graph, account: account,
                                       inputs: workflowInputs, startedAt: stored.createdAt)
        let engine = GraphEngine(graph: graph, config: GraphEngineConfig(maxWorkers: config.runtimeMaxWorkers,
                                                                        maxSteps: config.runtimeMaxSteps,
                                                                        maxTimeSeconds: config.runtimeMaxTimeSeconds),
                                 commands: commands, userId: p.id, appId: appId)
        let routes = self
        let execution = RunExecution(routes: routes, appId: appId, docSeq: seq, runId: runId, taskId: taskId, createdBy: p.id,
                                     channel: channel, encoder: encoder, triggeredFrom: nodeTriggeredFrom,
                                     pendingForms: pendingForms, lease: lease)
        Task.detached { await execution.run(engine: engine, pool: pool) }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
        let subscription = await channel.subscribe()
        let logger = self.logger
        let body = try Response.Body(stream: { writer in
            do {
                for await frame in subscription {
                    try await writer.write(frame)
                    // The run's channel stays open across a pause (the resumed round publishes into it), but this
                    // response ends with the pause as Dify's draft-run stream does.
                    if frame.contains("\"event\":\"workflow_paused\"") { break }
                }
            } catch {
                logger.debug("run stream \(runId) ended: \(error)")
                throw error
            }
        }, count: nil)
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: - Resume

    /// Resumes a paused run after an answer: claim it (one winner), rebuild the graph from the run's **stored** graph (never
    /// the draft that was edited since), rebuild the engine from the pause's snapshot and consume the resumed stream.
    /// Returns false when there was nothing to claim (not paused, no unconsumed answer, already resumed or stopped).
    @discardableResult
    func resumeRun(appId: String, runId: String) async -> Bool {
        // TEST ONLY (`testDefect: slowClaim`): widen the window between an accepted answer and the claim that consumes it,
        // so a test can kill the process there — the state a crash leaves behind (answer waiting, pause untouched).
        if config.testDefect == "slowClaim" { try? await Task.sleep(for: .milliseconds(1500)) }
        guard let claim = try? await store.claimResume(workflowRunId: runId, at: Date()) else { return false }
        // The claim already made the run `running`: a run we cannot read would stay there forever, and its subscribers
        // would wait for a round nobody starts.
        guard let run = try? await store.workflowRun(doc: appId, id: runId) else {
            try? await store.finishWorkflowRun(id: runId, status: "failed", outputs: nil, error: "the claimed run could not be read",
                                               elapsedTime: 0, totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
            await finishRunWithoutEngine(runId)
            return false
        }
        // TEST ONLY (`testDefect: resumePrepFails`): a resume whose preparation fails must end the run as failed and
        // release the claim's state, not leave a `running` run nothing will finish.
        if config.testDefect == "resumePrepFails" {
            try? await store.finishWorkflowRun(id: runId, status: "failed", outputs: nil,
                                               error: "the resumed run's preparation failed", elapsedTime: 0,
                                               totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
            await finishRunWithoutEngine(runId)
            return false
        }
        guard let graphJSON = try? JSONValue.parse(Data(run.graph.utf8)) else {
            // The claim already made the run `running`: leaving it there would be a run that never finishes.
            try? await store.finishWorkflowRun(id: runId, status: "failed", outputs: nil,
                                               error: "the paused run's stored graph does not parse",
                                               elapsedTime: 0, totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
            await finishRunWithoutEngine(runId)
            return false
        }
        let decisions = Dictionary(uniqueKeysWithValues: claim.decisions.map { ($0.executionId, $0) })
        let pending = PendingHumanInputForms()
        let userId = run.createdBy ?? ""
        let graph: RuntimeGraph
        do {
            let config = try GraphConfig(json: graphJSON)
            let rootId = try RuntimeGraph.defaultRootId(config)
            graph = try await RuntimeGraph.build(config, rootId: rootId,
                                                 factory: BuiltinNodeFactory(services: runServices(
                                                    appId: appId, runId: runId, docId: appId, userId: userId, pending: pending,
                                                    decisions: decisions)))
        } catch {
            logger.error("run \(runId) could not rebuild its graph: \(error)")
            try? await store.finishWorkflowRun(id: runId, status: "failed", outputs: nil, error: "could not rebuild the paused run: \(error)",
                                               elapsedTime: 0, totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
            await finishRunWithoutEngine(runId)
            return false
        }
        let account: JSONValue = ["id": .string(userId), "name": .string(run.createdByName ?? ""), "email": .string(run.createdByEmail ?? "")]
        let inputs = (try? JSONValue.parse(run.inputs))?.object ?? [:]
        var encoder = RunStreamEncoder(taskId: runId, runId: runId, workflowId: appId, graph: graph, account: account,
                                       inputs: inputs, startedAt: run.createdAt)
        // `elapsed_time` counts from the round (the resume), while `created_at` stays the run's original creation.
        encoder.roundStartedAt = Date()
        let commands = GraphEngineCommands()
        let engine = GraphEngine(graph: graph, config: GraphEngineConfig(maxWorkers: config.runtimeMaxWorkers,
                                                                        maxSteps: config.runtimeMaxSteps,
                                                                        maxTimeSeconds: config.runtimeMaxTimeSeconds),
                                 commands: commands, userId: userId, appId: appId)
        let snapshot: GraphEngineSnapshot
        do { snapshot = try GraphEngineSnapshot(data: Data(claim.pause.snapshot.utf8)) } catch {
            logger.error("run \(runId) has a pause snapshot that does not decode: \(error)")
            try? await store.finishWorkflowRun(id: runId, status: "failed", outputs: nil,
                                               error: "the paused run's snapshot does not decode: \(error)",
                                               elapsedTime: 0, totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
            await finishRunWithoutEngine(runId)
            return false
        }
        let channel = await runChannels.channel(runId, pingSeconds: config.ssePingSeconds)
        // The resumed round owns the task id from here: `stop` must find this engine, not the one that paused.
        let lease = UUID().uuidString.lowercased()
        await runs.add(runId, WorkflowRunRegistry.Active(appId: appId, runId: runId, commands: commands, lease: lease))
        let routes = self
        let execution = RunExecution(routes: routes, appId: appId, docSeq: run.docSeq, runId: runId, taskId: runId,
                                     createdBy: userId, channel: channel, encoder: encoder, triggeredFrom: "workflow-run",
                                     pendingForms: pending, lease: lease, decisions: claim.decisions)
        // TEST ONLY (`testDefect: slowResume`): hold the resumed round after it took the run over, so a test can stop it
        // while it is the run's round and prove the stop reaches this engine.
        if config.testDefect == "slowResume" { try? await Task.sleep(for: .milliseconds(300)) }
        Task.detached { await execution.run(engine: engine, pool: VariablePool(), snapshot: snapshot, filled: claim.decisions) }
        return true
    }

    /// One pass of the human-input timeout scan (`HumanInputTimeouts`): node deadlines first (the run goes on through the
    /// node's `__timeout` branch), then the global deadline (the run stops and its connection ends).
    @discardableResult
    func sweepHumanInputTimeouts(now: Date) async -> (timedOut: Int, expired: Int) {
        // TEST ONLY (`collab.test.clockSkewSeconds`): the scan's clock can be moved forward, so a test exercises the
        // production scan with a real form written an hour in the future rather than calling the store in its place.
        let at = now.addingTimeInterval(Double(config.testClockSkewSeconds))
        var timedOut = 0, expired = 0
        if let forms = try? await store.waitingFormsPastDeadline(at: at) {
            for form in forms {
                guard (try? await store.endHumanInputForm(token: form.token, status: .timedOut, at: at)) == true else { continue }
                timedOut += 1
                // The pause is now woken (`resume_requested`), and the run takes the timeout branch — in the background,
                // as an answer does.
                if let runId = form.workflowRunId {
                    let appId = form.docId, routes = self
                    Task.detached { await routes.resumeRun(appId: appId, runId: runId) }
                }
            }
        }
        let error = "Human input form timed out"
        if let runs = try? await store.pausedRunsPastGlobalDeadline(at: at, timeoutSeconds: config.humanInputGlobalTimeoutSeconds) {
            for run in runs {
                guard (try? await store.expireRunForGlobalTimeout(workflowRunId: run.runId, error: error, at: at)) == true else { continue }
                expired += 1
                await finishRunWithoutEngine(run.runId)
            }
        }
        return (timedOut, expired)
    }

    /// Picks up the runs a stopped server left answered-but-paused. Called once the routes exist; each one goes through the
    /// same `resumeRun`, so a restart is just another resume (and a run whose answer arrived while the server was down is
    /// not lost).
    func resumeRunsWaitingAfterRestart() async -> Int {
        guard let waiting = try? await store.runsAwaitingResume() else { return 0 }
        for run in waiting {
            logger.info("resuming run \(run.runId) after a restart")
            await resumeRun(appId: run.docId, runId: run.runId)
        }
        return waiting.count
    }

    // MARK: - Stop

    /// `POST /v1/apps/{app}/workflow-runs/tasks/{task}/stop` (edit; workflow and chatflow apps): Dify's stop command
    /// (`AbortCommand("User requested stop")`); `{"result": "success"}` also for tasks that are not running (as Dify).
    private func stopRun(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        guard let task = req.parameters.get("task"), !task.isEmpty, task.utf8.count <= 255 else { throw ServerError.badRequest("invalid task id") }
        if let active = await runs.get(task), active.appId == a.id {
            active.commands.abort(reason: "User requested stop")
        } else {
            // A paused run has no engine to abort: its pause must be closed and its forms closed, or a later submission
            // would wake a run the user already stopped. Then the subscribers hear it end (`workflow_finished` stopped)
            // and the channel is released — a durable terminal state alone leaves a live connection waiting forever.
            let stopped = (try? await store.stopPausedRun(workflowRunId: task, error: "User requested stop", at: Date())) ?? false
            if stopped { await finishRunWithoutEngine(task) }
        }
        return rawJSON(["result": "success"])
    }

    // MARK: - History and records

    /// `GET /v1/apps/{app}/workflow-runs?last_id=&limit=&status=&triggered_from=` (any member; workflow and chatflow apps):
    /// Dify's `WorkflowRunPaginationResponse`, newest first (draft runs: `triggered_from` `debugging`, the default).
    private func listRuns(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let q = queryAll(req)
        let limit = try queryInt(q, "limit", 20, 1...100)
        let triggered = q["triggered_from"]?.last.flatMap { $0.isEmpty ? nil : $0 } ?? "debugging"
        guard ["debugging", "app-run"].contains(triggered) else { throw Self.invalidParam("triggered_from must be debugging or app-run") }
        let status = q["status"]?.last.flatMap { $0.isEmpty ? nil : $0 }
        if let status, !Self.runStatuses.contains(status) {
            throw Self.invalidParam("status must be one of \(Self.runStatuses.joined(separator: ", "))")
        }
        let lastId = q["last_id"]?.last.flatMap { $0.isEmpty ? nil : $0 }
        if let lastId, UUID(uuidString: lastId) == nil { throw Self.invalidParam("last_id must be a UUID") }
        let page: (runs: [StoredWorkflowRun], hasMore: Bool)?
        do { page = try await store.workflowRuns(doc: a.id, triggeredFrom: triggered, status: status, limit: limit, lastId: lastId) } catch {
            throw ServerError.unavailable("\(error)")
        }
        guard let page else { throw Self.invalidParam("Last workflow run not exists") }
        let data: [JSONValue] = page.runs.map { r in
            [
                "id": .string(r.id), "version": .string(r.version), "status": .string(r.status), "elapsed_time": .double(r.elapsedTime),
                "total_tokens": .int(r.totalTokens), "total_steps": .int(r.totalSteps), "created_by_account": Self.accountJSON(r),
                "created_at": Self.epochSeconds(r.createdAt), "finished_at": r.finishedAt.map(Self.epochSeconds) ?? .null,
                "exceptions_count": .int(r.exceptionsCount), "retry_index": .null,
            ]
        }
        return rawJSON(["limit": .int(limit), "has_more": .bool(page.hasMore), "data": .array(data)])
    }

    /// `GET /v1/apps/{app}/workflow-runs/{run}` (any member): Dify's `WorkflowRunDetailResponse`; `404` "Workflow run not found".
    func workflowRunDetail(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let a = try await appOfMode(req, p, Self.workflowModes)
        guard let id = req.parameters.get("run") else { throw ServerError.missing("Workflow run not found") }
        let found: StoredWorkflowRun?
        do { found = try await store.workflowRun(doc: a.id, id: id.lowercased()) } catch { throw ServerError.unavailable("\(error)") }
        guard let r = found else { throw ServerError.missing("Workflow run not found") }
        func parsed(_ text: String?) -> JSONValue { text.flatMap { try? JSONValue.parse($0) } ?? .null }
        let detail: JSONValue = [
            "id": .string(r.id), "version": .string(r.version), "graph": parsed(r.graph), "inputs": parsed(r.inputs),
            "status": .string(r.status), "outputs": r.outputs.map { parsed($0) } ?? .object([:]), "error": r.error.map(JSONValue.string) ?? .null,
            "elapsed_time": .double(r.elapsedTime), "total_tokens": .int(r.totalTokens), "total_steps": .int(r.totalSteps),
            "created_by_role": r.createdBy == nil ? .null : "account", "created_by_account": Self.accountJSON(r), "created_by_end_user": .null,
            "created_at": Self.epochSeconds(r.createdAt), "finished_at": r.finishedAt.map(Self.epochSeconds) ?? .null,
            "exceptions_count": .int(r.exceptionsCount),
        ]
        return rawJSON(detail)
    }

    /// `GET /v1/apps/{app}/workflow-runs/{run}/node-executions` (any member): `{"data": [WorkflowRunNodeExecutionResponse]}`,
    /// oldest first; `{"data": []}` for an unknown run (as Dify).
    func workflowRunNodeExecutions(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let a = try await appOfMode(req, p, Self.workflowModes)
        guard let id = req.parameters.get("run") else { return rawJSON(["data": []]) }
        let list: [StoredNodeExecution]
        do { list = try await store.nodeExecutions(doc: a.id, run: id.lowercased()) } catch { throw ServerError.unavailable("\(error)") }
        return rawJSON(["data": .array(list.flatMap(RetryHistory.traces))])
    }

    static func epochSeconds(_ d: Date) -> JSONValue { .int(Int(d.timeIntervalSince1970.rounded(.down))) }

    static func accountJSON(_ r: StoredWorkflowRun) -> JSONValue {
        guard let id = r.createdBy else { return .null }
        return ["id": .string(id), "name": .string(r.createdByName ?? ""), "email": .string(r.createdByEmail ?? "")]
    }
}

extension Routes {
    /// Saves a run's node outputs as draft variables (the variable inspect panel).
    func saveRunDraftVariables(appId: String, userId: String, docSeq: Int, nodeId: String, nodeType: String, executionId: String,
                               status: String, result: NodeRunResult) async {
        // Dify saves succeeded and exception results, with the outputs as a run projects them (a start node: its inputs).
        guard status == "succeeded" || status == "exception" else { return }
        let outputs = nodeType == NodeType.start ? result.inputs : result.outputs
        do {
            try await saveDraftVariables(appId: appId, userId: userId, docSeq: docSeq, nodeId: nodeId, nodeType: nodeType,
                                         executionId: executionId, processData: result.processData, outputs: outputs)
        } catch {
            logger.error("saving draft variables of \(executionId) failed: \(error)")
        }
    }
}

// MARK: - Preparing a run

/// A graph ready to run with its pool (Dify's `WorkflowAppGenerator.generate` + `WorkflowAppRunner.run` up to the engine).
struct PreparedRun: Sendable {
    var graph: RuntimeGraph
    var pool: VariablePool
    /// The run's inputs as Dify stores and streams them: the user inputs and `sys.*`.
    var workflowInputs: JSONObject

    static func make(workflow: JSONValue, rawInputs: JSONObject, services: RuntimeServices, userId: String, appId: String,
                     workflowId: String, runId: String, query: String? = nil) async throws -> PreparedRun {
        let config = try GraphConfig(json: workflow["graph"] ?? .null)
        let rootId = try RuntimeGraph.defaultRootId(config)
        let graph = try await RuntimeGraph.build(config, rootId: rootId, factory: BuiltinNodeFactory(services: services))
        let variables = (graph.node(rootId) as? StartNode)?.variables ?? []
        let inputs = try WorkflowBootstrap.prepareUserInputs(rawInputs, variables: variables)
        var systemValues: [(String, JSONValue?)] = [("files", .array([])), ("user_id", .string(userId)), ("app_id", .string(appId)),
                                                    ("timestamp", .int(Int(Date().timeIntervalSince1970))),
                                                    ("workflow_id", .string(workflowId)), ("workflow_execution_id", .string(runId))]
        if let query { systemValues.insert(("query", .string(query)), at: 0) }
        let system = WorkflowBootstrap.systemVariables(systemValues)
        let environment = try (workflow["environment_variables"]?.array ?? []).map(WorkflowBootstrap.variable)
        let conversation = try (workflow["conversation_variables"]?.array ?? []).map(WorkflowBootstrap.variable)
        let pool = try WorkflowBootstrap.pool(system: system, environment: environment, conversation: conversation, rootId: rootId,
                                              inputs: inputs)
        var workflowInputs = inputs
        for (k, v) in system where k != "conversation_id" { workflowInputs["sys.\(k)"] = v }
        return PreparedRun(graph: graph, pool: pool, workflowInputs: workflowInputs)
    }
}

// MARK: - Running

/// One run in its task: engine events -> Dify's SSE frames (to the channel) and run records.
final class RunExecution: Sendable {
    let routes: Routes
    let appId: String
    let docSeq: Int
    let runId: String
    let taskId: String
    let createdBy: String
    let channel: RunChannel
    let encoderBox: Mutex<RunStreamEncoder>
    /// The forms the engine asked for during this run; the pause persists them before publishing anything.
    let pendingForms: PendingHumanInputForms
    /// The node executions' `triggered_from` (Dify: `workflow-run`; an iteration or loop single run: `single-step`).
    let triggeredFrom: String
    /// This round's ownership of the registry entry (see `WorkflowRunRegistry.remove`).
    let lease: String
    /// The answers this round's claim took; a filled frame is published when their node succeeds.
    let decisions: [StoredHumanInputForm]

    init(routes: Routes, appId: String, docSeq: Int, runId: String, taskId: String, createdBy: String, channel: RunChannel,
         encoder: RunStreamEncoder, triggeredFrom: String = "workflow-run",
         pendingForms: PendingHumanInputForms = PendingHumanInputForms(), lease: String = "",
         decisions: [StoredHumanInputForm] = []) {
        self.routes = routes
        self.appId = appId
        self.docSeq = docSeq
        self.runId = runId
        self.taskId = taskId
        self.createdBy = createdBy
        self.channel = channel
        encoderBox = Mutex(encoder)
        self.triggeredFrom = triggeredFrom
        self.pendingForms = pendingForms
        self.lease = lease
        self.decisions = decisions
    }

    /// A started node not finished yet (for its record and the end of the run).
    struct Running: Sendable {
        var nodeId: String
        var nodeType: String
        var title: String
        var startAt: Date
        var index: Int
        var scope: NodeScope
    }

    /// Consumes a run's event stream. `snapshot` resumes a paused run instead of starting one; `filled` are the answers the
    /// resume took, published as `human_input_form_filled` right after the engine's `workflow_started(reason=resumption)`.
    func run(engine: GraphEngine, pool: VariablePool, snapshot: GraphEngineSnapshot? = nil,
             filled: [StoredHumanInputForm] = []) async {
        let started = ContinuousClock.now
        // The round continues the run's numbering: a resumed round's executions follow the ones already stored, so the
        // history keeps its order and no index repeats. A failure to read it starts at the run's own count (0).
        var index = (try? await routes.store.maxNodeExecutionIndex(doc: appId, run: runId)) ?? 0
        /// False when the round ended at a pause: the run is still alive, so its channel is not finished.
        var endedWithoutPause = true
        var running: [String: Running] = [:]
        // `_append_retry_history`: the failed attempts of a node execution, kept in its process data.
        var retries: [String: [JSONValue]] = [:]
        let stream: AsyncStream<GraphEngineEvent>
        if let snapshot {
            do { stream = try engine.resume(snapshot) } catch {
                routes.logger.error("run \(runId) could not resume: \(error)")
                // Durable first, then the one terminal frame and the channel's end (`finishRunWithoutEngine`), so an
                // attached connection does not wait for a round that never started.
                try? await routes.store.finishWorkflowRun(id: runId, status: "failed", outputs: nil,
                                                          error: "could not resume the paused run: \(error)", elapsedTime: 0,
                                                          totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
                await routes.finishRunWithoutEngine(runId)
                await routes.runs.remove(taskId, lease: lease)
                return
            }
        } else {
            stream = engine.run(pool: pool)
        }
        var announcedFilled = false
        var filledPublished = Set<String>()
        for await event in stream {
            if case .runResumed = event, !announcedFilled {
                announcedFilled = true
                var frames = encoderBox.withLock { $0.encode(event) }
                // A timed-out form is announced with the resume; a filled one is announced when its node succeeds
                // (`boundary.py` emits it from the node, with the rendered content the completion produced).
                frames += encoderBox.withLock { enc in
                    decisions.filter { $0.status == .timedOut }.map { enc.humanInputFormTimeout($0) }
                }
                for f in frames { await channel.publish(Self.sse(f)) }
                continue
            }
            if case .runPaused(let reasons, let snapshot, let stats) = event {
                // The round did not end: the run is paused and its channel must survive into the next round — unless the
                // pause could not be written, which ends the run as failed.
                endedWithoutPause = !(await handlePause(reasons: reasons, snapshot: snapshot, stats: stats))
                continue
            }
            // `boundary.py` publishes the filled (or timeout) frame first and forwards the node's own frames after it.
            if case .node(.succeeded(let x, let nodeId, _, _, let r)) = event,
               let decision = decisions.first(where: { $0.executionId == x && $0.status == .submitted }),
               // Dify reports an answered form once; an execution that succeeds more than once (a rebuilt round can
               // replay its own success) must not put the same filled frame on the wire twice.
               filledPublished.insert(x).inserted {
                let filled = encoderBox.withLock { enc in
                    enc.humanInputFormFilled(nodeId: nodeId, nodeTitle: decision.nodeTitle,
                                             renderedContent: r.outputs["__rendered_content"]?.string ?? decision.renderedContent,
                                             actionId: r.outputs["__action_id"]?.string ?? (decision.submittedAction ?? ""),
                                             actionText: r.outputs["__action_value"]?.string ?? "",
                                             submittedData: r.inputs)
                }
                await channel.publish(Self.sse(filled))
            }
            let frames = encoderBox.withLock { $0.encode(event) }
            for f in frames { await channel.publish(Self.sse(f)) }
            switch event {
            case .node(.started(let x, let nodeId, let type, let title, let startAt, let scope)):
                index += 1
                running[x] = Running(nodeId: nodeId, nodeType: type, title: title, startAt: startAt, index: index, scope: scope)
            case .node(.retry(let x, let nodeId, let startAt, let r, let error, let retryIndex)):
                let now = Date()
                let type = running[x]?.nodeType ?? ""
                retries[x, default: []].append([
                    "retry_index": .int(retryIndex), "inputs": .object(r.inputs), "process_data": .object(r.processData),
                    "outputs": .object(type == NodeType.start ? r.inputs : r.outputs), "error": .string(r.error.isEmpty ? error : r.error),
                    "elapsed_time": .double(max(now.timeIntervalSince(startAt), 0)), "execution_metadata": .object(r.metadata),
                    "created_at": .int(Int(startAt.timeIntervalSince1970.rounded(.down))), "finished_at": .int(Int(now.timeIntervalSince1970.rounded(.down))),
                ])
                _ = nodeId
            case .node(.succeeded(let x, let nodeId, _, let finishedAt, let r)):
                await persist(x, nodeId, running.removeValue(forKey: x), "succeeded", r, error: nil, finishedAt: finishedAt,
                              retries: retries.removeValue(forKey: x))
            case .node(.failed(let x, let nodeId, _, let finishedAt, let r, let error)):
                await persist(x, nodeId, running.removeValue(forKey: x), "failed", r, error: error.isEmpty ? r.error : error, finishedAt: finishedAt,
                              retries: retries.removeValue(forKey: x))
            case .node(.exception(let x, let nodeId, _, let finishedAt, let r, let error)):
                await persist(x, nodeId, running.removeValue(forKey: x), "exception", r, error: error.isEmpty ? r.error : error,
                              finishedAt: finishedAt, retries: retries.removeValue(forKey: x))
            case .runSucceeded(let s), .runPartialSucceeded(let s):
                let status: String = { if case .runSucceeded = event { return "succeeded" }; return "partial-succeeded" }()
                await finish(status: status, error: nil, stats: s, started: started, running: running)
            case .runFailed(let error, let s):
                await finish(status: "failed", error: error, stats: s, started: started, running: running)
            case .runAborted(let reason, let s):
                await finish(status: "stopped", error: reason, stats: s, started: started, running: running)
            default: break
            }
        }
        if endedWithoutPause {
            // The run's channel lives as long as the run, not as long as one round: a pause keeps it so a reconnect (or the
            // resumed round) publishes into the same stream.
            await channel.finish()
            await routes.runChannels.remove(runId)
        }
        await routes.runs.remove(taskId, lease: lease)
    }

    /// The pause, in the order Dify's `WorkflowResponseConverter` implies: the snapshot, the forms and the run's state are
    /// durable **first**, and only then do `human_input_required` and `workflow_paused` reach the stream. If the write fails
    /// the run ends as failed with that error: publishing a pause nobody can answer, or carrying on past human input, would
    /// both be worse than stopping.
    @discardableResult
    private func handlePause(reasons: [PauseReason], snapshot: GraphEngineSnapshot, stats: GraphRunStats) async -> Bool {
        let sessionIds = reasons.compactMap { reason -> String? in
            if case .hitlRequired(let sessionId, _, _) = reason { return sessionId }
            return nil
        }
        let prepared = pendingForms.takePrepared(sessionIds)
        let forms = prepared.map(\.form)
        let at = Date()
        var generation = 0
        do {
            // TEST ONLY (`testDefect: pauseWriteFails`): a pause that cannot be written must end the run and run the
            // terminal cleanup, never leave a channel or a paused run behind.
            if routes.config.testDefect == "pauseWriteFails" {
                struct PauseWriteFailed: Error {}
                throw PauseWriteFailed()
            }
            let encoded = String(decoding: try snapshot.encoded(), as: UTF8.self)
            generation = try await routes.store.createPause(
                workflowRunId: runId, docId: appId, nodeId: forms.first?.nodeId ?? "", snapshot: encoded,
                totalTokens: stats.totalTokens, totalSteps: stats.totalSteps,
                elapsedTime: encoderBox.withLock { at.timeIntervalSince($0.roundStartedAt) },
                outputs: JSONValue.object(stats.outputs).compactJSON(), forms: forms, at: at)
        } catch {
            // A pause for a deleted app is a stop, not a failure: the user deleted the app, nothing broke.
            let appDeleted = (error as? PostgresStore.PauseRefused) == .appDeleted
            let status = appDeleted ? "stopped" : "failed"
            let message = appDeleted ? "The app was deleted" : "could not persist the paused run: \(error)"
            routes.logger.error("run \(runId) could not persist its pause: \(error)")
            // Durable first, then the frame (Dify's public stream has no `workflow_failed`: a failure is
            // `workflow_finished` with `status: failed`).
            try? await routes.store.finishWorkflowRun(id: runId, status: status, outputs: nil, error: message,
                                                      elapsedTime: at.timeIntervalSince(encoderBox.withLock { $0.roundStartedAt }),
                                                      totalTokens: stats.totalTokens, totalSteps: stats.totalSteps,
                                                      exceptionsCount: 0, finishedAt: at)
            let frames = encoderBox.withLock { enc in
                [enc.workflowFinished(status, error: message, stats: stats, exceptions: 0)]
            }
            for f in frames { await channel.publish(Self.sse(f)) }
            // The run is over: the caller must run its terminal cleanup (channel, registry).
            return false
        }
        // A variable-backed select's options come from the pause's own pool (Dify's `resolve_variable_select_input_options`
        // over the resumed state), so the client gets concrete options rather than a selector it cannot read.
        let pool = snapshot.variablePool()
        let resolvedInputs: [[JSONObject]?] = forms.map { form in
            guard let pool, let config = try? Routes.formConfig(form) else { return nil }
            return config.inputsResolved(pool: pool)
        }
        let frames = encoderBox.withLock { enc in
            forms.enumerated().map { i, form in enc.humanInputRequired(form, inputs: resolvedInputs[i]) }
                + [enc.workflowPaused(forms, reasons: reasons, stats: stats, at: at, inputs: resolvedInputs)]
        }
        for f in frames { await channel.publish(Self.sse(f), pauseGeneration: generation) }
        // The email delivery, after the pause is durable (Dify's mail task runs after the form exists): each recipient gets
        // their own link, and a delivery that already happened is not repeated (a restart, or a later pause adopting the
        // same waiting form). Best effort: a failure is logged and never unwinds a pause.
        await prepareAndDeliverHumanInputMail(prepared, pool: snapshot.variablePool())
        // An answer for another execution of this pause may have been taken while the pause was being written: the pause
        // starts awake, and since no new submission will come to wake it, the resume is enqueued here.
        let stored = (try? await routes.store.pause(workflowRunId: runId, generation: generation)) ?? nil
        if stored?.resumeRequested == true {
            let routes = self.routes
            let app = appId
            let run = runId
            Task.detached { await routes.resumeRun(appId: app, runId: run) }
        }
        return true
    }

    /// The email delivery of a pause (Dify's `mail_human_input_delivery_task`): every recipient of an enabled email method
    /// becomes a row of its own with its own link token, and every row that was never mailed gets one mail now. A node
    /// names member recipients by account id (`reference_id`), so the workspace's members are read here.
    private func prepareAndDeliverHumanInputMail(_ prepared: [PendingHumanInputForms.Prepared],
                                                 pool: VariablePool? = nil) async {
        let outbox = MailOutbox(sender: SMTPMailSender(config: routes.config.mail), logger: routes.logger)
        guard outbox.isEnabled else { return }
        let members: [String: String]
        do {
            members = Dictionary(uniqueKeysWithValues: try await routes.store.members().map { ($0.id, $0.email) })
        } catch {
            routes.logger.warning("human input mail skipped: the workspace's members could not be read (\(error))")
            return
        }
        var methodsByForm: [String: [JSONObject]] = [:]
        for entry in prepared {
            let recipients = HumanInputMail.recipients(entry.deliveryMethods, members: members)
            guard !recipients.isEmpty else { continue }
            methodsByForm[entry.form.id] = entry.deliveryMethods
            let now = Date()
            var rows: [StoredFormRecipient] = []
            for recipient in recipients {
                // A waiting form adopted by a later pause keeps the tokens it already handed out.
                rows.append(StoredFormRecipient(
                    token: UUID().uuidString.lowercased(), formId: entry.form.id, workflowRunId: entry.form.workflowRunId ?? "",
                    methodIndex: recipient.method, type: recipient.type, referenceId: recipient.referenceId,
                    email: recipient.email, createdAt: now))
            }
            do { try await routes.store.addFormRecipients(rows) } catch {
                routes.logger.warning("human input mail skipped: the recipients of \(entry.form.id) could not be stored (\(error))")
            }
        }
        guard !methodsByForm.isEmpty else { return }
        guard let base = Optional(routes.config.webAppBaseURL), !base.isEmpty else {
            routes.logger.warning("human input mail skipped: COLLAB_WEBAPP_BASE_URL is not set (no form link)")
            return
        }
        let pending: [StoredFormRecipient]
        do { pending = try await routes.store.formRecipientsAwaitingMail() } catch { return }
        for row in pending {
            guard let methods = methodsByForm[row.formId] else { continue }
            guard let link = HumanInputMail.link(base: base, token: row.token) else { continue }
            guard let message = HumanInputMail.message(methods, methodIndex: row.methodIndex, to: row.email, link: link,
                                                       pool: pool) else { continue }
            // Marked only after the mail went out, so a failure is retried by the next pause or scan instead of lost.
            if await outbox.send(message, kind: "human input") {
                try? await routes.store.markFormRecipientMailed(token: row.token, at: Date())
            }
        }
    }

    static func sse(_ payload: JSONValue) -> String { "data: " + payload.compactJSON() + "\n\n" }

    /// A node execution as Dify's persistence layer stores it (start node outputs = its inputs; failed attempts before a
    /// retry in `process_data.__dify_retry_history`). Nodes inside an iteration or loop save no draft variables (but the
    /// variable assigner's conversation variables).
    func persist(_ executionId: String, _ nodeId: String, _ start: Running?, _ status: String, _ r: NodeRunResult, error: String?,
                 finishedAt: Date, retries: [JSONValue]? = nil) async {
        let startAt = start?.startAt ?? finishedAt
        let nodeType = start?.nodeType ?? ""
        let outputs = nodeType == NodeType.start ? r.inputs : r.outputs
        var processData = r.processData
        if let retries, !retries.isEmpty { processData[RetryHistory.key] = .array(retries) }
        let e = StoredNodeExecution(
            id: executionId, docId: appId, workflowRunId: runId, triggeredFrom: triggeredFrom, docSeq: docSeq, index: start?.index ?? 0,
            predecessorNodeId: nil, nodeId: nodeId, nodeType: nodeType, title: start?.title ?? "",
            inputs: JSONValue.object(r.inputs).compactJSON(), processData: JSONValue.object(processData).compactJSON(),
            outputs: JSONValue.object(outputs).compactJSON(), status: status, error: error.flatMap { $0.isEmpty ? nil : $0 },
            elapsedTime: max(finishedAt.timeIntervalSince(startAt), 0), executionMetadata: JSONValue.object(r.metadata).compactJSON(),
            createdBy: createdBy, createdAt: startAt, finishedAt: finishedAt)
        do { try await routes.store.upsertNodeExecution(e) } catch {
            routes.logger.error("run \(runId): storing node execution \(executionId) failed: \(error)")
        }
        let enclosing = (start?.scope ?? NodeScope(metadata: r.metadata)).containerId
        if enclosing != nil && nodeType != NodeType.variableAssigner { return }
        await routes.saveRunDraftVariables(appId: appId, userId: createdBy, docSeq: docSeq, nodeId: nodeId, nodeType: nodeType, executionId: executionId,
                                           status: status, result: r)
    }

    func finish(status: String, error: String?, stats: GraphRunStats, started: ContinuousClock.Instant,
                running: [String: Running]) async {
        let now = Date()
        // `_fail_running_node_executions`: nodes still running when the run ends.
        for (x, s) in running {
            let e = StoredNodeExecution(
                id: x, docId: appId, workflowRunId: runId, triggeredFrom: triggeredFrom, docSeq: docSeq, index: s.index, predecessorNodeId: nil,
                nodeId: s.nodeId, nodeType: s.nodeType, title: s.title, inputs: nil, processData: nil, outputs: nil, status: "failed",
                error: error ?? "", elapsedTime: max(now.timeIntervalSince(s.startAt), 0), executionMetadata: nil, createdBy: createdBy,
                createdAt: s.startAt, finishedAt: now)
            try? await routes.store.upsertNodeExecution(e)
        }
        let elapsed = SingleStepRunSeconds.of(ContinuousClock.now - started)
        do {
            try await routes.store.finishWorkflowRun(id: runId, status: status, outputs: JSONValue.object(stats.outputs).compactJSON(), error: error,
                                                     elapsedTime: elapsed, totalTokens: stats.totalTokens, totalSteps: stats.totalSteps,
                                                     exceptionsCount: status == "stopped" ? 0 : stats.exceptionsCount, finishedAt: now)
        } catch {
            routes.logger.error("run \(runId): storing the result failed: \(error)")
        }
    }
}

/// Dify's retry history (`core/app/workflow/retry_history.py`, `services/workflow_node_execution_trace_service.py`): the
/// failed attempts before a retry are kept in the execution's process data; the node-executions list shows each as its
/// own trace (`status` `retry`, id `<execution>:retry:<n>`, `retry_index`) before the execution, whose process data
/// loses the key.
enum RetryHistory {
    static let key = "__dify_retry_history"

    static func traces(_ e: StoredNodeExecution) -> [JSONValue] {
        guard case .object(var terminal) = Routes.executionJSON(e) else { return [] }
        guard case .object(var processData)? = terminal["process_data"], let raw = processData[key] else { return [.object(terminal)] }
        processData[key] = nil
        terminal["process_data"] = .object(processData)
        var seen = Set<Int>()
        var attempts: [JSONObject] = []
        for a in raw.array ?? [] {
            guard case .object(let o) = a, let i = o["retry_index"]?.int, i > 0, !seen.contains(i) else { continue }
            seen.insert(i)
            attempts.append(o)
        }
        attempts.sort { ($0["retry_index"]?.int ?? 0) < ($1["retry_index"]?.int ?? 0) }
        let terminalMetadata = terminal["execution_metadata"]?.object ?? [:]
        var out: [JSONValue] = attempts.map { a in
            var t = terminal
            let index = a["retry_index"]?.int ?? 0
            t["id"] = .string("\(e.id):retry:\(index)")
            t["inputs"] = a["inputs"] ?? .null
            t["process_data"] = a["process_data"] ?? .null
            t["outputs"] = a["outputs"] ?? .null
            t["status"] = "retry"
            t["error"] = a["error"] ?? .null
            t["elapsed_time"] = a["elapsed_time"] ?? .null
            t["execution_metadata"] = .object(terminalMetadata.merging(a["execution_metadata"]?.object ?? [:]))
            t["created_at"] = a["created_at"] ?? .null
            t["finished_at"] = a["finished_at"] ?? .null
            t["retry_index"] = .int(index)
            return .object(t)
        }
        out.append(.object(terminal))
        return out
    }
}

enum SingleStepRunSeconds {
    static func of(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

/// Dify's stream for one run (`WorkflowResponseConverter` + the generate pipeline): engine events -> SSE payloads.
struct RunStreamEncoder: Sendable {
    let taskId: String
    let runId: String
    let workflowId: String
    let graph: RuntimeGraph
    let account: JSONValue
    let inputs: JSONObject
    /// The run's `created_at`: the original start, kept across a resume (Dify keeps the run row's value).
    let startedAt: Date
    /// When **this round** started: equal to `startedAt` for a fresh run, the resume moment for a resumed one. Dify computes
    /// `elapsed_time` from the round, not from the run's creation (`sqlalchemy_workflow_execution_repository`).
    var roundStartedAt: Date
    /// `_NodeSnapshot`s of started nodes.
    struct Snapshot: Sendable {
        var title: String
        var startAt: Date
        var scope: NodeScope
    }
    var snapshots: [String: Snapshot] = [:]

    init(taskId: String, runId: String, workflowId: String, graph: RuntimeGraph, account: JSONValue, inputs: JSONObject, startedAt: Date) {
        self.taskId = taskId
        self.runId = runId
        self.workflowId = workflowId
        self.graph = graph
        self.account = account
        self.inputs = inputs
        self.startedAt = startedAt
        roundStartedAt = startedAt
    }

    static func ts(_ d: Date) -> JSONValue { .int(Int(d.timeIntervalSince1970.rounded(.down))) }

    /// Dify's frame: `{"event", "workflow_run_id"}` updated with the response's `model_dump` (`event`, `task_id`, ..., `data`).
    func envelope(_ event: String, _ data: JSONValue) -> JSONValue {
        ["event": .string(event), "workflow_run_id": .string(runId), "task_id": .string(taskId), "data": data]
    }

    func nodeType(_ id: String) -> String { graph.nodes[id]?.nodeType ?? "" }

    /// Iteration and loop nodes have no node_started / node_finished / node_retry frames (Dify's converter drops them; their
    /// iteration_* / loop_* frames stand for them).
    func isContainer(_ nodeId: String) -> Bool {
        let t = nodeType(nodeId)
        return t == NodeType.iteration || t == NodeType.loop
    }

    func title(_ nodeId: String) -> String { graph.nodes[nodeId]?.title ?? "" }

    static func scopeFields(_ scope: NodeScope) -> (JSONValue, JSONValue) {
        (scope.iterationId.map(JSONValue.string) ?? .null, scope.loopId.map(JSONValue.string) ?? .null)
    }

    /// `_merge_metadata`: the result's metadata with the started node's iteration / loop id; null when empty.
    static func mergedMetadata(_ metadata: JSONObject, _ snap: Snapshot?) -> JSONValue {
        var m = metadata
        if let i = snap?.scope.iterationId { m[MetadataKey.iterationId] = .string(i) }
        if let l = snap?.scope.loopId { m[MetadataKey.loopId] = .string(l) }
        return m.isEmpty ? .null : .object(m)
    }

    mutating func encode(_ event: GraphEngineEvent) -> [JSONValue] {
        switch event {
        case .runStarted, .runResumed:
            let reason = { if case .runResumed = event { return "resumption" }; return "initial" }()
            return [envelope("workflow_started", ["id": .string(runId), "workflow_id": .string(workflowId), "inputs": .object(inputs),
                                                  "created_at": Self.ts(roundStartedAt), "reason": .string(reason)])]
        case .node(let e):
            switch e {
            case .pauseRequested: return [] // The async form adapter enriches these after a durable pause.
            case .started(let x, let nodeId, let type, let title, let startAt, let scope):
                if isContainer(nodeId) { return [] }
                snapshots[x] = Snapshot(title: title, startAt: startAt, scope: scope)
                let (iterationId, loopId) = Self.scopeFields(scope)
                return [envelope("node_started", [
                    "id": .string(x), "node_id": .string(nodeId), "node_type": .string(type), "title": .string(title), "index": 1,
                    "predecessor_node_id": .null, "inputs": .null, "inputs_truncated": false, "created_at": Self.ts(startAt), "extras": [:],
                    "iteration_id": iterationId, "loop_id": loopId, "agent_strategy": .null,
                ])]
            case .streamChunk(_, _, let selector, let chunk, _):
                return [envelope("text_chunk", ["text": .string(chunk), "from_variable_selector": .array(selector.map(JSONValue.string))])]
            case .reasoningChunk(_, let nodeId, _, let chunk, let isFinal):
                if chunk.isEmpty && !isFinal { return [] }
                return [envelope("reasoning_chunk", ["message_id": .null, "reasoning": .string(chunk), "node_id": .string(nodeId),
                                                     "is_final": .bool(isFinal)])]
            case .succeeded(let x, let nodeId, let startAt, let finishedAt, let r):
                if isContainer(nodeId) { return [] }
                var frames: [JSONValue] = []
                // WorkflowBasedAppRunner: an answer inside an iteration or loop streams its answer when it succeeds.
                if nodeType(nodeId) == NodeType.answer, !e.scope.isRoot, case .string(let answer)? = r.outputs["answer"], !answer.isEmpty {
                    frames.append(envelope("text_chunk", ["text": .string(answer), "from_variable_selector": [.string(nodeId), "answer"]]))
                }
                frames.append(finished(x, nodeId, "succeeded", r, error: nil, startAt: startAt, finishedAt: finishedAt))
                return frames
            case .failed(let x, let nodeId, let startAt, let finishedAt, let r, let error):
                if isContainer(nodeId) { return [] }
                return [finished(x, nodeId, "failed", r, error: error.isEmpty ? (r.error.isEmpty ? "Unknown error" : r.error) : error,
                                 startAt: startAt, finishedAt: finishedAt)]
            case .exception(let x, let nodeId, let startAt, let finishedAt, let r, let error):
                if isContainer(nodeId) { return [] }
                return [finished(x, nodeId, "exception", r, error: error.isEmpty ? (r.error.isEmpty ? "Unknown error" : r.error) : error,
                                 startAt: startAt, finishedAt: finishedAt)]
            case .retry(let x, let nodeId, let startAt, let r, let error, let retryIndex):
                if isContainer(nodeId) { return [] }
                let snap = snapshots[x]
                let now = Date()
                let (iterationId, loopId) = Self.scopeFields(e.scope)
                return [envelope("node_retry", [
                    "id": .string(x), "node_id": .string(nodeId), "node_type": .string(nodeType(nodeId)), "title": .string(snap?.title ?? ""),
                    "index": 1, "predecessor_node_id": .null, "inputs": .object(r.inputs), "inputs_truncated": false,
                    "process_data": .object(r.processData), "process_data_truncated": false, "outputs": .object(projected(nodeId, r)),
                    "outputs_truncated": false, "status": "retry", "error": .string(error), "elapsed_time": .double(now.timeIntervalSince(startAt)),
                    "execution_metadata": Self.mergedMetadata(r.metadata, snap), "created_at": Self.ts(snap?.startAt ?? startAt),
                    "finished_at": Self.ts(now), "files": [], "iteration_id": iterationId, "loop_id": loopId, "retry_index": .int(retryIndex),
                ])]
            case .containerStarted(_, let nodeId, let kind, _, let inputs, let metadata):
                return [envelope("\(kind.rawValue)_started", [
                    "id": .string(nodeId), "node_id": .string(nodeId), "node_type": .string(nodeType(nodeId)), "title": .string(title(nodeId)),
                    "created_at": Self.ts(Date()), "extras": [:], "metadata": .object(metadata), "inputs": .object(inputs), "inputs_truncated": false,
                ])]
            case .containerNext(_, let nodeId, let kind, let index, _):
                var data: JSONObject = ["id": .string(nodeId), "node_id": .string(nodeId), "node_type": .string(nodeType(nodeId)),
                                        "title": .string(title(nodeId)), "index": .int(index), "created_at": Self.ts(Date())]
                // `pre_loop_output` is sent empty (Dify: "not utilized by the frontend").
                if kind == .loop { data["pre_loop_output"] = [:] }
                data["extras"] = [:]
                return [envelope("\(kind.rawValue)_next", .object(data))]
            case .containerCompleted(_, let nodeId, let kind, let startAt, let inputs, let outputs, let metadata, let steps, let error):
                let now = Date()
                return [envelope("\(kind.rawValue)_completed", [
                    "id": .string(nodeId), "node_id": .string(nodeId), "node_type": .string(nodeType(nodeId)), "title": .string(title(nodeId)),
                    "outputs": .object(outputs), "outputs_truncated": false, "created_at": Self.ts(now), "extras": [:], "inputs": .object(inputs),
                    "inputs_truncated": false, "status": .string(error == nil ? "succeeded" : "failed"), "error": .null,
                    "elapsed_time": .double(now.timeIntervalSince(startAt)), "total_tokens": .int(metadata[MetadataKey.totalTokens]?.int ?? 0),
                    "execution_metadata": .object(metadata), "finished_at": Self.ts(now), "steps": .int(steps),
                ])]
            case .retrieverResource, .variableUpdated:
                return []
            }
        case .edgeTaken, .edgeSkipped:
            return []
        case .runPaused: return [] // Forms and workflow_paused are emitted together by the async pause adapter.
        case .runSucceeded(let s): return [workflowFinished("succeeded", error: nil, stats: s, exceptions: 0)]
        case .runPartialSucceeded(let s): return [workflowFinished("partial-succeeded", error: nil, stats: s, exceptions: s.exceptionsCount)]
        case .runFailed(let error, let s): return [workflowFinished("failed", error: error, stats: s, exceptions: s.exceptionsCount)]
        case .runAborted(let reason, let s): return [workflowFinished("stopped", error: reason, stats: s, exceptions: 0)]
        }
    }

    /// `project_node_outputs_for_workflow_run`: a start node's outputs are its inputs.
    func projected(_ nodeId: String, _ r: NodeRunResult) -> JSONObject { nodeType(nodeId) == NodeType.start ? r.inputs : r.outputs }

    mutating func finished(_ x: String, _ nodeId: String, _ status: String, _ r: NodeRunResult, error: String?, startAt: Date,
                           finishedAt: Date) -> JSONValue {
        let snap = snapshots.removeValue(forKey: x)
        let start = snap?.startAt ?? startAt
        let (iterationId, loopId) = Self.scopeFields(NodeScope(metadata: r.metadata))
        return envelope("node_finished", [
            "id": .string(x), "node_id": .string(nodeId), "node_type": .string(nodeType(nodeId)), "title": .string(snap?.title ?? ""),
            "index": snap == nil ? 0 : 1, "predecessor_node_id": .null, "inputs": .object(r.inputs), "inputs_truncated": false,
            "process_data": .object(r.processData), "process_data_truncated": false, "outputs": .object(projected(nodeId, r)),
            "outputs_truncated": false, "status": .string(status), "error": error.map(JSONValue.string) ?? .null,
            "elapsed_time": .double(finishedAt.timeIntervalSince(start)), "execution_metadata": Self.mergedMetadata(r.metadata, snap),
            "created_at": Self.ts(start), "finished_at": Self.ts(finishedAt), "files": [], "iteration_id": iterationId, "loop_id": loopId,
        ])
    }

    func workflowFinished(_ status: String, error: String?, stats: GraphRunStats, exceptions: Int) -> JSONValue {
        let now = Date()
        return envelope("workflow_finished", [
            "id": .string(runId), "workflow_id": .string(workflowId), "status": .string(status), "outputs": .object(stats.outputs),
            "error": error.map(JSONValue.string) ?? .null, "elapsed_time": .double(now.timeIntervalSince(roundStartedAt)),
            "total_tokens": .int(stats.totalTokens), "total_steps": .int(stats.totalSteps), "created_by": account,
            // The converter stamps its own `started_at` on every `workflow_started`; a resumed round's frames carry the
            // resume moment, while the run row keeps the original `created_at`.
            "created_at": Self.ts(roundStartedAt), "finished_at": Self.ts(now), "exceptions_count": .int(exceptions), "files": [],
        ])
    }
}

// MARK: - Channels and the registry of running tasks

/// The frames of one run for its SSE subscribers: every frame is kept (a subscriber that attaches late gets them all) until
/// the run ends.
/// The live channels of the runs this process is executing, by run id. A reconnect attaches to the same channel the run
/// publishes into; a run that is not in here (paused, finished, or started by another process) is served from its records.
actor RunChannelRegistry {
    private var channels: [String: RunChannel] = [:]

    func channel(_ runId: String, pingSeconds: Int) async -> RunChannel {
        if let existing = channels[runId] { return existing }
        let created = RunChannel()
        channels[runId] = created
        await created.startPing(seconds: pingSeconds)
        return created
    }

    func existing(_ runId: String) -> RunChannel? { channels[runId] }

    func remove(_ runId: String) { channels.removeValue(forKey: runId) }
}

actor RunChannel {
    private var frames: [String] = []
    private var pauseGenerations: [Int: Int] = [:]
    private var subscribers: [Int: AsyncStream<String>.Continuation] = [:]
    private var next = 0
    private var finished = false
    private var lastSent = ContinuousClock.now
    private var pinger: Task<Void, Never>?

    /// `pauseGeneration` tags a frame that belongs to one pause (the database generation): a reconnect deduplicates by that
    /// identity, never by a second-resolution `created_at` (two resumes can re-pause within the same second).
    func publish(_ frame: String, pauseGeneration: Int? = nil) {
        if let pauseGeneration { pauseGenerations[frames.count] = pauseGeneration }
        frames.append(frame)
        lastSent = .now
        for c in subscribers.values { c.yield(frame) }
    }

    /// `event: ping` when nothing was sent for `seconds` (not kept for late subscribers). True once the channel ended.
    func pingIfIdle(seconds: Int) -> Bool {
        guard !finished else { return true }
        guard ContinuousClock.now - lastSent >= .seconds(seconds) else { return false }
        lastSent = .now
        for c in subscribers.values { c.yield("event: ping\n\n") }
        return false
    }

    /// Keeps the keep-alives coming for as long as the channel lives — a **run**, not one round: a run that waits for a
    /// person can wait for hours, and Dify's queue pings every 10 s whether a node is running or not.
    func startPing(seconds: Int) {
        guard pinger == nil else { return }
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                guard let self else { return }
                if await self.pingIfIdle(seconds: seconds) { return }
            }
        }
    }

    func finish() {
        finished = true
        pinger?.cancel()
        pinger = nil
        for c in subscribers.values { c.finish() }
        subscribers = [:]
    }

    /// How many frames have been published so far (a reconnect marks the window it must deduplicate).
    var published: Int { frames.count }

    /// The pause generation a published frame belongs to, when it is a pause frame.
    func pauseGeneration(at index: Int) -> Int? { pauseGenerations[index] }

    /// `replay` = the frames already published (a fresh subscriber sees the run from its start); false = only what comes
    /// next. `from` starts the replay at that index instead of 0.
    func subscribe(replay: Bool = true, from: Int = 0) -> AsyncStream<String> {
        let (stream, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        if replay { for f in frames.dropFirst(max(0, min(from, frames.count))) { cont.yield(f) } }
        if finished {
            cont.finish()
            return stream
        }
        let id = next
        next += 1
        subscribers[id] = cont
        cont.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: Int) { subscribers[id] = nil }
}

/// Running draft runs by task id (Dify's task ids; the stop command finds them here).
actor WorkflowRunRegistry {
    struct Active: Sendable {
        var appId: String
        var runId: String
        var commands: GraphEngineCommands
        /// The round that registered this entry. A resumed round takes over the task id; the round before it must not
        /// remove the new one when its own cleanup runs.
        var lease: String
    }

    private var active: [String: Active] = [:]

    func add(_ taskId: String, _ a: Active) { active[taskId] = a }
    func get(_ taskId: String) -> Active? { active[taskId] }
    /// Removes the entry only when `lease` still owns it (an older round finishing late must not delete its successor).
    func remove(_ taskId: String, lease: String) {
        guard active[taskId]?.lease == lease else { return }
        active[taskId] = nil
    }
    var count: Int { active.count }
}
