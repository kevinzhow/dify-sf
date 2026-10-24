// Dify 1.17.1 service/web app surfaces. The engine is shared with console runs;
// caller identity, published revision and durable ownership are explicit.
import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

struct PublicCaller: Sendable {
    var app: StoredApp
    var executor: Principal
    var endUser: StoredEndUser
    var apiKeyId: String?
}
struct PublicRunBinding: Sendable {
    var endUser: StoredEndUser
    var version: StoredVersion
    var apiKeyId: String?
}

extension Routes {
    func registerPublicRuntime(on r: any RoutesBuilder) {
        r.get("v1", "passport") { req in await handle(req) { try await publicPassport(req) } }
        for path in ["site", "info", "parameters", "meta"] {
            r.get("v1", .constant(path)) { req in await handle(req) { try await publicDefinition(req, kind: path) } }
        }
        r.post("v1", "workflows", "run") { req in await handle(req) { try await runPublished(req, chat: false) } }
        r.post("v1", "chat-messages") { req in await handle(req) { try await runPublished(req, chat: true) } }
        r.get("v1", "workflows", "run", ":publicRun") { req in await handle(req) { try await publicRunDetail(req) } }
        r.post("v1", "workflows", "tasks", ":publicRun", "stop") { req in await handle(req) { try await stopPublicRun(req) } }
        r.post("v1", "chat-messages", ":publicRun", "stop") { req in await handle(req) { try await stopPublicRun(req) } }
        r.get("v1", "conversations") { req in await handle(req) { try await publicConversations(req) } }
        r.get("v1", "messages") { req in await handle(req) { try await publicMessages(req) } }
    }

    func publicCaller(_ req: Request, user suppliedUser: String? = nil) async throws -> PublicCaller {
        guard let token = bearer(req, allowQuery: false), token.utf8.count <= 512 else { throw ServerError.unauthorized("missing app bearer token") }
        let appId: String
        let endUser: StoredEndUser
        let keyId: String?
        if let session = try await store.publicSession(tokenHash: Tokens.sha256(token), at: Date()) {
            if let code = req.headers[HTTPField.Name("X-App-Code")!], code != session.siteCode { throw ServerError.notFound }
            appId = session.endUser.appId; endUser = session.endUser; keyId = nil
        } else if let key = try await store.apiKey(byHash: Tokens.sha256(token)),
                  let app = try await store.app(key.doc, viewer: ""), app.enableApi, !app.deleted {
            let user = suppliedUser ?? query(req)["user"] ?? ""
            guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, user.utf8.count <= 256 else {
                throw Self.invalidParam("user is required and must not exceed 256 bytes")
            }
            appId = key.doc; keyId = key.id
            endUser = try await store.endUser(appId: key.doc, source: "api", namespace: key.id, externalId: user)
            try await store.touchApiKey(key.id)
        } else { throw ServerError.unauthorized("invalid or revoked app bearer token") }
        guard let app = try await store.app(appId, viewer: ""), !app.deleted,
              let owner = app.createdBy, let account = try await store.account(id: owner), account.status == "active",
              let role = account.role.flatMap(Role.init(rawValue:)), role.canEdit else { throw ServerError.notFound }
        return PublicCaller(app: app, executor: Principal(account: account, role: role, sessionId: ""), endUser: endUser, apiKeyId: keyId)
    }

    private func publicPassport(_ req: Request) async throws -> Response {
        guard let code = req.headers[HTTPField.Name("X-App-Code")!], code.utf8.count <= 256,
              let site = try await store.publicSiteApp(code: code) else { throw ServerError.notFound }
        // An unproved user_id is never an identity credential. Existing visitors
        // retain their separate opaque passport; console access tokens do not work.
        if bearer(req, allowQuery: false) != nil {
            let caller = try await publicCaller(req)
            guard caller.app.id == site.appId, caller.apiKeyId == nil else { throw ServerError.notFound }
            return try json(JSONValue.object(["access_token": .string(bearer(req, allowQuery: false)!)]))
        }
        guard query(req)["user_id"] == nil else { throw Self.invalidParam("Restoring a visitor requires its passport") }
        let user = try await store.endUser(appId: site.appId, source: "web-app", namespace: code, externalId: UUID().uuidString.lowercased())
        let token = Tokens.random()
        try await store.createPublicSession(tokenHash: Tokens.sha256(token), endUser: user.id, siteCode: code,
                                            expiresAt: Date().addingTimeInterval(30 * 86400))
        return try json(JSONValue.object(["access_token": .string(token)]))
    }

