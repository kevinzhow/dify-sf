// Agent v2 model gateway: reuses Dify's prompt/chunk protocol, with a run-scoped capability.
// The agent loop never receives provider credentials. This endpoint is not a model-provider API for clients.
import CollabRuntime
import Configuration
import Foundation
import HTTPTypes
import Vapor

public struct AgentServiceConfig: Sendable {
    public var url: String
    public var key: String
    public var maxConcurrent: Int
    public var timeoutSeconds: Int
    public var timeoutSecondsMax: Int
    public var inlineEnabled: Bool
    public var shellEnabled: Bool

    public init(reader: ConfigReader) {
        shellEnabled = reader.bool(forKey: "collab.agent.shell.enabled", default: false)
        inlineEnabled = reader.bool(forKey: "collab.agent.inline.enabled", default: false)
        url = reader.string(forKey: "collab.agent.service.url", default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        key = reader.string(forKey: "collab.agent.service.key", isSecret: true, default: "")
        maxConcurrent = max(1, reader.int(forKey: "collab.agent.maxConcurrent", default: 2))
        timeoutSeconds = max(1, reader.int(forKey: "collab.agent.timeoutSeconds", default: 1800))
        timeoutSecondsMax = max(1, min(86400, reader.int(forKey: "collab.agent.timeoutSecondsMax", default: 86400)))
    }

    public var isConfigured: Bool { !url.isEmpty && !key.isEmpty }
}

/// Constructed only by the workflow runtime, never from an HTTP caller's claimed identity.
struct AgentModelFileError: Error {}

struct AgentModelScope: Sendable {
    var operationID: String
    var generation: Int
    var execution: JSONObject
    var provider: String
    var model: String
    var maxCalls: Int
    var expiresAt: Date
    var inputFileIDs: Set<String> = []
    var endUserID: String? = nil
    var modelParameters: JSONObject? = nil
    var credentialReference: JSONValue? = nil
    var durableOwner: String? = nil
    var harnessStyle: String = "dify"
    var modelWire: String = "plugin"
    var outputTokenLimit: Int? = nil

    var appID: String { execution["app_id"]?.string ?? "" }
    var workflowRunID: String { execution["workflow_run_id"]?.string ?? "" }
    var executionID: String { execution["execution_id"]?.string ?? "" }
    var userID: String { execution["user_id"]?.string ?? "" }
    var executionKey: String { "\(appID):\(workflowRunID):\(executionID)" }

    var caller: JSONObject {
        var fields = execution
        fields["node_execution_id"] = fields["execution_id"]
        fields["execution_id"] = nil
        fields["operation_id"] = .string(operationID)
        return fields
    }
}

enum AgentModelGatewayLimits {
    // Append-only histories for long tool runs, while keeping one request bounded.
    static let messages = 8192
    static let requestBytes = 32 << 20
    static let fileBytes = 20 << 20
    // Codex: 5 request attempts inside 6 stream attempts.
    static let attempts = 30
}

struct AgentModelGatewayRequest: Sendable {
    let caller: JSONObject
    let provider: String
    let model: String
    let messages: [PromptMessage]
    let parameters: JSONObject
    let tools: [PromptMessageTool]
    let stop: [String]
    let callIndex: Int
    let invocationID: String
    let attempt: Int

    static func invalid() -> ServerError { .badRequest("Invalid agent model request") }

    init(_ value: JSONValue) throws {
        guard let caller = value["caller"]?.object, let target = value["target"]?.object,
              let provider = target["provider"]?.string, !provider.isEmpty,
              let model = target["model"]?.string, !model.isEmpty,
              let rawMessages = target["prompt_messages"]?.array, !rawMessages.isEmpty, rawMessages.count <= AgentModelGatewayLimits.messages,
              case .int(let callIndex)? = caller["call_index"], callIndex >= 1,
              let runID = caller["run_id"]?.string, !runID.isEmpty, runID.utf8.count <= 128,
              let invocationID = caller["invocation_id"]?.string, invocationID == "\(runID):\(callIndex)",
              target["stream"] == true else { throw Self.invalid() }
        self.caller = caller
        self.provider = provider
        self.model = model
        self.callIndex = callIndex
        self.invocationID = invocationID
        if let value = caller["attempt"] {
            guard case .int(let attempt) = value, (1...AgentModelGatewayLimits.attempts).contains(attempt) else { throw Self.invalid() }
            self.attempt = attempt
        } else { self.attempt = 1 }
        if let raw = target["model_parameters"], raw != .null {
            guard let object = raw.object else { throw Self.invalid() }
            parameters = object
        } else { parameters = [:] }
        if let raw = (target["stop"] == .null ? nil : target["stop"]) ?? parameters["stop"], raw != .null {
            guard let array = raw.array, array.count <= 32, array.allSatisfy({ $0.string != nil }) else { throw Self.invalid() }
            stop = array.compactMap(\.string)
        } else { stop = [] }
        if let raw = target["tools"], raw != .null {
            guard let array = raw.array, array.count <= 128 else { throw Self.invalid() }
            tools = try array.map { tool in
                guard let name = tool["name"]?.string, !name.isEmpty, name.utf8.count <= 128,
                      let schema = tool["parameters"]?.object else { throw Self.invalid() }
                return PromptMessageTool(name: name, description: tool["description"]?.string ?? "", parameters: schema)
            }
        } else { tools = [] }
        messages = try rawMessages.map(Self.message)
    }

