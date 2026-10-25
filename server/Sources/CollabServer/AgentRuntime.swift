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
        guard routes.config.agentService.isConfigured else { throw NodeError("AgentServiceUnavailable", "The agent service is not configured") }
        let (_, soul) = try await configuration(nodeID, data)
        guard let provider = soul.provider, let model = soul.model,
              let models = routes.runtimeServices(appId: appID, userId: userID).models else { throw ServiceNotConfigured(service: .models) }
        guard AgentModelCompatibility.isCompatible(label: model) else { throw NodeError("AgentModelUnsupported", "This model is not supported by inline Agent v2") }
        let credentials = try await routes.agentCredentials(provider: provider, model: model, reference: soul.json["model"]?["credential_ref"])
        guard let schema = try await models.modelSchema(provider: provider, model: model, modelType: "llm", credentials: credentials),
              (schema.features ?? []).contains(where: { ["tool-call", "multi-tool-call"].contains($0) }) else {
            throw NodeError("AgentModelUnsupported", "The agent model must support tool calls")
        }
        for item in soul.files {
            guard let id = item["file_id"]?.string, let files else { throw NodeError("AgentFileUnavailable", "An agent configuration file is missing") }
            _ = try await files.resolve(["transfer_method": "local_file", "upload_file_id": .string(id)], config: nil)
        }
    }

    func run(nodeID: String, data: AgentNodeData, context: NodeRunContext) async throws -> AgentNodeDecision {
        guard let execution = context.executionId else { throw NodeError("AgentExecutionMissing", "Agent nodes require a workflow execution") }
        let (stored, soul) = try await configuration(nodeID, data)
        let prompt = try await AgentPromptBuilder.build(node: data, config: soul, pool: context.pool, files: files,
            nodeJob: try JSONValue.parse(stored.nodeJob).object ?? [:])
        var session: StoredAgentSession
        var continuation: JSONValue = .null
        if let existing = try await routes.store.agentSession(execution: execution) {
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
            session = try await routes.store.createAgentSession(.init(executionID: execution, workflowRunID: runID, docID: appID,
                nodeID: nodeID, agentID: data.agentID, configSnapshotID: data.snapshotID, ownerID: routes.agentOwner),
                maxConcurrent: routes.config.agentService.maxConcurrent)
        }
        let service = AgentServiceClient(config: routes.config.agentService)
        let deadline = Date().addingTimeInterval(Double(routes.config.agentService.timeoutSeconds))
        var roundUsage = LLMUsage.empty
        var cumulative = LLMUsage(json: try JSONValue.parse(session.usage))
        var inputs = JSONObject(); inputs["task"] = .string(data.task)
        while true {
            try Task.checkCancellation()
            if context.isAborted() { throw CancellationError() }
            let operation = "\(execution):\(session.outputAttempt):\(session.resumeSequence)"
            let identity: JSONObject = ["tenant_id": .string(routes.config.pluginDaemonTenant), "app_id": .string(appID),
                "workflow_run_id": .string(runID), "node_id": .string(nodeID), "execution_id": .string(execution),
                "agent_config_snapshot_id": .string(data.snapshotID), "user_id": .string(userID), "user_from": "account", "invoke_from": endUserID == nil ? "debugger" : "web_app"]
            var env = JSONObject()
            for item in soul.environment {
                guard let value = item["value"]?.string else { throw NodeError("AgentEnvironmentInvalid", "Agent environment values must be text") }
                env[AgentInlineConfig.environmentName(item)] = .string(value)
            }
            let secrets = try await routes.store.secrets(appID)
            for item in soul.secretReferences {
                guard let name = item["name"]?.string, let ref = item["ref"]?.string, let value = secrets[ref] else {
                    throw NodeError("AgentSecretMissing", "An agent environment secret is unavailable")
                }
                env[name] = .string(value)
            }
            let body: JSONObject = ["operation_id": .string(operation), "generation": .int(session.generation), "execution": .object(identity),
                "model": ["provider": .string(soul.provider!), "name": .string(soul.model!), "parameters": .object(soul.modelParameters)],
                "system_prompt": .string(prompt.system), "task": .array(prompt.task), "output_schema": data.outputSchema ?? .null,
                "tools": ["ask_human": .bool(soul.askHuman), "shell": true], "env": .object(env), "files": .array(prompt.files),
                "limits": ["max_turns": 50, "timeout_seconds": .int(max(1, Int(deadline.timeIntervalSinceNow)))], "continuation": continuation]
            // Identities are fixed across uncertain transport retries. Secrets are never persisted in the operation ledger.
            let scope = AgentModelScope(operationID: operation, generation: session.generation, execution: identity,
                provider: soul.provider!, model: soul.model!, maxCalls: 50, expiresAt: deadline, inputFileIDs: prompt.inputFileIDs,
                endUserID: endUserID, modelParameters: soul.modelParameters, credentialReference: soul.json["model"]?["credential_ref"], durableOwner: routes.agentOwner)
            let token = try await routes.agentModelScopes.activate(scope)
            do {
                try await routes.store.startAgentOperation(session: session, operation: operation,
                    digest: Tokens.sha256(JSONValue.object(body).compactJSON()), tokenHash: Tokens.sha256(token))
                session = try requireAgentSession(try await routes.store.agentSession(execution: execution))
                try await service.lease(execution: execution, generation: session.generation)
                let remote = try await service.start(body, token: token)
                try await routes.store.recordAgentRun(session: session, run: remote)
                let terminal = try await service.result(run: remote, operation: operation, deadline: deadline, isAborted: context.isAborted)
                let usage = await routes.agentModelScopes.revoke(token: token)
                roundUsage = roundUsage.plus(usage); cumulative = cumulative.plus(usage)
                let result = terminal["result"] ?? [:]
                try await routes.store.recordAgentResult(session: session, run: remote, event: terminal["last_event_id"]!.int!, result: result.compactJSON())
                session = try requireAgentSession(try await routes.store.agentSession(execution: execution))
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
                        formID: id, usage: cumulative.json.compactJSON(), resumeSequence: session.resumeSequence + 1))
                    return .pause(formID: id, usage: roundUsage)
                case "succeeded":
                    let candidate = try await routes.normalizeAgentCandidate(result["candidate"] ?? .null, session: session, files: files)
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
                            acceptedOutputs: JSONValue.object(decision.outputs).compactJSON(), usage: cumulative.json.compactJSON(), outputAttempt: decision.nextAttempt))
                        session = try requireAgentSession(try await routes.store.agentSession(execution: execution))
                        continuation = ["kind": "output_retry", "snapshot": snapshot, "feedback": .array(decision.feedback)]
                        try await Task.sleep(for: .milliseconds(decision.retryIntervalMs))
                        continue
                    }
                    let succeeded = decision.action == .succeeded
                    var value = NodeRunResult(status: succeeded ? .succeeded : .failed, inputs: inputs,
                        processData: ["agent_output_checks": .array(decision.checks.map(\.json))], outputs: decision.outputs,
                        metadata: ["agent_config_snapshot_id": .string(data.snapshotID), "total_tokens": .int(cumulative.totalTokens)], llmUsage: roundUsage,
                        error: succeeded ? "" : "Declared agent outputs failed validation",
                        errorType: succeeded ? "" : (decision.action == .failBranch ? "output_type_check_failed_fail_branch" : "output_type_check_failed"))
                    value.edgeSourceHandle = "source"
                    pending.addAgentOutcome(.init(session: session, status: succeeded ? "completed" : "failed",
                        acceptedOutputs: JSONValue.object(decision.outputs).compactJSON(), usage: cumulative.json.compactJSON()))
                    try await pending.agentCommits.commit(execution, result: value)
                    return .completed(value)
                case "failed", "cancelled":
                    let errorType = result["error_type"]?.string ?? "cancel_lost"
                    let known: Set<String> = ["model_error", "model_quota", "max_turns", "timeout", "ask_human_invalid", "sandbox_unavailable", "sandbox_error", "file_error", "cancel_lost", "internal"]
                    pending.addAgentOutcome(.init(session: session, status: "failed", usage: cumulative.json.compactJSON()))
                    let value = NodeRunResult(status: .failed, inputs: inputs, metadata: ["total_tokens": .int(cumulative.totalTokens)], llmUsage: roundUsage,
                        error: "The agent operation did not complete", errorType: known.contains(errorType) ? errorType : "internal")
                    try await pending.agentCommits.commit(execution, result: value)
                    return .completed(value)
                default: throw NodeError("AgentServiceProtocolError", "Invalid agent result")
                }
            } catch {
                _ = await routes.agentModelScopes.revoke(token: token)
                try? await routes.store.abandonAgentExecution(execution: execution, owner: routes.agentOwner, generation: session.generation)
                if error is CancellationError { throw CancellationError() }
                throw NodeError("AgentExecutionFailed", "The agent operation could not be committed")
            }
        }
    }
}

private func requireAgentSession(_ session: StoredAgentSession?) throws -> StoredAgentSession {
    guard let session else { throw NodeError("AgentExecutionMissing", "The agent execution is unavailable") }
    return session
}
