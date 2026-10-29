import CollabRuntime
import CollabStore
import Foundation

/// One graph's adapter. Config identity comes from its stored graph, never a mutable draft pointer.
struct ServerAgentRuntime: AgentRuntime {
    let routes: Routes
    let appID: String
    let runID: String
    let userID: String
    let endUserID: String?
    let pending: PendingHumanInputForms
    let decisions: [String: StoredHumanInputForm]
    var files: (any RuntimeFiles)? { routes.runtimeServices(appId: appID, userId: userID, endUserId: endUserID).files }

    func configuration(_ node: String, _ data: AgentNodeData) async throws -> (StoredAgentConfig, AgentInlineConfig) {
        guard let config = try await routes.store.agentConfig(doc: appID, node: node, agent: data.agentID, snapshot: data.snapshotID) else {
            throw NodeError("AgentConfigMissing", "This workflow node's pinned agent configuration is unavailable")
        }
        return (config, try AgentInlineConfig(try JSONValue.parse(config.soul).object ?? [:], requireModel: true))
    }

    func prepare(nodeID: String, data: AgentNodeData) async throws {
        let app = try await routes.liveApp(appID, viewer: userID)
        guard app.mode == "workflow" else { throw NodeError("AgentModeUnsupported", "Inline Agent v2 is available only in workflows") }
        guard routes.config.agentService.isConfigured else { throw NodeError("AgentServiceUnavailable", "The agent service is not configured") }
        let (_, soul) = try await configuration(nodeID, data)
        let profile = try await executorProfile(soul)
        _ = try AgentExecutionPolicy.turns(node: soul.maxTurns, profile: profile?.maxTurnsMax)
        try await validateModel(soul)
        for item in soul.files {
            guard let id = item["file_id"]?.string, let files else { throw NodeError("AgentFileUnavailable", "An agent configuration file is missing") }
            _ = try await files.resolve(["transfer_method": "local_file", "upload_file_id": .string(id)], config: nil)
        }
    }

    private func validateModel(_ soul: AgentInlineConfig) async throws {
        guard let provider = soul.provider, let model = soul.model,
              let models = routes.runtimeServices(appId: appID, userId: userID).models else { throw ServiceNotConfigured(service: .models) }
        let credentials = try await routes.agentCredentials(provider: provider, model: model, reference: soul.json["model"]?["credential_ref"])
        guard let schema = try await models.modelSchema(provider: provider, model: model, modelType: "llm", credentials: credentials),
              AgentModelCompatibility.isCompatible(label: schema.json["label"]?["en_US"]?.string ?? model),
              (schema.features ?? []).contains(where: { ["tool-call", "multi-tool-call"].contains($0) }) else {
            throw NodeError("AgentModelUnsupported", "The agent model must support tool calls")
        }
        if let effort = soul.modelParameters["reasoning_effort"],
           let options = ModelReasoning.runtimeOptions(provider: provider, credentials: credentials,
               rule: schema.json["parameter_rules"]?.array?.first(where: { $0["name"] == "reasoning_effort" })),
           !options.contains(effort) {
            throw NodeError("AgentModelInputInvalid", "The selected model does not support this reasoning effort")
        }
    }