    static func message(_ raw: JSONValue) throws -> PromptMessage {
        guard let roleName = raw["role"]?.string, let role = PromptMessageRole(rawValue: roleName) else { throw invalid() }
        let content: PromptMessage.Content
        switch raw["content"] {
        case nil, .null?: content = .none
        case .string(let text)?: content = .text(text)
        case .array(let rawParts)?:
            content = .parts(try rawParts.map { part in
                switch part["type"]?.string {
                case "text": return .text(part["data"]?.string ?? "")
                case "image":
                    // The agent obtains bytes through the execution-scoped file API, not arbitrary model-side URL fetches.
                    guard let bytes = part["base64_data"]?.string, !bytes.isEmpty,
                          (part["url"]?.string ?? "").isEmpty, let mime = part["mime_type"]?.string,
                          mime.hasPrefix("image/"), Data(base64Encoded: bytes) != nil else { throw invalid() }
                    return .image(base64Data: bytes, format: part["format"]?.string ?? "",
                                  mimeType: mime, filename: part["filename"]?.string ?? "", detail: part["detail"]?.string ?? "auto")
                case "document", "audio", "video":
                    guard let bytes = part["base64_data"]?.string, !bytes.isEmpty,
                          (part["url"]?.string ?? "").isEmpty, let mime = part["mime_type"]?.string,
                          Data(base64Encoded: bytes) != nil else { throw invalid() }
                    return .media(type: part["type"]!.string!, base64Data: bytes, format: part["format"]?.string ?? "",
                                  mimeType: mime, filename: part["filename"]?.string ?? "")
                default: throw invalid()
                }
            })
        default: throw invalid()
        }
        let toolCalls: [PromptMessage.ToolCall]
        if let rawCalls = raw["tool_calls"], rawCalls != .null {
            guard role == .assistant, let array = rawCalls.array, array.count <= 128 else { throw invalid() }
            toolCalls = try array.map { value in
                let call = PromptMessage.ToolCall(json: value)
                guard !call.id.isEmpty, !call.name.isEmpty else { throw invalid() }
                return call
            }
        } else { toolCalls = [] }
        let toolCallID = raw["tool_call_id"]?.string
        if role == .tool, toolCallID?.isEmpty != false { throw invalid() }
        return PromptMessage(role: role, content: content, name: raw["name"]?.string, toolCalls: toolCalls, toolCallId: toolCallID,
                             reasoningContent: role == .assistant ? raw["reasoning_content"]?.string : nil)
    }
}

/// An operation's capabilities expire on completion or ownership change. No public endpoint can create one.
actor AgentModelScopes {
    struct Entry: Sendable {
        var scope: AgentModelScope
        var calls: Set<Int> = []
        var tasks: [Int: Task<Void, Never>] = [:]
        var usage: [Int: LLMUsage] = [:]
        var activeCall: Int?
        var activeAttempt: Int?
        var retryableCalls: [Int: Int] = [:]
        var invocations: [Int: String] = [:]
        var codexActive: Set<Int> = []
    }
    struct Claim: Sendable { var digest: String; var scope: AgentModelScope; var index: Int; var attempt: Int = 1; var codex: Bool = false }
    private var entries: [String: Entry] = [:]
    private var generations: [String: Int] = [:]

    func activate(_ scope: AgentModelScope) throws -> String {
        guard scope.generation >= 1, scope.maxCalls >= 1, scope.maxCalls <= 1000,
              !scope.operationID.isEmpty, !scope.appID.isEmpty, !scope.workflowRunID.isEmpty,
              !scope.executionID.isEmpty, !scope.userID.isEmpty, scope.expiresAt > Date() else {
            throw AgentModelGatewayRequest.invalid()
        }
        if let generation = generations[scope.executionKey], scope.generation < generation { throw Self.stale() }
        if scope.generation > (generations[scope.executionKey] ?? 0) {
            for (digest, entry) in entries where entry.scope.executionKey == scope.executionKey {
                for task in entry.tasks.values { task.cancel() }
                entries[digest] = nil
            }
        }
        guard !entries.values.contains(where: { $0.scope.executionKey == scope.executionKey }) else {
            throw ServerError.http(status: 409, code: "agent_operation_active", message: "The execution already has an active operation")
        }
        generations[scope.executionKey] = scope.generation
        let token = Tokens.random()
        entries[Tokens.sha256(token)] = Entry(scope: scope)
        return token
    }

    func activeScope(token: String) throws -> AgentModelScope {
        guard let entry = entries[Tokens.sha256(token)], entry.scope.expiresAt > Date(),
              generations[entry.scope.executionKey] == entry.scope.generation else { throw Self.denied() }
        return entry.scope
    }

    func claim(token: String, request: AgentModelGatewayRequest) throws -> Claim {
        try claim(token: token, caller: request.caller, provider: request.provider, model: request.model,
                  parameters: request.parameters, stop: request.stop, index: request.callIndex, attempt: request.attempt)
    }

    func claim(token: String, caller: JSONObject, provider: String, model: String, parameters: JSONObject,
               stop: [String], index: Int, attempt: Int) throws -> Claim {
        let digest = Tokens.sha256(token)
        guard var entry = entries[digest], entry.scope.expiresAt > Date() else { throw Self.denied() }
        let scope = entry.scope
        guard generations[scope.executionKey] == scope.generation else { throw Self.stale() }
        guard provider == scope.provider, model == scope.model, index >= 1, (1...AgentModelGatewayLimits.attempts).contains(attempt),
              scope.modelParameters.map({ expected in
                  expected.count == parameters.count && expected.allSatisfy { parameters[$0.key] == $0.value }
              }) ?? true,
              scope.modelParameters.map({ expected in stop == (expected["stop"]?.array?.compactMap(\.string) ?? []) }) ?? true,
              scope.caller.allSatisfy({ caller[$0.key] == $0.value }) else { throw Self.denied() }
        guard index <= scope.maxCalls else {
            throw ServerError.http(status: 429, code: "agent_call_limit", message: "Agent model call limit reached")
        }
        let invocation = caller["invocation_id"]?.string ?? ""
        guard entry.invocations[index] == nil || entry.invocations[index] == invocation else { throw Self.denied() }
        // Requests lost before admission need not have reached the gateway at all.
        guard !entry.calls.contains(index) || entry.retryableCalls[index].map({ attempt > $0 }) == true else {
            throw ServerError.http(status: 409, code: "duplicate_invocation", message: "This model invocation was already accepted")
        }
        guard entry.activeCall == nil, entry.codexActive.isEmpty else {
            throw ServerError.http(status: 409, code: "agent_call_in_progress", message: "A model invocation is still running")
        }
        entry.invocations[index] = invocation
        entry.calls.insert(index)
        entry.retryableCalls[index] = nil
        entry.activeCall = index
        entry.activeAttempt = attempt
        entries[digest] = entry
        return Claim(digest: digest, scope: scope, index: index, attempt: attempt)
    }

    func attach(_ task: Task<Void, Never>, to claim: Claim) {
        guard var entry = entries[claim.digest], generations[entry.scope.executionKey] == entry.scope.generation,
              claim.codex ? entry.codexActive.contains(claim.index) : (entry.activeCall == claim.index && entry.activeAttempt == claim.attempt) else {
            task.cancel(); return
        }
        entry.tasks[claim.index] = task
        entries[claim.digest] = entry
    }

    func finish(_ claim: Claim, usage: LLMUsage?, succeeded: Bool = true) {
        guard var entry = entries[claim.digest],
              claim.codex ? entry.codexActive.contains(claim.index) : (entry.activeCall == claim.index && entry.activeAttempt == claim.attempt) else { return }
        if let usage { entry.usage[claim.index] = entry.usage[claim.index].map { $0.plus(usage) } ?? usage }
        if claim.codex {
            entry.codexActive.remove(claim.index)
            entry.tasks[claim.index] = nil
            entries[claim.digest] = entry
            return
        }
        if !succeeded { entry.retryableCalls[claim.index] = claim.attempt }
        entry.activeAttempt = nil
        entry.tasks[claim.index] = nil
        if entry.activeCall == claim.index { entry.activeCall = nil }
        entries[claim.digest] = entry
    }

    /// Official Codex owns retry identities. Every accepted HTTP POST consumes
    /// a new slot, including retries and calls made by child agents.
    func claimCodex(token: String) throws -> Claim {
        let digest = Tokens.sha256(token)
        guard var entry = entries[digest], entry.scope.expiresAt > Date(),
              generations[entry.scope.executionKey] == entry.scope.generation,
              entry.scope.harnessStyle == "codex", entry.scope.modelWire == "responses" else { throw Self.denied() }
        let index = (entry.calls.max() ?? 0) + 1
        guard index <= entry.scope.maxCalls else { throw AgentCodexCallLimit() }
        entry.calls.insert(index)
        entries[digest] = entry
        // Keep the server's bounded stream buffers bounded across child agents.
        guard entry.codexActive.count < 8, entry.activeCall == nil else {
            throw ServerError.http(status: 503, code: "agent_model_busy", message: "Too many model requests are active")
        }
        entry.codexActive.insert(index)
        entries[digest] = entry
        return Claim(digest: digest, scope: entry.scope, index: index, codex: true)
    }

    func grantFiles(execution: String, generation: Int, files: Set<String>) {
        for (digest, var entry) in entries where entry.scope.executionID == execution && entry.scope.generation == generation {
            entry.scope.inputFileIDs.formUnion(files); entries[digest] = entry
        }
    }

    func revokeExecution(_ execution: String, generation: Int) {
        for (digest, entry) in entries where entry.scope.executionID == execution && entry.scope.generation == generation {
            for task in entry.tasks.values { task.cancel() }; entries[digest] = nil
        }
    }

    func revoke(token: String) -> LLMUsage {
        guard let entry = entries.removeValue(forKey: Tokens.sha256(token)) else { return .empty }
        for task in entry.tasks.values { task.cancel() }
        return entry.usage.keys.sorted().reduce(.empty) { $0.plus(entry.usage[$1]!) }
    }

    private static func denied() -> ServerError {
        .forbidden(code: "agent_run_forbidden", message: "The agent operation is not authorized")
    }
    private static func stale() -> ServerError {
        .http(status: 409, code: "stale_generation", message: "The execution ownership changed")
    }
}

extension Routes {
    func registerAgentModels(on routes: any RoutesBuilder) {
        routes.post("inner", "agent", "llm", "invoke") { req in
            await handle(req) {
                do { return try await invokeAgentModel(req) }
                catch is AgentModelFileError {
                    return rawJSON(["error": "file_error", "message": "The model file is not available to this execution"],
                                   status: .init(code: 422))
                }
            }
        }
        routes.post("inner", "agent", "responses") { req in
            await handle(req, cancellable: true) {
                do { return try await invokeAgentResponses(req) }
                catch is AgentModelFileError {
                    return rawJSON(["error": "file_error", "message": "The model file is not available to this execution"], status: .init(code: 422))
                }
            }
        }
        routes.post("inner", "agent", "codex", "v1", "responses") { req in
            await handle(req, cancellable: true) {
                do { return try await invokeAgentResponses(req, codex: true) }
                catch is AgentCodexCallLimit {
                    return rawJSON(["error": ["type": "usage_limit_reached", "code": "agent_call_limit", "message": "Agent model call limit reached"]], status: .init(code: 429))
                } catch is AgentModelFileError {
                    return rawJSON(["error": ["type": "invalid_request_error", "code": "file_error", "message": "The model file is not available to this execution"]], status: .init(code: 422))
                }
            }
        }
        routes.post("inner", "agent", "files", "download-request") { req in
            await handle(req) { try await downloadAgentFile(req) }
        }
    }