    func publishedDefinition(_ caller: PublicCaller) async throws -> (StoredVersion, JSONValue) {
        guard ["workflow", "advanced-chat"].contains(caller.app.mode), let version = try await store.latestVersion(caller.app.id) else {
            throw ServerError.http(status: 404, code: "app_unavailable", message: "This app has no published workflow")
        }
        let root = try DifyDSL.exportValue(WireJSON.decode(Document.self, from: version.state),
            metadata: WireJSON.decode(Value.self, from: version.dsl), secrets: try await store.secrets(caller.app.id))
        return (version, try JSONValue.parse(WireJSON.encode(root))["workflow"] ?? .null)
    }

    private func publicDefinition(_ req: Request, kind: String) async throws -> Response {
        let caller = try await publicCaller(req)
        let (version, workflow) = try await publishedDefinition(caller)
        if kind == "meta" { return rawJSON(["tool_icons": [:]]) }
        let start = workflow["graph"]?["nodes"]?.array?.first { $0["data"]?["type"]?.string == "start" }
        let form: [JSONValue] = (start?["data"]?["variables"]?.array ?? []).map { variable in
            let type = variable["type"]?.string ?? "text-input"
            var field = variable.object ?? [:]; field["variable"] = variable["variable"]
            return .object([type: .object(field)])
        }
        let parameters: JSONValue = ["user_input_form": .array(form), "file_upload": workflow["features"]?["file_upload"] ?? [:],
            "opening_statement": workflow["features"]?["opening_statement"] ?? "", "suggested_questions": workflow["features"]?["suggested_questions"] ?? [],
            "retriever_resource": workflow["features"]?["retriever_resource"] ?? [:], "speech_to_text": workflow["features"]?["speech_to_text"] ?? [:],
            "text_to_speech": workflow["features"]?["text_to_speech"] ?? [:]]
        if kind == "parameters" { return try json(parameters) }
        var site:JSONObject=[:]
        if let stored=try await store.siteJSON(caller.app.id),let fields=try JSONValue.parse(stored).object {
            for key in ["title","description","icon_type","icon","icon_background","default_language","copyright","privacy_policy","input_placeholder","custom_disclaimer","show_workflow_steps","use_icon_as_answer_icon"] { site[key]=fields[key] }
        }
        return try json(JSONValue.object(["id": .string(caller.app.id), "name": .string(caller.app.name),
            "site":.object(site), "title": site["title"] ?? .string(caller.app.name), "mode": .string(caller.app.mode), "description": .string(caller.app.description),
            "workflow_id": .string(version.id), "parameters": parameters]))
    }

