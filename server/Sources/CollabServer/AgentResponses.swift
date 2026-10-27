// Native Responses transport. Provider credentials remain in the workflow server;
// opaque response items and SSE bytes are never converted to the plugin protocol.
import AsyncHTTPClient
import CollabRuntime
import Foundation
import HTTPTypes
import NIOCore
import Vapor

enum AgentModelWire {
    static let compatible = "langgenius/openai_api_compatible/openai_api_compatible"
    static let openAI = "langgenius/openai/openai"

    static func select(style: String, provider: String, credentials: JSONObject) -> String {
        style == "codex" && (provider == openAI || (provider == compatible && credentials["api_type"] == "responses"))
            ? "responses" : "plugin"
    }
}

struct AgentResponsesRequest: Sendable {
    let callIndex: Int
    let invocationID: String
    let attempt: Int
    var body: JSONObject

    init(body: JSONValue, index: String?, invocation: String?, attempt: String?, scope: AgentModelScope) throws {
        guard scope.harnessStyle == "codex", scope.modelWire == "responses" else {
            throw ServerError.forbidden(code: "agent_model_wire", message: "This operation uses a different model channel")
        }
        guard let index, let n = Int(index), n >= 1, String(n) == index,
              let invocation, invocation.hasSuffix(":\(n)"),
              invocation.utf8.count <= 160, invocation.count > ":\(n)".count,
              invocation.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              let a = Int(attempt ?? "1"), (1...AgentModelGatewayLimits.attempts).contains(a),
              String(a) == (attempt ?? "1"),
              var fields = body.object, fields["model"] == .string(scope.model),
              fields["stream"] == true, fields["store"] == false,
              let input = fields["input"]?.array, !input.isEmpty, input.count <= AgentModelGatewayLimits.messages else {
            throw AgentModelGatewayRequest.invalid()
        }
        // No previous_response_id, URLs, headers, hosted tools or other bypass of
        // the execution's local history, tools and file budget.
        let allowed: Set<String> = ["model", "input", "tools", "tool_choice", "parallel_tool_calls", "reasoning", "store",
            "stream", "include", "prompt_cache_key", "text", "max_output_tokens", "temperature", "top_p"]
        guard Set(fields.keys).isSubset(of: allowed),
              fields["tools"]?.array.map({ $0.count <= 128 && $0.allSatisfy { ["function", "custom"].contains($0["type"]?.string ?? "") } }) ?? true,
              fields["include"]?.array.map({ $0.allSatisfy { $0 == "reasoning.encrypted_content" } }) ?? true else {
            throw AgentModelGatewayRequest.invalid()
        }
        var reasoning = fields["reasoning"]?.object ?? [:]
        guard fields["reasoning"] == nil || fields["reasoning"]?.object != nil,
              Set(reasoning.keys).isSubset(of: ["effort", "summary"]) else { throw AgentModelGatewayRequest.invalid() }
        let params = scope.modelParameters ?? [:]
        if let effort = params["reasoning_effort"] {
            guard effort.string != nil, reasoning["effort"] == nil || reasoning["effort"] == effort else {
                throw AgentModelGatewayRequest.invalid()
            }
            reasoning["effort"] = effort
        } else if reasoning["effort"] != nil { throw AgentModelGatewayRequest.invalid() }
        fields["reasoning"] = .object(reasoning)
        for (source, target) in [("max_tokens", "max_output_tokens"), ("max_completion_tokens", "max_output_tokens"),
                                  ("max_output_tokens", "max_output_tokens"), ("temperature", "temperature"), ("top_p", "top_p")] {
            if let value = params[source] {
                guard fields[target] == nil || fields[target] == value else { throw AgentModelGatewayRequest.invalid() }
                fields[target] = value
            } else if source == target && target != "max_output_tokens", fields[target] != nil {
                throw AgentModelGatewayRequest.invalid()
            }
        }
        if let requested = fields["max_output_tokens"] {
            guard let n = requested.int, n > 0,
                  ["max_tokens", "max_completion_tokens", "max_output_tokens"].contains(where: { params[$0] == requested }) else {
                throw AgentModelGatewayRequest.invalid()
            }
        }
        // A stable, server-owned cache key cannot join another execution's cache namespace.
        fields["prompt_cache_key"] = .string(scope.executionID)
        callIndex = n; invocationID = invocation; self.attempt = a; self.body = fields
    }
}

struct AgentResponsesConnection: Sendable {
    let url: String
    let model: String
    let headers: [String: String]
    let secrets: [String]