    func authenticateAgentService(_ req: Request) throws -> String {
        guard config.agentService.isConfigured else {
            throw ServerError.http(status: 503, code: "agent_not_configured", message: "The agent service is not configured")
        }
        let supplied = req.headers[.authorization] ?? ""
        guard Passwords.constantTimeEqual(Array(Tokens.sha256(supplied).utf8),
            Array(Tokens.sha256("Bearer " + config.agentService.key).utf8)) else {
            throw ServerError.unauthorized("Invalid agent service authentication")
        }
        guard let token = req.headers[HTTPField.Name("X-Agent-Run-Token")!], !token.isEmpty else {
            throw ServerError.unauthorized("An agent run token is required")
        }
        return token
    }

    private func downloadAgentFile(_ req: Request) async throws -> Response {
        let token = try authenticateAgentService(req)
        let scope = try await agentModelScopes.activeScope(token: token)
        if scope.durableOwner != nil { try await requireDurableAgentScope(scope) }
        let bytes = try await req.body.collect(max: .specified(ByteCount(value: 4096))) ?? Data()
        guard let payload = try? JSONValue.parse(bytes), let id = payload["file_id"]?.string,
              scope.inputFileIDs.contains(id) else { throw ServerError.missing("File not found") }
        guard let run = try await store.workflowRun(doc: scope.appID, id: scope.workflowRunID), run.status == "running", run.type == "workflow" else {
            throw ServerError.forbidden(code: "agent_run_inactive", message: "The workflow run is not active")
        }
        _ = try await liveApp(scope.appID, viewer: scope.userID)
        let files = ServerWorkflowFiles(routes: self, userId: scope.userID, endUserId: scope.endUserID)
        let file = try await files.resolve(["transfer_method": "local_file", "upload_file_id": .string(id)], config: nil)
        guard let signer = FileSigner(config: config.files, internalAudience: true) else {
            throw ServerError.unavailable("File storage is not configured")
        }
        let now = Date()
        return try json(JSONValue.object(["url": .string(signer.url(id: file.recordId, now: now)),
                         "expires_at": .int(Int(now.timeIntervalSince1970) + signer.lifetime),
                         "mime_type": .string(file.mimeType), "size": .int(file.size)]))
    }

