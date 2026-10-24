import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Vapor

struct ChatTurn: Sendable {
    var conversation: StoredChatConversation
    var message: StoredChatMessage
    var create: Bool
}

/// A fixed turn's parent thread. Query newest-first before walking parents, matching Dify's message_limit semantics.
struct ServerConversationMemory: ConversationMemory {
    let store: PostgresStore
    let runId: String
    func history(messageLimit: Int) async throws -> [ConversationMemoryTurn] {
        guard let current = try await store.chatMessage(runId: runId) else { return [] }
        let messages = try await store.chatMessages(doc: current.docId, conversation: current.conversationId,
                                                   account: current.accountId, limit: messageLimit > 0 ? messageLimit : 500, endUser: current.endUserId)
        var cursor = current.parentMessageId
        var history: [StoredChatMessage] = []
        for message in messages where message.id != current.id {
            guard let next = cursor else { break }
            if message.parentMessageId == nil { history.append(message); break }
            if next == message.id || next == "00000000-0000-0000-0000-000000000000" {
                history.append(message); cursor = message.parentMessageId
            }
        }
        return history.reversed().map { .init(query: $0.query, answer: $0.answer,
            files: (try? JSONValue.parse($0.files))?.array ?? [], outputFiles: (try? JSONValue.parse($0.outputFiles))?.array ?? []) }
    }
}

extension Routes {
    func registerChatRuns(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.post(":app", "advanced-chat", "workflows", "draft", "run") { req in await handle(req) { try await runChatDraft(req) } }
        apps.post(":app", "chat-messages", ":task", "stop") { req in await handle(req) { try await stopChatRun(req) } }
        apps.get(":app", "advanced-chat", "workflows", "draft", "conversation-variables") { req in
            await handle(req) { try await chatVariables(req) }
        }
    }
    func runChatDraft(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, ["advanced-chat"])
        let raw = try await body(req)
        guard let b = (try? JSONValue.parse(raw))?.object, let inputs = b["inputs"]?.object,
              let query = b["query"]?.string else { throw Self.invalidParam("query and inputs are required") }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.invalidParam("query is required") }
        if let files = b["files"], files != .null, files.array == nil { throw Self.invalidParam("files must be a list") }
        let rawConversation = b["conversation_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let conversationId: String
        if let rawConversation {
            guard let uuid = Self.parseUUID(rawConversation) else { throw Self.invalidParam("conversation_id must be a UUID") }
            conversationId = uuid.uuidString.lowercased()
        } else { conversationId = UUID().uuidString.lowercased() }
        let parent = b["parent_message_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let parent, Self.parseUUID(parent) == nil { throw Self.invalidParam("parent_message_id must be a UUID") }
        var previous: StoredChatConversation?
        if rawConversation != nil {
            previous = try await store.chatConversation(doc: a.id, id: conversationId, account: p.id)
            guard previous != nil else { throw ServerError.notFound }
        }
        let (seq, workflow) = try await draftWorkflow(a.id, viewer: p.id)
        let runId = UUID().uuidString.lowercased()
        let pending = PendingHumanInputForms()
        var services = runServices(appId: a.id, runId: runId, docId: a.id, userId: p.id, pending: pending)
        services.memory = ServerConversationMemory(store: store, runId: runId)
        let prepared: PreparedRun
        do {
            prepared = try await PreparedRun.make(workflow: workflow, rawInputs: previous.flatMap { try? JSONValue.parse($0.inputs).object } ?? inputs,
                files: b["files"]?.array ?? [], services: services, userId: p.id, appId: a.id, workflowId: a.id, runId: runId, query: query)
        } catch { throw preparationError(error) }
        let at = Date()
        let values = JSONObject( (prepared.pool.variables["conversation"] ?? []).map { ($0.name, $0.segment.value) })
        let conversation = previous ?? StoredChatConversation(id: conversationId, docId: a.id, accountId: p.id,
            inputs: JSONValue.object(JSONObject(prepared.workflowInputs.filter { !$0.key.hasPrefix("sys.") }.map { ($0.key, $0.value) })).compactJSON(),
            variables: JSONValue.object(values).compactJSON(), at: at)
        let message = StoredChatMessage(id: UUID().uuidString.lowercased(), docId: a.id, conversationId: conversationId, accountId: p.id,
            parentMessageId: parent.flatMap(Self.parseUUID)?.uuidString.lowercased(), workflowRunId: runId, query: query,
            inputs: conversation.inputs, files: (prepared.workflowInputs["sys.files"] ?? []).compactJSON(), at: at)
        return try await startRun(appId: a.id, principal: p, seq: seq, workflow: workflow, runId: runId, graph: prepared.graph,
            pool: prepared.pool, workflowInputs: prepared.workflowInputs, nodeTriggeredFrom: "workflow-run", pendingForms: pending,
            chat: ChatTurn(conversation: conversation, message: message, create: previous == nil))
    }
    func stopChatRun(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, ["advanced-chat"])
        guard let runId = req.parameters.get("task"), let run = try await store.workflowRun(doc: a.id, id: runId),
              run.type == "chat", run.createdBy == p.id else { throw ServerError.notFound }
        if let active = await runs.get(runId), active.appId == a.id { active.commands.abort(reason: "Stopped by user") }
        if try await store.stopChatTurn(runId: runId, error: "Stopped by user", at: Date()) {
            await finishRunWithoutEngine(runId)
        }
        return rawJSON(["result": "success"])
    }
    func chatVariables(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, ["advanced-chat"])
        guard let id = query(req)["conversation_id"], let conversation = try await store.chatConversation(doc: a.id, id: id, account: p.id)
        else { throw ServerError.notFound }
        let (_, workflow) = try await draftWorkflow(a.id, viewer: p.id)
        let stored = (try? JSONValue.parse(conversation.variables))?.object ?? [:]
        let data = (workflow["conversation_variables"]?.array ?? []).map { declaration -> JSONValue in
            var value = declaration.object ?? [:]
            if let name = value["name"]?.string, let current = stored[name] { value["value"] = current }
            return .object(value)
        }
        return await fileJSONResponse(["data": .array(data)], userId: p.id)
    }

    static func chatMessageJSON(_ m: StoredChatMessage) -> JSONValue {
        ["id": .string(m.id), "conversation_id": .string(m.conversationId), "parent_message_id": m.parentMessageId.map(JSONValue.string) ?? .null,
         "workflow_run_id": .string(m.workflowRunId), "query": .string(m.query), "answer": .string(m.answer),
         "inputs": (try? JSONValue.parse(m.inputs)) ?? [:], "message_files": (try? JSONValue.parse(m.files)) ?? [],
         "files": (try? JSONValue.parse(m.outputFiles)) ?? [], "status": .string(m.status), "error": m.error.map(JSONValue.string) ?? .null,
         "metadata": (try? JSONValue.parse(m.metadata)) ?? [:], "reasoning": (try? JSONValue.parse(m.reasoning)) ?? [:],
         "created_at": .int(Int(m.createdAt.timeIntervalSince1970))]
    }
}