    init(provider: String, model: String, credentials: JSONObject) throws {
        guard AgentModelWire.select(style: "codex", provider: provider, credentials: credentials) == "responses" else {
            throw ServerError.badRequest("The selected model does not use the Responses API")
        }
        let official = provider == AgentModelWire.openAI
        let key = credentials[official ? "openai_api_key" : "api_key"]?.string ?? (official ? "" : "dummy")
        let endpoint = credentials[official ? "openai_api_base" : "endpoint_url"]?.string ?? (official ? "https://api.openai.com/v1" : "")
        guard var parts = URLComponents(string: endpoint), ["https", "http"].contains(parts.scheme ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, !key.isEmpty, key.utf8.count <= 4096,
              !key.contains("\r"), !key.contains("\n") else {
            throw ServerError.badRequest("The selected model connection is not configured correctly")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if !parts.path.hasSuffix("/v1") { parts.path += "/v1" }
        parts.path += "/responses"
        guard let url = parts.url?.absoluteString else { throw AgentModelGatewayRequest.invalid() }
        var headers: [String: String] = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        var secrets = [key]
        if let raw = credentials["extra_headers"], raw != .null, raw != "" {
            let object: JSONObject?
            if let text = raw.string { object = (try? JSONValue.parse(Data(text.utf8)))?.object }
            else { object = raw.object }
            guard let object, object.count <= 32 else { throw AgentModelGatewayRequest.invalid() }
            for (name, value) in object {
                let lower = name.lowercased()
                guard !name.isEmpty, name.utf8.count <= 128,
                      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }),
                      let value = value.string, value.utf8.count <= 4096, !value.contains("\r"), !value.contains("\n"),
                      !["host", "content-length", "transfer-encoding", "connection", "cookie", "upgrade", "proxy-authorization"].contains(lower),
                      !lower.hasPrefix("x-agent-") else { throw AgentModelGatewayRequest.invalid() }
                if !["authorization", "content-type", "accept"].contains(lower) { headers[name] = value }
                if !value.isEmpty { secrets.append(value) }
            }
        }
        if official, let org = credentials["openai_organization"]?.string, !org.isEmpty {
            guard !org.contains("\r"), !org.contains("\n") else { throw AgentModelGatewayRequest.invalid() }
            headers["OpenAI-Organization"] = org; secrets.append(org)
        }
        headers["Authorization"] = "Bearer " + key
        self.url = url; self.headers = headers; self.secrets = secrets
        self.model = credentials["endpoint_model_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? model
    }
}

/// Observe usage without re-encoding any byte of the stream. Unknown items and
/// encrypted reasoning are only held in the bounded current frame, never logged.
struct AgentResponsesSSE: Sendable {
    var buffer = [UInt8]()
    var usage: LLMUsage?
    var terminal = false
    var failed = false
    mutating func consume(_ bytes: [UInt8]) throws {
        buffer.append(contentsOf: bytes.filter { $0 != 13 })
        guard buffer.count <= 2 << 20 else { throw AgentModelGatewayRequest.invalid() }
        while let end = buffer.indices.dropLast().first(where: { buffer[$0] == 10 && buffer[$0 + 1] == 10 }) {
            let frame = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeFirst(end + 2)
            let data = frame.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).drop(while: { $0 == " " }) }.joined(separator: "\n")
            guard let value = try? JSONValue.parse(Data(data.utf8)) else { continue }
            if let raw = value["response"]?["usage"], raw.object != nil { usage = LLMUsage(json: raw) }
            if ["response.completed", "response.incomplete", "response.failed", "error"].contains(value["type"]?.string ?? "") {
                terminal = true
                failed = value["type"] != "response.completed"
            }
        }
    }
}

/// Only a suffix that might still be a credential is delayed between chunks.
/// Normal SSE is returned byte-for-byte; a reflected credential aborts the stream.
struct AgentResponsesSecretGuard: Sendable {
    let secrets: [Data]
    var pending = Data()
    init(_ secrets: [String]) { self.secrets = secrets.filter { !$0.isEmpty }.map { Data($0.utf8) } }
    mutating func consume(_ bytes: [UInt8], final: Bool = false) throws -> Data {
        pending.append(contentsOf: bytes)
        guard !secrets.contains(where: { pending.range(of: $0) != nil }) else { throw AgentModelGatewayRequest.invalid() }
        var retain = 0
        if !final {
            for secret in secrets where secret.count > 1 {
                let maximum = min(secret.count - 1, pending.count)
                if maximum > 0 {
                    for count in stride(from: maximum, through: 1, by: -1) where count > retain {
                        if pending.suffix(count).elementsEqual(secret.prefix(count)) { retain = count; break }
                    }
                }
            }
        }
        let ready = Data(pending.prefix(pending.count - retain))
        pending = Data(pending.suffix(retain))
        return ready
    }
}

private actor AgentResponsesObserver {
    var state = AgentResponsesSSE()
    func consume(_ bytes: [UInt8]) throws { try state.consume(bytes) }
    func snapshot() -> AgentResponsesSSE { state }
}