    /// A stable reference is only an identifier. Authorization comes from the operation's private input set.
    /// Read local storage directly; no model-side URL fetch or expiring link enters this path.
    private func normalizeAgentFiles(_ payload: JSONValue, scope: AgentModelScope) async throws -> JSONValue {
        guard var root = payload.object, var target = root["target"]?.object,
              var messages = target["prompt_messages"]?.array else { throw AgentModelGatewayRequest.invalid() }
        var fileBytes = 0
        for i in messages.indices {
            guard var message = messages[i].object, var parts = message["content"]?.array else { continue }
            for j in parts.indices {
                guard var part = parts[j].object, let type = part["type"]?.string,
                      ["image", "document", "audio", "video"].contains(type) else { continue }
                guard (part["base64_data"]?.string ?? "").isEmpty,
                      let reference = part["url"]?.string, reference.hasPrefix("dify-sf-file:") else { throw AgentModelFileError() }
                let id = String(reference.dropFirst("dify-sf-file:".count))
                guard UUID(uuidString: id)?.uuidString.lowercased() == id, scope.inputFileIDs.contains(id) else { throw AgentModelFileError() }
                let files = ServerWorkflowFiles(routes: self, userId: scope.userID, endUserId: scope.endUserID)
                let mapping: JSONValue = ["transfer_method": "local_file", "upload_file_id": .string(id)]
                let file: RuntimeFile
                let bytes: [UInt8]
                do {
                    file = try await files.resolve(mapping, config: nil)
                    fileBytes += file.size
                    guard fileBytes <= AgentModelGatewayLimits.fileBytes else { throw ServerError.payloadTooLarge }
                    guard (type != "image" || file.mimeType.hasPrefix("image/")),
                          (type != "audio" || file.mimeType.hasPrefix("audio/")),
                          (type != "video" || file.mimeType.hasPrefix("video/")) else { throw AgentModelFileError() }
                    bytes = try await files.bytes(mapping)
                } catch is RuntimeFileError { throw AgentModelFileError() }
                part["base64_data"] = .string(Data(bytes).base64EncodedString()); part["url"] = ""
                part["mime_type"] = .string(file.mimeType); part["filename"] = .string(file.filename)
                part["format"] = .string(file.extensionName)
                parts[j] = .object(part)
            }
            message["content"] = .array(parts); messages[i] = .object(message)
        }
        target["prompt_messages"] = .array(messages); root["target"] = .object(target)
        let normalized = JSONValue.object(root)
        guard normalized.compactJSON().utf8.count <= AgentModelGatewayLimits.requestBytes else { throw ServerError.payloadTooLarge }
        return normalized
    }