    func run(nodeID: String, data: AgentNodeData, context: NodeRunContext) async throws -> AgentNodeDecision {
        let activeStarted = ContinuousClock.now
        let activeWallStarted = Date()
        let (stored, configured) = try await configuration(nodeID, data)
        guard let execution = context.executionId else { throw NodeError("AgentExecutionMissing", "Agent nodes require a workflow execution") }
        let existing = try await routes.store.agentSession(execution: execution)
        let pinned = try existing.flatMap { try JSONValue.parse($0.usage)["model_selection"]?.object }
        let soul = try data.modelInputs.resolve(configured, pool: context.pool, pinned: pinned)
        try await validateModel(soul)
        let profile = try await executorProfile(soul)
        let maxTurns = try AgentExecutionPolicy.turns(node: soul.maxTurns, profile: profile?.maxTurnsMax)
        let timeout = AgentExecutionPolicy.timeout(node: routes.config.agentService.timeoutSeconds,
            profile: profile?.timeoutSecondsMax ?? (soul.executorProfile == "default" ? 1800 : nil),
            server: routes.config.agentService.timeoutSecondsMax)
        var deadline = activeWallStarted.addingTimeInterval(Double(timeout))
        func admitted<T>(_ work: () async throws -> T) async throws -> T {
            while true {
                try Task.checkCancellation()
                if context.isAborted() { throw CancellationError() }
                guard Date() < deadline else { throw NodeError("AgentTimeout", "Agent admission exceeded its deadline") }
                do { return try await work() }
                catch StoreError.agentCapacityFull { try await Task.sleep(for: .milliseconds(250)) }
            }
        }
        let prompt = try await AgentPromptBuilder.build(node: data, config: soul, pool: context.pool, files: files,
            nodeJob: try JSONValue.parse(stored.nodeJob).object ?? [:])
        var session: StoredAgentSession
        var continuation: JSONValue = .null
        if let existing {
            guard existing.workflowRunID == runID, existing.configSnapshotID == data.snapshotID, existing.nodeID == nodeID else {
                throw NodeError("AgentConfigChanged", "The agent execution does not belong to this pinned workflow node")
            }
            session = try await routes.store.adoptPausedAgent(execution: execution, owner: routes.agentOwner)
            guard let formID = session.formID, let questionID = session.questionID,
                  let snapshot = session.continuation, let result = session.preparedResult else {
                throw NodeError("AgentResumeInvalid", "The agent pause is incomplete")
            }
            guard let form = decisions[formID] else {
                guard let waiting = try await routes.store.humanInputForm(id: formID), waiting.questionID == questionID else {
                    throw NodeError("AgentResumeInvalid", "The agent question is unavailable")
                }
                let question = try JSONValue.parse(result)["question"]?.object ?? [:]
                let built = try AgentQuestion(question, title: data.base.title, contacts: soul.contacts)
                pending.add(waiting, deliveryMethods: built.config.deliveryMethods, resolvedInputs: built.config.inputs)
                return .pause(formID: formID, usage: .empty)
            }
            guard form.executionId == execution, form.questionID == questionID else { throw NodeError("AgentResumeInvalid", "The answer is for a different agent question") }
            let question = try AgentQuestion(try JSONValue.parse(result)["question"]?.object ?? [:], title: data.base.title, contacts: soul.contacts)
            continuation = ["kind": "answer", "snapshot": try JSONValue.parse(snapshot), "question_id": .string(questionID),
                "result": try await question.answer(form, files: files)]
        } else {
            session = try await admitted { try await routes.store.createAgentSession(.init(executionID: execution, workflowRunID: runID, docID: appID,
                nodeID: nodeID, agentID: data.agentID, configSnapshotID: data.snapshotID, ownerID: routes.agentOwner),
                maxConcurrent: routes.config.agentService.maxConcurrent) }
        }
        let service = AgentServiceClient(config: routes.config.agentService)
        let selectedModel = soul.json["model"]!.object!
        let pinnedModel = try await routes.store.pinAgentModel(session: session, selection: JSONValue.object(selectedModel).compactJSON())
        guard try JSONValue.parse(pinnedModel) == .object(selectedModel) else {
            throw NodeError("AgentConfigChanged", "The agent execution already has a different model selection")
        }
        let retainSession = try await routes.store.pinAgentRetention(session: session, enabled: data.retainSession)
        let startedData = try await pending.agentCommits.startedData(execution)
        let shellAvailable: Bool
        if let pinned = try JSONValue.parse(session.usage)["shell_enabled"]?.bool { shellAvailable = pinned }
        else { shellAvailable = try await routes.store.pinAgentShell(session: session, enabled: routes.config.agentService.shellEnabled) }
        let viewImage: Bool
        if let pinned = try JSONValue.parse(session.usage)["view_image"]?.bool { viewImage = pinned && shellAvailable }
        else {
            // Old paused snapshots have the old tool set. Introducing a new tool would invalidate their continuation.
            let legacyContinuation = continuation["snapshot"]?.object != nil && continuation["snapshot"]?["executor_profile"] == nil
            let vision = shellAvailable && !legacyContinuation ? try await modelSupportsVision(soul) : false
            viewImage = try await routes.store.pinAgentViewImage(session: session, enabled: vision)
        }
        let reportProgress: Bool
        if let pinned = try JSONValue.parse(session.usage)["report_progress"]?.bool { reportProgress = pinned && shellAvailable }
        else {
            // Existing snapshots must resume with their original tool definitions.
            reportProgress = try await routes.store.pinAgentReportProgress(session: session,
                enabled: shellAvailable && continuation["snapshot"]?.object == nil)
        }
        var roundUsage = LLMUsage.empty
        var recordedUsage = try JSONValue.parse(session.usage)
        var cumulative = LLMUsage(json: recordedUsage)
        let previousElapsed = recordedUsage["active_elapsed_time"]?.double ?? 0
        deadline = deadline.addingTimeInterval(-previousElapsed)
        func activeElapsed() -> Double {
            let duration = (ContinuousClock.now - activeStarted).components
            return previousElapsed + Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        func usageJSON() -> String {
            var json = cumulative.json.object ?? [:]
            json["active_elapsed_time"] = .double(activeElapsed())
            json["node_started"] = recordedUsage["node_started"] ?? .null
            json["shell_enabled"] = .bool(shellAvailable)
            json["view_image"] = .bool(viewImage)
            json["report_progress"] = .bool(reportProgress)
            json["model_selection"] = .object(selectedModel)
            json["retain_session"] = .bool(retainSession)
            return JSONValue.object(json).compactJSON()
        }
        let modelEnvelope = try await modelEnvelope(soul)
        let wire = modelEnvelope["wire"]?.string ?? "plugin"
        if retainSession && !(shellAvailable && soul.harnessStyle == "codex" && wire == "responses") {
            throw NodeError("AgentSessionUnsupported", "Retaining a session requires Codex, Responses and a disk execution environment")
        }
        var inputs = JSONObject(); inputs["task"] = .string(data.task)
        // Public values only: keep private credential references in the session, not in workflow trace inputs.
        let resolvedModel: JSONObject = ["provider": .string(soul.provider!), "model": .string(soul.model!),
            "parameters": .object(soul.modelParameters)]
        inputs["model"] = .object(resolvedModel)
        inputs["retain_session"] = .bool(retainSession)
        while true {
            try Task.checkCancellation()
            if context.isAborted() { throw CancellationError() }
            let operation = "\(execution):\(session.outputAttempt):\(session.resumeSequence)"
            let identity: JSONObject = ["tenant_id": .string(routes.config.pluginDaemonTenant), "app_id": .string(appID),
                "workflow_run_id": .string(runID), "node_id": .string(nodeID), "execution_id": .string(execution),
                "agent_config_snapshot_id": .string(data.snapshotID), "user_id": .string(userID), "user_from": endUserID == nil ? "account" : "end-user", "invoke_from": endUserID == nil ? "debugger" : "web_app"]
            var env = JSONObject()
            for item in soul.environment {
                guard let value = item["value"]?.string else { throw NodeError("AgentEnvironmentInvalid", "Agent environment values must be text") }
                env[AgentInlineConfig.environmentName(item)] = .string(value)
            }
            let secrets = try await routes.store.secrets(appID)
            for item in soul.secretReferences {
                guard let name = item["name"]?.string, let ref = item["ref"]?.string, let value = secrets[ref], !value.isEmpty else {
                    throw NodeError("AgentSecretMissing", "An agent environment secret is unavailable")
                }
                env[name] = .string(value)
            }
            var body: JSONObject = ["operation_id": .string(operation), "generation": .int(session.generation), "execution": .object(identity),
                "model": .object(modelEnvelope),
                "system_prompt": .string(prompt.system), "task": .array(prompt.task), "output_schema": data.outputSchema ?? .null,
                "executor_profile": .string(soul.executorProfile),
                "tools": ["ask_human": .bool(soul.askHuman), "shell": .bool(shellAvailable), "view_image": .bool(viewImage), "report_progress": .bool(reportProgress)], "env": .object(env), "files": .array(prompt.files),
                "limits": ["max_turns": .int(maxTurns), "timeout_seconds": .int(max(1, Int(deadline.timeIntervalSinceNow)))], "continuation": continuation]
            if soul.harnessStyle == "codex" {
                body["harness_style"] = "codex"
                var tools = body["tools"]!.object!
                tools["update_plan"] = .bool(soul.updatePlan)
                body["tools"] = .object(tools)
            }
            if retainSession { body["codex_session"] = ["retain": true] }
            // Identities are fixed across uncertain transport retries. Secrets are never persisted in the operation ledger.
            let scope = AgentModelScope(operationID: operation, generation: session.generation, execution: identity,
                provider: soul.provider!, model: soul.model!, maxCalls: maxTurns, expiresAt: deadline, inputFileIDs: prompt.inputFileIDs,
                endUserID: endUserID, modelParameters: soul.modelParameters, credentialReference: soul.json["model"]?["credential_ref"], durableOwner: routes.agentOwner, harnessStyle: soul.harnessStyle, modelWire: wire,
                outputTokenLimit: modelEnvelope["max_output_tokens"]?.int)
            let token = try await routes.agentModelScopes.activate(scope)
            if soul.harnessStyle == "codex", wire == "responses" {
                var model = body["model"]!.object!
                model["run_token"] = .string(token)
                body["model"] = .object(model)
            }
            do {
                try await admitted { try await routes.store.startAgentOperation(session: session, operation: operation,
                    digest: Self.operationDigest(body), tokenHash: Tokens.sha256(token), startedData: startedData.compactJSON(), maxConcurrent: routes.config.agentService.maxConcurrent) }
                session = try requireAgentSession(try await routes.store.agentSession(execution: execution))
                let remote = try await service.begin(body, token: token, execution: execution,
                    generation: session.generation, deadline: deadline, isAborted: context.isAborted)
                try await routes.store.recordAgentRun(session: session, run: remote)
                let activeSession = session
                let trace = AgentTraceWriter(secrets: env.values.compactMap(\.string) + [token])
                let terminal = try await service.result(run: remote, operation: operation, deadline: deadline,
                    expectedProfile: soul.executorProfile, expectedHarness: soul.harnessStyle == "codex" ? "codex" : nil,
                    expectedWire: soul.harnessStyle == "codex" ? wire : nil, generation: session.generation, isAborted: context.isAborted) { event, name, data in
                    var display = data
                    if name == "run_started" {
                        display["max_turns"] = .int(maxTurns)
                        display["resolved_model"] = .object(resolvedModel)
                    }
                    if name == "progress" { display = try await routes.normalizeAgentProgress(data, session: activeSession, files: files) }
                    try await trace.record(routes: routes, session: activeSession, run: remote, event: event, name: name, data: display)
                }
                let usage = await routes.agentModelScopes.revoke(token: token)
                roundUsage = roundUsage.plus(usage); cumulative = cumulative.plus(usage)
                let result = terminal["result"] ?? [:]
                let partial = Self.partialResult(result["partial"])
                try await routes.store.recordAgentResult(session: session, run: remote, event: terminal["last_event_id"]!.int!, result: result.compactJSON())
                session = try requireAgentSession(try await routes.store.agentSession(execution: execution))
                recordedUsage = try JSONValue.parse(session.usage)
                switch terminal["status"]?.string {
                case "paused":
                    guard soul.askHuman, let questionID = result["question_id"]?.string,
                          questionID == "\(execution):q\(session.resumeSequence + 1)", let question = result["question"]?.object,
                          let snapshot = result["snapshot"], snapshot.object != nil else { throw NodeError("AgentServiceProtocolError", "Invalid agent question result") }
                    let built = try AgentQuestion(question, title: data.base.title, contacts: soul.contacts)
                    let now = Date(), id = UUID().uuidString.lowercased()
                    let form = StoredHumanInputForm(id: id, workflowRunId: runID, generation: 0, executionId: execution, docId: appID, nodeId: nodeID,
                        nodeTitle: data.base.title, token: UUID().uuidString.lowercased(), formContent: built.config.content,
                        inputs: try ServerHumanInputRuntime.jsonText(built.config.inputs), userActions: try ServerHumanInputRuntime.jsonText(built.config.actions),
                        renderedContent: built.config.content, defaultValues: ServerHumanInputRuntime.jsonTextObject(built.defaults),
                        resolvedDefaultValues: ServerHumanInputRuntime.jsonTextObject(built.defaults), actions: try ServerHumanInputRuntime.jsonText(built.config.actions),
                        displayInUi: true, expirationTime: Int(built.config.expirationTime(from: now).timeIntervalSince1970), createdAt: now,
                        recipientType: endUserID == nil ? .console : .webapp, questionID: questionID)
                    pending.add(form, deliveryMethods: built.config.deliveryMethods, resolvedInputs: built.config.inputs)
                    pending.addAgentOutcome(.init(session: session, status: "paused", continuation: snapshot.compactJSON(), questionID: questionID,
                        formID: id, usage: usageJSON(), resumeSequence: session.resumeSequence + 1))
                    return .pause(formID: id, usage: roundUsage)
                case "succeeded":
                    let candidate = try await routes.normalizeAgentCandidate(result["candidate"] ?? .null, session: session, files: files, declarations: data.declarations)
                    let decision = await AgentOutputPolicy.decide(fields: data.declarations, candidate: candidate, attempt: session.outputAttempt,
                        fileValid: { value in
                            guard RuntimeFile.isFile(value), let files = self.files else { return false }
                            return (try? await files.resolve(value, config: nil)) != nil
                        }, resolveDefault: { definition, value in
                            try await self.routes.resolveAgentDefault(definition: definition, value: value, files: self.files)
                        })
                    if decision.action == .retry {
                        guard let snapshot = result["snapshot"], snapshot.object != nil else { throw NodeError("AgentServiceProtocolError", "An output retry has no continuation") }
                        try await routes.store.commitAgentRetry(.init(session: session, status: "retry", continuation: snapshot.compactJSON(),
                            acceptedOutputs: JSONValue.object(decision.outputs).compactJSON(), usage: usageJSON(), outputAttempt: decision.nextAttempt))
                        session = try requireAgentSession(try await routes.store.agentSession(execution: execution))
                        continuation = ["kind": "output_retry", "snapshot": snapshot, "feedback": .array(decision.feedback + (result["candidate_errors"]?.array ?? []).prefix(128))]
                        try await Task.sleep(for: .milliseconds(decision.retryIntervalMs))
                        continue
                    }
                    let succeeded = decision.action == .succeeded
                    var processData: JSONObject = ["agent_id": .string(data.agentID), "agent_config_snapshot_id": .string(data.snapshotID), "workflow_agent_binding_id": data.bindingID.map(JSONValue.string) ?? .null, "agent_output_checks": .array(decision.checks.map(\.json))]
                    var metadata: JSONObject = ["agent_config_snapshot_id": .string(data.snapshotID), "total_tokens": .int(cumulative.totalTokens), "agent_active_elapsed_time": .double(activeElapsed()), "agent_partial": partial ?? .null, "agent_log": try await routes.agentLogPreview(session)]
                    if retainSession {
                        let state = try AgentRetainedSessionStatus.normalize(result["session"])
                        processData["agent_session"] = .object(state)
                        metadata["agent_session"] = .object(state)
                    }
                    var value = NodeRunResult(status: succeeded ? .succeeded : .failed, inputs: inputs,
                        processData: processData, outputs: decision.outputs,
                        metadata: metadata, llmUsage: roundUsage,
                        error: succeeded ? "" : "Declared agent outputs failed validation",
                        errorType: succeeded ? "" : (decision.action == .failBranch ? "output_type_check_failed_fail_branch" : "output_type_check_failed"))
                    value.edgeSourceHandle = "source"
                    pending.addAgentOutcome(.init(session: session, status: succeeded ? "completed" : "failed",
                        acceptedOutputs: JSONValue.object(decision.outputs).compactJSON(), usage: usageJSON()))
                    try await pending.agentCommits.commit(execution, result: value)
                    return .completed(value)
                case "failed", "cancelled":
                    let errorType = result["error_type"]?.string ?? "cancel_lost"
                    let known: Set<String> = ["model_error", "model_quota", "max_turns", "timeout", "ask_human_invalid", "sandbox_unavailable", "sandbox_error", "file_error", "session_restore_failed", "session_save_failed", "cancel_lost", "internal"]
                    pending.addAgentOutcome(.init(session: session, status: "failed", usage: usageJSON()))
                    let value = NodeRunResult(status: .failed, inputs: inputs, metadata: ["total_tokens": .int(cumulative.totalTokens), "agent_active_elapsed_time": .double(activeElapsed()), "agent_partial": partial ?? .null, "agent_log": try await routes.agentLogPreview(session)], llmUsage: roundUsage,
                        error: "The agent operation did not complete", errorType: known.contains(errorType) ? errorType : "internal")
                    try await pending.agentCommits.commit(execution, result: value)
                    return .completed(value)
                default: throw NodeError("AgentServiceProtocolError", "Invalid agent result")
                }
            } catch {
                _ = await routes.agentModelScopes.revoke(token: token)
                try? await routes.store.abandonAgentExecution(execution: execution, owner: routes.agentOwner, generation: session.generation)
                if error is CancellationError { throw CancellationError() }
                if let error = error as? NodeError { throw error }
                throw NodeError("AgentExecutionFailed", "The agent operation could not be committed")
            }
        }
    }

    static func partialResult(_ value: JSONValue?) -> JSONValue? {
        guard let reason = value?["reason"]?.string, ["max_turns", "timeout"].contains(reason),
              case .int(let call)? = value?["notice_call_index"], (1...1000).contains(call) else { return nil }
        return ["reason": .string(reason), "notice_call_index": .int(call)]
    }

    private func executorProfile(_ soul: AgentInlineConfig) async throws -> AgentExecutorProfile? {
        guard routes.config.agentService.shellEnabled,
              let profiles = await routes.agentExecutorProfiles.profiles(routes.config.agentService) else { return nil }
        guard let profile = profiles.first(where: { $0.name == soul.executorProfile }) else {
            throw NodeError("executor_profile_unknown", "Executor profile \(soul.executorProfile) is not available on this server")
        }
        guard profile.status == "ok" else {
            throw NodeError("executor_profile_unavailable", "Executor profile \(soul.executorProfile) is not available on this server")
        }
        return profile
    }

    private func modelEnvelope(_ soul: AgentInlineConfig) async throws -> JSONObject {
        var result: JSONObject = ["provider": .string(soul.provider!), "name": .string(soul.model!), "parameters": .object(soul.modelParameters)]
        // Preserve the original dify envelope, including the absence of new keys.
        guard soul.harnessStyle == "codex" else { return result }
        let credentials = try await routes.agentCredentials(provider: soul.provider!, model: soul.model!, reference: soul.json["model"]?["credential_ref"])
        result["wire"] = .string(AgentModelWire.select(style: soul.harnessStyle, provider: soul.provider!, credentials: credentials))
        if let apiType = credentials["api_type"]?.string { result["api_type"] = .string(apiType) }
        if routes.config.agentService.codexWebsocketPort > 0, result["wire"] == "responses",
           try AgentResponsesConnection(provider: soul.provider!, model: soul.model!, credentials: credentials).isOfficialOpenAI {
            result["transport"] = "websocket"
        }
        if let models = routes.runtimeServices(appId: appID, userId: userID).models,
           let schema = try await models.modelSchema(provider: soul.provider!, model: soul.model!, modelType: "llm", credentials: credentials) {
            if let context = schema.json["model_properties"]?["context_size"]?.int, context > 0 { result["context_window"] = .int(context) }
            if let efforts = ModelReasoning.runtimeOptions(provider: soul.provider!, credentials: credentials,
                rule: schema.json["parameter_rules"]?.array?.first(where: { $0["name"] == "reasoning_effort" })),
               !efforts.isEmpty, efforts.allSatisfy({ $0.string?.isEmpty == false }) {
                result["reasoning_efforts"] = .array(efforts)
            }
            if let features = schema.features {
                result["input_modalities"] = .array(features.contains("vision") ? ["text", "image"] : ["text"])
            }
            if let output = schema.json["parameter_rules"]?.array?.first(where: {
                ["max_tokens", "max_completion_tokens", "max_output_tokens"].contains($0["name"]?.string ?? "")
            })?["max"]?.int, output > 0 { result["max_output_tokens"] = .int(output) }
        }
        return result
    }

    private func modelSupportsVision(_ soul: AgentInlineConfig) async throws -> Bool {
        guard let provider = soul.provider, let model = soul.model,
              let models = routes.runtimeServices(appId: appID, userId: userID).models else { return false }
        let credentials = try await routes.agentCredentials(provider: provider, model: model, reference: soul.json["model"]?["credential_ref"])
        let schema = try await models.modelSchema(provider: provider, model: model, modelType: "llm", credentials: credentials)
        return schema?.features?.contains("vision") == true
    }
    /// The audit digest identifies the public operation shape; a low-entropy secret must never be guessable from it.
    static func operationDigest(_ body: JSONObject) -> String {
        var projected = body
        projected["env"] = .object(JSONObject((body["env"]?.object ?? [:]).keys.map { ($0, JSONValue.string("[redacted]")) }))
        if var model = projected["model"]?.object {
            model["run_token"] = nil
            projected["model"] = .object(model)
        }
        return Tokens.sha256(JSONValue.object(projected).compactJSON())
    }

}

private func requireAgentSession(_ session: StoredAgentSession?) throws -> StoredAgentSession {
    guard let session else { throw NodeError("AgentExecutionMissing", "The agent execution is unavailable") }
    return session
}