struct ChatProgress: Sendable {
    var message: StoredChatMessage
    var reasoning: JSONObject
    var variables: JSONObject = [:]
    init(_ message: StoredChatMessage) {
        self.message = message
        reasoning = (try? JSONValue.parse(message.reasoning))?.object ?? [:]
    }
}

extension RunExecution {
    /// Text and reasoning are persisted before publication. A resumed round starts with the same durable message,
    /// while a reconnect receives a replacement of its full contents rather than appending duplicated chunks.
    func publish(_ frame: JSONValue, generation: Int? = nil) async {
        guard encoderBox.withLock({ $0.chat != nil }) else {
            await channel.publish(Self.sse(frame), pauseGeneration: generation); return
        }
        var output = frame.object ?? [:]
        let event = output["event"]?.string ?? ""
        let saved = progress.withLock { state -> StoredChatMessage? in
            guard var stateValue = state else { return nil }
            if event == "text_chunk" {
                let text = output["data"]?["text"]?.string ?? ""
                stateValue.message.answer += text
                output["event"] = "message"; output["answer"] = .string(text)
                output["id"] = .string(stateValue.message.id)
                output["data"] = nil
            } else if event == "reasoning_chunk" {
                if var data = output["data"]?.object { data["message_id"] = .string(stateValue.message.id); output["data"] = .object(data) }
                let node = output["data"]?["node_id"]?.string ?? ""
                let old = stateValue.reasoning[node]?.string ?? ""
                stateValue.reasoning[node] = .string(old + (output["data"]?["reasoning"]?.string ?? ""))
                stateValue.message.reasoning = JSONValue.object(stateValue.reasoning).compactJSON()
            }
            if event == "node_finished", output["data"]?["node_type"]?.string == NodeType.answer,
               let files = output["data"]?["outputs"]?["files"]?.array, !files.isEmpty {
                var accumulated = (try? JSONValue.parse(stateValue.message.outputFiles))?.array ?? []
                var ids = Set(accumulated.map { $0["related_id"]?.string ?? $0.compactJSON() })
                for file in files where ids.insert(file["related_id"]?.string ?? file.compactJSON()).inserted { accumulated.append(file) }
                stateValue.message.outputFiles = JSONValue.array(accumulated).compactJSON()
            }
            state = stateValue
            return ["text_chunk", "reasoning_chunk", "node_finished"].contains(event) ? stateValue.message : nil
        }
        if let saved {
            do {
                guard try await routes.store.saveChatProgress(runId: runId, lease: lease, answer: saved.answer,
                    reasoning: saved.reasoning, files: saved.outputFiles, metadata: saved.metadata) else { return }
            } catch {
                routes.logger.error("chat progress could not be stored: \(error)")
                if let active = await routes.runs.get(taskId) { active.commands.abort(reason: "Could not save the conversation") }
                return
            }
        }
        // TEST ONLY: deterministically expose persistence-before-publication to a reconnecting real route.
        if routes.config.testDefect == "slowChatPublication", event == "text_chunk", !(output["answer"]?.string ?? "").isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
        }
        let reasoning: ChatReasoningCursor? = event == "reasoning_chunk" ? progress.withLock { state in
            let node = output["data"]?["node_id"]?.string ?? ""
            return ChatReasoningCursor(nodeId: node, bytes: (state?.reasoning[node]?.string ?? "").utf8.count)
        } : nil
        await channel.publish(Self.sse(await routes.projectRuntimeFiles(.object(output), userId: createdBy, endUserId: progress.withLock { $0?.message.endUserId })),
            pauseGeneration: generation, chatOffset: event == "text_chunk" ? progress.withLock { $0?.message.answer.utf8.count } : nil,
            reasoning: reasoning)
        if event == "workflow_finished", let message = progress.withLock({ $0?.message }) {
            await channel.publish(Self.sse(await routes.chatEndFrame(message)))
        }
    }
    func saveConversationVariables(_ values: JSONObject) async {
        guard let saved = progress.withLock({ state -> ChatProgress? in
            guard var value = state else { return nil }
            value.variables = value.variables.merging(values); state = value; return value
        }) else { return }
        do {
            _ = try await routes.store.saveChatProgress(runId: runId, lease: lease, answer: saved.message.answer,
                reasoning: saved.message.reasoning, files: saved.message.outputFiles, metadata: saved.message.metadata,
                variables: JSONValue.object(saved.variables).compactJSON())
        } catch { routes.logger.error("chat variables could not be stored: \(error)") }
    }
}