    private func runPublished(_ req: Request, chat isChat: Bool) async throws -> Response {
        guard let b = (try? JSONValue.parse(try await body(req)))?.object, let inputs = b["inputs"]?.object else {
            throw Self.invalidParam("inputs must be an object")
        }
        let caller = try await publicCaller(req, user: b["user"]?.string)
        guard caller.app.mode == (isChat ? "advanced-chat" : "workflow") else { throw Self.invalidParam("App mode does not match this endpoint") }
        let mode = b["response_mode"]?.string ?? "streaming"
        guard ["streaming", "blocking"].contains(mode) else { throw Self.invalidParam("response_mode must be streaming or blocking") }
        if let files = b["files"], files != .null, files.array == nil { throw Self.invalidParam("files must be a list") }
        let (version, workflow) = try await publishedDefinition(caller)
        let id = UUID().uuidString.lowercased(), pending = PendingHumanInputForms()
        let services = runServices(appId: caller.app.id, runId: id, docId: caller.app.id, userId: caller.executor.id,
                                   pending: pending, endUserId: caller.endUser.id)
        let queryText = isChat ? b["query"]?.string : nil
        if isChat && (queryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { throw Self.invalidParam("query is required") }
        let conversationId = b["conversation_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var previous: StoredChatConversation?
        if isChat, let conversationId {
            previous = try await store.chatConversation(doc: caller.app.id, id: conversationId, account: caller.executor.id, endUser: caller.endUser.id)
            guard previous != nil else { throw ServerError.notFound }
        }
        let prepared: PreparedRun
        do {
            prepared = try await PreparedRun.make(workflow: workflow,
                rawInputs: previous.flatMap { try? JSONValue.parse($0.inputs).object } ?? inputs, files: b["files"]?.array ?? [],
                services: services, userId: caller.endUser.id, appId: caller.app.id, workflowId: version.id, runId: id, query: queryText)
        } catch { throw preparationError(error) }
        var turn: ChatTurn?
        if isChat {
            let at = Date()
            var conversation = previous ?? StoredChatConversation(id: UUID().uuidString.lowercased(), docId: caller.app.id,
                accountId: caller.executor.id, inputs: JSONValue.object(inputs).compactJSON(),
                variables: JSONValue.object(JSONObject((prepared.pool.variables["conversation"] ?? []).map { ($0.name, $0.segment.value) })).compactJSON(), at: at)
            conversation.endUserId = caller.endUser.id
            var message = StoredChatMessage(id: UUID().uuidString.lowercased(), docId: caller.app.id, conversationId: conversation.id,
                accountId: caller.executor.id, parentMessageId: b["parent_message_id"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                workflowRunId: id, query: queryText!, inputs: conversation.inputs, files: (prepared.workflowInputs["sys.files"] ?? []).compactJSON(), at: at)
            message.endUserId = caller.endUser.id
            turn = ChatTurn(conversation: conversation, message: message, create: previous == nil)
        }
        return try await startRun(appId: caller.app.id, principal: caller.executor, seq: version.seq, workflow: workflow, runId: id,
            graph: prepared.graph, pool: prepared.pool, workflowInputs: prepared.workflowInputs, nodeTriggeredFrom: "workflow-run", pendingForms: pending,
            chat: turn, publicRun: PublicRunBinding(endUser: caller.endUser, version: version, apiKeyId: caller.apiKeyId), responseMode: mode)
    }

    func publicBlockingResponse(subscription: AsyncStream<String>, runId: String, chat: StoredChatMessage?) async throws -> Response {
        for await frame in subscription {
            guard let data = frame.components(separatedBy: "data: ").last,
                  let value = try? JSONValue.parse(data.trimmingCharacters(in: .whitespacesAndNewlines)), let event = value["event"]?.string else { continue }
            if event == "workflow_paused" {
                var paused = value["data"]?.object ?? [:]
                if let chat {
                    let current = (try await store.chatMessage(runId:runId)) ?? chat
                    paused["id"] = .string(chat.id); paused["message_id"] = .string(chat.id)
                    paused["conversation_id"] = .string(chat.conversationId); paused["workflow_run_id"] = .string(runId)
                    paused["mode"] = "advanced-chat"; paused["answer"] = .string(current.answer)
                    paused["metadata"] = (try? JSONValue.parse(current.metadata)) ?? [:]
                    paused["created_at"] = Self.epochSeconds(current.createdAt)
                    return try json(JSONValue.object(["event":"workflow_paused","task_id":.string(runId),"id":.string(current.id),
                        "message_id":.string(current.id),"conversation_id":.string(current.conversationId),"mode":"advanced-chat",
                        "answer":.string(current.answer),"metadata":paused["metadata"] ?? [:],"created_at":Self.epochSeconds(current.createdAt),
                        "workflow_run_id":.string(runId),"data":.object(paused)]))
                }
                return try json(JSONValue.object(["task_id": .string(runId), "workflow_run_id": .string(runId), "data": .object(paused)]))
            }
            if event == "workflow_finished" {
                guard let run = try await store.workflowRun(id: runId) else { throw ServerError.notFound }
                if let chat, let message = try await store.chatMessage(runId: runId) {
                    // Dify's blocking converter raises its ErrorStreamResponse; it must not return an empty successful answer.
                    if run.status == "failed" { throw ServerError.http(status:400,code:"workflow_run_failed",message:run.error ?? "Workflow run failed") }
                    let value:JSONValue = ["event": "message", "task_id": .string(runId), "id": .string(message.id),
                        "message_id": .string(message.id), "conversation_id": .string(chat.conversationId), "mode": "advanced-chat",
                        "answer": .string(message.answer), "metadata": (try? JSONValue.parse(message.metadata)) ?? [:],
                        "files":(try? JSONValue.parse(message.outputFiles)) ?? [],"created_at": Self.epochSeconds(message.createdAt)]
                    return try json(await projectRuntimeFiles(value,userId:message.accountId,endUserId:message.endUserId))
                }
                return try json(JSONValue.object(["task_id": .string(runId), "workflow_run_id": .string(runId), "data": publicRunJSON(run)]))
            }
        }
        throw ServerError.unavailable("The run ended without a terminal record")
    }

    func publicRunJSON(_ run: StoredWorkflowRun) -> JSONValue {
        ["id": .string(run.id), "workflow_id": .string(run.workflowId), "status": .string(run.status),
         "outputs": (run.outputs.flatMap { try? JSONValue.parse($0) }) ?? .null, "error": run.error.map(JSONValue.string) ?? .null,
         "elapsed_time": .double(run.elapsedTime), "total_tokens": .int(run.totalTokens), "total_steps": .int(run.totalSteps),
         "created_at": Self.epochSeconds(run.createdAt), "finished_at": run.finishedAt.map(Self.epochSeconds) ?? .null]
    }
    private func publicRunDetail(_ req: Request) async throws -> Response {
        let caller = try await publicCaller(req)
        guard let id = req.parameters.get("publicRun"), let run = try await store.workflowRun(doc: caller.app.id, id: id),
              run.endUserId == caller.endUser.id else { throw ServerError.notFound }
        return try json(await projectRuntimeFiles(publicRunJSON(run), userId: caller.executor.id, endUserId: caller.endUser.id))
    }
    private func stopPublicRun(_ req: Request) async throws -> Response {
        let b = (try? JSONValue.parse(try await body(req)))?.object ?? [:]
        let caller = try await publicCaller(req, user: b["user"]?.string)
        guard let id = req.parameters.get("publicRun"), let run = try await store.workflowRun(doc: caller.app.id, id: id),
              run.endUserId == caller.endUser.id else { throw ServerError.notFound }
        if let active = await runs.get(id) { active.commands.abort(reason: "Stopped by user") }
        if run.type == "chat" {
            if try await store.stopChatTurn(runId: id, error: "Stopped by user", at: Date()) { await finishRunWithoutEngine(id) }
        } else if run.status == "paused" {
            if try await store.stopPausedRun(workflowRunId: id, error: "Stopped by user", at: Date()) { await finishRunWithoutEngine(id) }
        }
        return rawJSON(["result": "success"])
    }
    private func publicListLimit(_ req: Request, maximum: Int = 100) throws -> Int {
        guard let raw=query(req)["limit"] else { return 20 }
        guard let value=Int(raw),value>=1,value<=maximum else { throw Self.invalidParam("limit is out of range") }
        return value
    }
    private func publicConversations(_ req: Request) async throws -> Response {
        let caller = try await publicCaller(req), q=query(req), limit=try publicListLimit(req)
        let sort=q["sort_by"] ?? "-updated_at"
        guard ["created_at","-created_at","updated_at","-updated_at"].contains(sort) else { throw Self.invalidParam("sort_by is invalid") }
        var cursor:StoredChatConversation?
        if let id=q["last_id"],!id.isEmpty {
            cursor=try await store.chatConversation(doc:caller.app.id,id:id,account:caller.executor.id,endUser:caller.endUser.id)
            guard cursor != nil else { throw ServerError.notFound }
        }
        let values=try await store.publicConversations(app:caller.app.id,endUser:caller.endUser.id,limit:limit+1,cursor:cursor,sort:sort)
        return try json(JSONValue.object(["data": .array(values.prefix(limit).map { c in
            ["id": .string(c.id), "name": "New conversation", "inputs": (try? JSONValue.parse(c.inputs)) ?? [:],
             "created_at": Self.epochSeconds(c.createdAt), "updated_at": Self.epochSeconds(c.updatedAt)]
        }), "has_more": .bool(values.count>limit), "limit": .int(limit)]))
    }
    private func publicMessages(_ req: Request) async throws -> Response {
        let caller = try await publicCaller(req), q=query(req), limit=try publicListLimit(req,maximum:101)
        guard let id = q["conversation_id"], try await store.chatConversation(doc: caller.app.id, id: id,
            account: caller.executor.id, endUser: caller.endUser.id) != nil else { throw ServerError.notFound }
        var cursor:StoredChatMessage?
        if let message=q["first_id"],!message.isEmpty {
            cursor=try await store.publicMessage(app:caller.app.id,conversation:id,endUser:caller.endUser.id,message:message)
            guard cursor != nil else { throw ServerError.notFound }
        }
        let values=try await store.chatMessages(doc:caller.app.id,conversation:id,account:caller.executor.id,limit:limit+1,endUser:caller.endUser.id,before:cursor)
        let response: JSONValue = ["data": .array(values.prefix(limit).reversed().map(Self.chatMessageJSON)), "has_more": .bool(values.count>limit), "limit": .int(limit)]
        return try json(await projectRuntimeFiles(response,userId:caller.executor.id,endUserId:caller.endUser.id))
    }
}