private struct AgentResponsesHead: Sendable { let status: Int; let retryAfter: String? }

extension Routes {
    func invokeAgentResponses(_ req: Request) async throws -> Response {
        let token = try authenticateAgentService(req)
        let scope = try await agentModelScopes.activeScope(token: token)
        if scope.durableOwner != nil { try await requireDurableAgentScope(scope) }
        guard let run = try await store.workflowRun(doc: scope.appID, id: scope.workflowRunID),
              run.status == "running", run.type == "workflow" else {
            throw ServerError.forbidden(code: "agent_run_inactive", message: "The workflow run is not active")
        }
        _ = try await liveApp(scope.appID, viewer: scope.userID)
        let bytes = try await req.body.collect(max: .specified(ByteCount(value: AgentModelGatewayLimits.requestBytes))) ?? Data()
        guard let payload = try? JSONValue.parse(bytes) else { throw AgentModelGatewayRequest.invalid() }
        var request = try AgentResponsesRequest(body: payload, index: req.headers[HTTPField.Name("X-Agent-Call-Index")!],
            invocation: req.headers[HTTPField.Name("X-Agent-Invocation-ID")!], attempt: req.headers[HTTPField.Name("X-Agent-Attempt")!], scope: scope)
        request.body["input"] = try await normalizeAgentResponsesFiles(request.body["input"]!, scope: scope)
        let credentials = try await agentCredentials(provider: scope.provider, model: scope.model, reference: scope.credentialReference)
        let connection = try AgentResponsesConnection(provider: scope.provider, model: scope.model, credentials: credentials)
        request.body["model"] = .string(connection.model)
        let encoded = JSONValue.object(request.body).compactJSON()
        guard encoded.utf8.count <= AgentModelGatewayLimits.requestBytes else { throw ServerError.payloadTooLarge }
        let claim = try await agentModelScopes.claim(token: token, caller: scope.caller.merging(["invocation_id": .string(request.invocationID)]),
            provider: scope.provider, model: scope.model, parameters: scope.modelParameters ?? [:],
            stop: scope.modelParameters?["stop"]?.array?.compactMap(\.string) ?? [], index: request.callIndex, attempt: request.attempt)
        let (heads, head) = AsyncThrowingStream<AgentResponsesHead, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (frames, output) = AsyncThrowingStream<ByteBuffer, any Error>.makeStream(bufferingPolicy: .unbounded)
        let scopes = agentModelScopes
        let task = Task<Void, Never> {
            // Explicitly disable redirects: a provider response cannot redirect a
            // credential to a different destination. The event-loop group is shared.
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init(redirectConfiguration: .disallow))
            let observer = AgentResponsesObserver()
            do {
                try await agentResponsesBeforeDeadline(scope.expiresAt) {
                    var upstream = HTTPClientRequest(url: connection.url)
                    upstream.method = .POST
                    for (name, value) in connection.headers { upstream.headers.add(name: name, value: value) }
                    upstream.body = .bytes(ByteBuffer(string: encoded))
                    let response = try await client.execute(upstream, timeout: .seconds(max(1, Int64(scope.expiresAt.timeIntervalSinceNow))))
                    let status = Int(response.status.code)
                    let retry = response.headers.first(name: "Retry-After").flatMap { value -> String? in
                        guard let seconds = Int(value), (0...300).contains(seconds) else { return nil }; return String(seconds)
                    }
                    if status != 200 {
                        // Errors may quote credentials, URLs or input. Preserve the
                        // status/retry classification, expose only a bounded code.
                        let raw = try await response.body.collect(upTo: 1 << 20)
                        let value = try? JSONValue.parse(Array(raw.readableBytesView))
                        let code = value?["error"]?["code"]?.string ?? value?["error"]?["type"]?.string ?? "upstream_error"
                        let safeCodes: Set<String> = ["server_is_overloaded", "rate_limit_exceeded", "insufficient_quota", "quota_exceeded", "invalid_api_key", "invalid_request_error", "context_length_exceeded"]
                        let safe: JSONValue = ["error": ["code": .string(safeCodes.contains(code) ? code : "upstream_error"),
                            "message": "The model provider rejected this request"]]
                        await scopes.finish(claim, usage: nil, succeeded: !(status == 429 || status >= 500))
                        head.yield(.init(status: status, retryAfter: retry)); head.finish()
                        output.yield(ByteBuffer(string: safe.compactJSON())); output.finish()
                        return
                    }
                    guard response.headers.first(name: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw AgentModelGatewayRequest.invalid()
                    }
                    head.yield(.init(status: status, retryAfter: retry)); head.finish()
                    var total = 0, guarder = AgentResponsesSecretGuard(connection.secrets)
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        total += chunk.readableBytes
                        guard total <= 8 << 20 else { throw AgentModelGatewayRequest.invalid() }
                        let bytes = Array(chunk.readableBytesView)
                        try await observer.consume(bytes)
                        let safe = try guarder.consume(bytes)
                        if !safe.isEmpty { output.yield(ByteBuffer(bytes: safe)) }
                    }
                    let tail = try guarder.consume([], final: true)
                    if !tail.isEmpty { output.yield(ByteBuffer(bytes: tail)) }
                    let observed = await observer.snapshot()
                    await scopes.finish(claim, usage: observed.usage, succeeded: observed.terminal && !observed.failed)
                    output.finish()
                }
            } catch {
                let observed = await observer.snapshot()
                await scopes.finish(claim, usage: observed.usage, succeeded: false)
                // Never reflect transport error descriptions: they can include a URL.
                let safe = ServerError.http(status: 502, code: "agent_model_transport", message: "The model response stream was interrupted")
                head.finish(throwing: safe); output.finish(throwing: safe)
            }
            try? await client.shutdown()
        }
        output.onTermination = { if case .cancelled = $0 { task.cancel() } }
        await scopes.attach(task, to: claim)
        var iterator = heads.makeAsyncIterator()
        let received = try await withTaskCancellationHandler {
            try await iterator.next()
        } onCancel: { task.cancel() }
        guard let response = received else { task.cancel(); throw CancellationError() }
        var headers = Self.eventHeaders
        if response.status != 200 { headers[.contentType] = "application/json" }
        if let retry = response.retryAfter { headers[HTTPField.Name("Retry-After")!] = retry }
        if let effort = request.body["reasoning"]?["effort"]?.string {
            headers[HTTPField.Name("X-Dify-SF-Forwarded-Reasoning")!] = effort
        }
        return Response(status: .init(code: response.status), headers: headers, body: try .init(stream: { writer in
            do { for try await frame in frames { try await writer.write(frame.readableBytesView) } }
            catch { task.cancel(); throw error }
        }, count: nil))
    }

    func normalizeAgentResponsesFiles(_ input: JSONValue, scope: AgentModelScope) async throws -> JSONValue {
        var bytes = 0, nodes = 0
        func walk(_ value: JSONValue, depth: Int) async throws -> JSONValue {
            nodes += 1
            guard depth <= 40, nodes <= 100_000 else { throw AgentModelGatewayRequest.invalid() }
            if let values = value.array {
                var result = [JSONValue]()
                for value in values { result.append(try await walk(value, depth: depth + 1)) }
                return .array(result)
            }
            guard var fields = value.object else { return value }
            if ["input_image", "input_file"].contains(fields["type"]?.string ?? "") {
                let image = fields["type"] == "input_image"
                guard fields["file_data"] == nil, fields["file_url"] == nil,
                      image ? fields["file_id"] == nil : fields["image_url"] == nil,
                      let reference = fields[image ? "image_url" : "file_id"]?.string,
                      reference.hasPrefix("dify-sf-file:") else { throw AgentModelFileError() }
                let id = String(reference.dropFirst("dify-sf-file:".count))
                guard UUID(uuidString: id)?.uuidString.lowercased() == id, scope.inputFileIDs.contains(id) else { throw AgentModelFileError() }
                let files = ServerWorkflowFiles(routes: self, userId: scope.userID, endUserId: scope.endUserID)
                let mapping: JSONValue = ["transfer_method": "local_file", "upload_file_id": .string(id)]
                do {
                    let file = try await files.resolve(mapping, config: nil)
                    bytes += file.size
                    guard bytes <= AgentModelGatewayLimits.fileBytes else { throw ServerError.payloadTooLarge }
                    guard !image || file.mimeType.hasPrefix("image/") else { throw AgentModelFileError() }
                    let content = try await files.bytes(mapping)
                    guard content.count == file.size else { throw AgentModelFileError() }
                    let data = "data:\(file.mimeType);base64," + Data(content).base64EncodedString()
                    if image { fields["image_url"] = .string(data) }
                    else { fields["file_id"] = nil; fields["file_data"] = .string(data); fields["filename"] = .string(file.filename) }
                    return .object(fields)
                } catch is RuntimeFileError { throw AgentModelFileError() }
            }
            // Opaque reasoning payloads and arbitrary future item fields stay intact.
            if fields["type"] == "reasoning" { return value }
            for key in fields.keys { fields[key] = try await walk(fields[key]!, depth: depth + 1) }
            return .object(fields)
        }
        return try await walk(input, depth: 0)
    }
}

private func agentResponsesBeforeDeadline(_ deadline: Date, operation: @escaping @Sendable () async throws -> Void) async throws {
    // AHC's execute deadline covers only response headers, not an idle SSE body.
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