extension Routes {
    func chatEndFrame(_ message: StoredChatMessage) async -> JSONValue {
        await projectRuntimeFiles(["event": "message_end", "task_id": .string(message.workflowRunId),
            "workflow_run_id": .string(message.workflowRunId), "message_id": .string(message.id), "id": .string(message.id),
            "conversation_id": .string(message.conversationId), "created_at": .int(Int(message.createdAt.timeIntervalSince1970)),
            "metadata": (try? JSONValue.parse(message.metadata)) ?? [:], "files": (try? JSONValue.parse(message.outputFiles)) ?? []], userId: message.accountId, endUserId: message.endUserId)
    }
    func chatReplaceFrame(_ message: StoredChatMessage) async -> JSONValue {
        await projectRuntimeFiles(["event": "message_replace", "task_id": .string(message.workflowRunId),
            "workflow_run_id": .string(message.workflowRunId), "message_id": .string(message.id),
            "conversation_id": .string(message.conversationId), "answer": .string(message.answer),
            "reasoning": (try? JSONValue.parse(message.reasoning)) ?? [:], "files": (try? JSONValue.parse(message.outputFiles)) ?? [],
            "created_at": .int(Int(message.createdAt.timeIntervalSince1970))], userId: message.accountId, endUserId: message.endUserId)
    }
}

extension RunExecution {
    func saveChatMetadata(usage: LLMUsage? = nil, resources: [JSONValue]? = nil) async -> Bool {
        guard let message = progress.withLock({ value -> StoredChatMessage? in
            guard var state = value else { return nil }
            var metadata = (try? JSONValue.parse(state.message.metadata))?.object ?? [:]
            if let usage { metadata["usage"] = usage.json }
            if let resources { metadata["retriever_resources"] = .array(resources) }
            state.message.metadata = JSONValue.object(metadata).compactJSON(); value = state
            return state.message
        }) else { return true }
        do {
            return try await routes.store.saveChatProgress(runId: runId, lease: lease, answer: message.answer,
                reasoning: message.reasoning, files: message.outputFiles, metadata: message.metadata)
        } catch {
            routes.logger.error("chat metadata could not be stored: \(error)")
            return false
        }
    }
}