    private func invokeAgentModel(_ req: Request) async throws -> Response {
        guard config.agentService.isConfigured, runtimeConfigured else {
            throw ServerError.http(status: 503, code: "agent_not_configured", message: "The agent model gateway is not configured")
        }
        let token = try authenticateAgentService(req)
        let bytes = try await req.body.collect(max: .specified(ByteCount(value: AgentModelGatewayLimits.requestBytes))) ?? Data()
        let payload: JSONValue
        do { payload = try JSONValue.parse(bytes) } catch { throw AgentModelGatewayRequest.invalid() }
        let authorized = try await agentModelScopes.activeScope(token: token)
        if authorized.durableOwner != nil { try await requireDurableAgentScope(authorized) }
        guard let caller = payload["caller"]?.object,
              authorized.caller.allSatisfy({ caller[$0.key] == $0.value }),
              payload["target"]?["provider"] == .string(authorized.provider),
              payload["target"]?["model"] == .string(authorized.model) else {
            throw ServerError.forbidden(code: "agent_run_forbidden", message: "The agent operation is not authorized")
        }
        let scope = authorized
        guard scope.modelWire == "plugin" else {
            throw ServerError.forbidden(code: "agent_model_wire", message: "This operation uses a different model channel")
        }
        // Current machine state still wins over an issued token (e.g. stop or delete between two model turns).
        guard let run = try await store.workflowRun(doc: scope.appID, id: scope.workflowRunID),
              run.status == "running", run.type == "workflow" else {
            throw ServerError.forbidden(code: "agent_run_inactive", message: "The workflow run is not active")
        }
        _ = try await liveApp(scope.appID, viewer: scope.userID)
        guard let models = runtimeServices(appId: scope.appID, userId: scope.userID).models else {
            throw ServerError.http(status: 503, code: "agent_not_configured", message: "The model runtime is not configured")
        }
        let normalized = try await normalizeAgentFiles(payload, scope: scope)
        let request = try AgentModelGatewayRequest(normalized)
        let claim = try await agentModelScopes.claim(token: token, request: request)
        // The complete accepted response is capped below; buffering cannot exceed 8 MiB per operation.
        let (frames, continuation) = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .unbounded)
        let scopes = agentModelScopes
        let task = Task<Void, Never> {
            var lastUsage: LLMUsage?
            do {
                try Task.checkCancellation()
                let credentials: JSONObject
                if scope.credentialReference != nil { credentials = try await self.agentCredentials(provider: request.provider, model: request.model, reference: scope.credentialReference) }
                else { credentials = try await models.credentials(provider: request.provider, model: request.model, modelType: "llm") }
                try Task.checkCancellation()
                var parameters = request.parameters
                parameters["stop"] = nil
                let instance = ModelInstance(provider: request.provider, modelName: request.model, credentials: credentials,
                                             parameters: parameters, stop: request.stop)
                var size = 0
                for try await chunk in models.invokeLLM(instance, promptMessages: request.messages, parameters: parameters,
                    tools: request.tools, stop: request.stop, stream: request.tools.isEmpty, user: scope.userID) {
                    try Task.checkCancellation()
                    if let usage = chunk.usage { lastUsage = usage }
                    let envelope: JSONValue = ["code": 0, "message": "", "data": chunk.json]
                    let frame = "data: " + envelope.compactJSON() + "\n\n"
                    size += frame.utf8.count
                    guard size <= 8 << 20 else { throw AgentModelGatewayRequest.invalid() }
                    if case .dropped = continuation.yield(frame) { throw AgentModelGatewayRequest.invalid() }
                }
                await scopes.finish(claim, usage: lastUsage)
                continuation.finish()
            } catch is CancellationError {
                await scopes.finish(claim, usage: lastUsage, succeeded: false)
                continuation.finish(throwing: CancellationError())
            } catch {
                // Upstream errors may quote a provider key, prompt or signed URL. Do not reflect them.
                let inner: JSONValue = ["error_type": "AgentModelInvokeError", "message": "Agent model invocation failed"]
                let envelope: JSONValue = ["code": -500, "message": .string(inner.compactJSON()), "data": .null]
                continuation.yield("data: " + envelope.compactJSON() + "\n\n")
                await scopes.finish(claim, usage: lastUsage, succeeded: false)
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        await agentModelScopes.attach(task, to: claim)
        let body = try Response.Body(stream: { writer in
            do { for try await frame in frames { try await writer.write(frame) } }
            catch { task.cancel(); throw error }
        }, count: nil)
        return Response(status: .ok, headers: Self.eventHeaders, body: body)
    }
}
