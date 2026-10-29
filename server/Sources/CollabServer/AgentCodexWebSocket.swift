// Native Codex <-> Responses WebSocket. SwiftNIO owns framing/backpressure;
// credentials, file authorization, budgets and usage stay in the API process.
import CollabRuntime
import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import ServiceLifecycle
import Vapor

struct AgentCodexSocketError: Error, Sendable {
    let status: Int
    let code: String
    var json: JSONValue {
        var value: JSONObject = ["type": "error", "status": .int(status), "error": [
            "type": .string(code == "agent_call_limit" ? "usage_limit_reached" : code),
            "code": .string(code), "message": "The incremental model connection cannot continue"]]
        if code == "agent_call_limit" { value["headers"] = ["x-codex-promo-message": "dify-sf-agent-call-limit"] }
        return .object(value)
    }
    static func safe(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        if error is AgentCodexCallLimit { return .init(status: 429, code: "agent_call_limit") }
        if error is AgentModelFileError { return .init(status: 422, code: "file_error") }
        if let error = error as? ServerError {
            switch error {
            case .unauthorized: return .init(status: 401, code: "unauthorized")
            case .forbidden: return .init(status: 403, code: "agent_run_forbidden")
            case .payloadTooLarge: return .init(status: 413, code: "payload_too_large")
            case .http(let status, let code, _): return .init(status: status, code: code)
            default: return .init(status: 400, code: "invalid_request_error")
            }
        }
        return .init(status: 502, code: "agent_model_transport")
    }
}

extension AgentResponsesConnection {
    var isOfficialOpenAI: Bool { url == "https://api.openai.com/v1/responses" }
}

/// The client uses full certificate and hostname verification. No redirects,
/// caller-selected headers, compression, cookies or conversation cache.
enum AgentCodexUpstream {
    enum Upgrade: Sendable {
        case socket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case refused
    }
    static let eventBytes = 16 << 20

    static func connect(_ connection: AgentResponsesConnection) async throws -> NIOAsyncChannel<WebSocketFrame, WebSocketFrame> {
        guard let url = URLComponents(string: connection.url), let host = url.host,
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.query == nil else {
            throw AgentModelGatewayRequest.invalid()
        }
        let secure = url.scheme == "https"
        let tls = secure ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil
        let future: EventLoopFuture<Upgrade> = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15)).connect(host: host, port: url.port ?? (secure ? 443 : 80)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: host)) }
                    let upgrader = NIOTypedWebSocketClientUpgrader<Upgrade>(maxFrameSize: eventBytes,
                        upgradePipelineHandler: { channel, _ in channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                minNonFinalFragmentSize: 1024, maxAccumulatedFrameCount: 2048, maxAccumulatedFrameSize: eventBytes))
                            return .socket(try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel,
                                configuration: .init(backPressureStrategy: .init(lowWatermark: 1, highWatermark: 2))))
                        } })
                    var headers = HTTPHeaders()
                    headers.add(name: "Host", value: host + (url.port.map { ":\($0)" } ?? ""))
                    for (name, value) in connection.headers where !["content-type", "accept", "openai-beta"].contains(name.lowercased()) {
                        headers.add(name: name, value: value)
                    }
                    headers.add(name: "OpenAI-Beta", value: "responses_websockets=2026-02-06")
                    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: url.percentEncodedPath, headers: headers)
                    let negotiated = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(configuration: .init(
                        upgradeConfiguration: .init(upgradeRequestHead: head, upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.close(promise: nil)
                                return channel.eventLoop.makeSucceededFuture(.refused)
                            })))
                    let timer = channel.eventLoop.scheduleTask(in: .seconds(15)) { channel.close(promise: nil) }
                    negotiated.whenComplete { _ in timer.cancel() }
                    return negotiated
                }
            }
        let result = try await withTaskCancellationHandler { try await future.get() } onCancel: {
            future.whenSuccess { if case .socket(let socket) = $0 { socket.channel.close(promise: nil) } }
        }
        switch result {
        case .socket(let socket): return socket
        case .refused: throw AgentCodexSocketError(status: 502, code: "agent_upstream_websocket_required")
        }
    }

    static func text(_ bytes: ByteBuffer) -> WebSocketFrame {
        .init(fin: true, opcode: .text, maskKey: .random(), data: bytes)
    }
}

/// One active response per connection. Only a previous response id and a small
/// parameter digest survive between requests; opaque output items stay on wire.
actor AgentCodexSocketSession {
    let routes: Routes
    let token: String
    let lane: String
    let connection: AgentResponsesConnection
    private var busy = false
    private var warmed = false
    private var completedID: String?
    private var parameters: String?
    private var claim: AgentModelScopes.Claim?
    private var body: JSONObject = [:]
    private var received = 0
    private var sent = 0
    private var usage: LLMUsage?

    init(routes: Routes, token: String, lane: String, connection: AgentResponsesConnection) {
        self.routes = routes; self.token = token; self.lane = lane; self.connection = connection
    }

    func prepare(_ bytes: Data) async throws -> ByteBuffer {
        guard !busy else { throw AgentCodexSocketError(status: 400, code: "response_in_progress") }
        busy = true // Reserve before any suspension; pipelined creates cannot race admission.
        guard bytes.count <= AgentCodexGatewayLimits.requestBytes,
              var fields = (try? JSONValue.parse(bytes))?.object,
              fields["type"] == "response.create" else { throw AgentModelGatewayRequest.invalid() }
        fields["type"] = nil
        let scope = try await routes.agentModelScopes.activeScope(token: token)
        try await routes.requireActiveAgentCodexScope(scope)
        var request = try AgentResponsesRequest(codexBody: .object(fields), scope: scope, incremental: true)
        request.body["input"] = try await routes.normalizeAgentResponsesFiles(request.body["input"]!, scope: scope, allowInline: true)
        let previous = request.body["previous_response_id"]?.string
        var signature = request.body
        for name in ["input", "previous_response_id", "generate", "client_metadata", "stream_options"] { signature[name] = nil }
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: JSONValue.object(signature).compactData()), options: [.sortedKeys])
        let digest = Tokens.sha256(String(decoding: canonical, as: UTF8.self))
        if let previous {
            guard previous == completedID, digest == parameters else {
                throw AgentCodexSocketError(status: 400, code: "agent_incremental_context_lost")
            }
        } else if completedID != nil {
            throw AgentCodexSocketError(status: 400, code: "incremental_required")
        }
        if request.body["generate"] == false {
            guard !warmed, previous == nil else { throw AgentCodexSocketError(status: 400, code: "invalid_warmup") }
            warmed = true
        }
        request.body["model"] = .string(connection.model)
        // Keep audit metadata only. The initial image/history payload must be
        // released after its write, not cached for this socket's lifetime.
        body = JSONObject(request.body.filter { ["reasoning", "include", "max_output_tokens", "previous_response_id", "generate"].contains($0.key) })
        var upstream = request.body; upstream["type"] = "response.create"
        let encoded = JSONValue.object(upstream).compactJSON()
        received = bytes.count; sent = encoded.utf8.count; usage = nil
        guard sent <= AgentCodexGatewayLimits.requestBytes else { throw ServerError.payloadTooLarge }
        try await routes.agentModelScopes.startCodexSocket(token: token, lane: lane)
        parameters = digest
        if body["generate"] != false {
            let accepted = try await routes.agentModelScopes.claimCodex(token: token)
            claim = accepted
            try await routes.recordCodexModelCall(scope: scope, claim: accepted, phase: "started", body: body,
                model: connection.model, usage: nil, status: nil, transport: "websocket", receivedBytes: received, forwardedBytes: sent)
        }
        // Metadata only; no ids, URLs, credentials, input or response contents.
        routes.logger.info("codex websocket request bytes=\(received) forwarded=\(sent) previous=\(previous != nil) warmup=\(body["generate"] == false)")
        return ByteBuffer(string: encoded)
    }

    func observe(_ bytes: Data) async throws -> Data {
        _ = try await routes.agentModelScopes.activeScope(token: token)
        guard bytes.count <= AgentCodexUpstream.eventBytes, let value = try? JSONValue.parse(bytes), let type = value["type"]?.string else {
            throw AgentCodexSocketError(status: 502, code: "agent_model_protocol")
        }
        // Check both encoded and decoded strings before forwarding. Escaping a
        // credential must not defeat the reflection guard.
        var guarder = AgentResponsesSecretGuard(connection.secrets + [token])
        _ = try guarder.consume(Array(bytes), final: true)
        func check(_ item: JSONValue, depth: Int = 0) throws {
            guard depth <= 64 else { throw AgentModelGatewayRequest.invalid() }
            if let text = item.string, (connection.secrets + [token]).contains(where: { !$0.isEmpty && text.contains($0) }) {
                throw AgentModelGatewayRequest.invalid()
            }
            if let array = item.array { for v in array { try check(v, depth: depth + 1) } }
            if let object = item.object { for (k, v) in object { try check(.string(k), depth: depth + 1); try check(v, depth: depth + 1) } }
        }
        try check(value)
        if let raw = value["response"]?["usage"], raw.object != nil { usage = LLMUsage(json: raw) }
        if ["response.completed", "response.incomplete", "response.failed", "error"].contains(type) {
            guard busy else { throw AgentCodexSocketError(status: 502, code: "agent_model_protocol") }
            if type == "response.completed" {
                guard let id = value["response"]?["id"]?.string, !id.isEmpty, id.utf8.count <= 256 else {
                    throw AgentCodexSocketError(status: 502, code: "agent_model_protocol")
                }
                completedID = id
            } else { completedID = nil }
            // Persist usage before forwarding completion: Codex can finish and
            // revoke this capability immediately upon seeing it.
            await finish(succeeded: type == "response.completed", status: type == "error" ? (value["status"]?.int ?? value["status_code"]?.int ?? 502) : 200)
            if type == "error" {
                let raw = value["error"]?["code"]?.string ?? "agent_upstream_error"
                if ["previous_response_not_found", "websocket_connection_limit_reached"].contains(raw) {
                    return Data(AgentCodexSocketError(status: 400, code: "agent_incremental_context_lost").json.compactJSON().utf8)
                }
                // Upstream error messages may contain private request content.
                let code = raw != "agent_call_limit" && raw.utf8.count <= 128 && raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? raw : "agent_upstream_error"
                var safe = AgentCodexSocketError(status: value["status"]?.int ?? value["status_code"]?.int ?? 502, code: code).json.object!
                if let kind = value["error"]?["type"]?.string, ["usage_limit_reached", "insufficient_quota"].contains(kind) {
                    var details = safe["error"]!.object!
                    details["type"] = .string(kind); safe["error"] = .object(details)
                }
                if let retry = (value["error"]?["headers"]?["retry-after"] ?? value["headers"]?["retry-after"])?.string,
                   let seconds = Int(retry), (0...3600).contains(seconds) {
                    safe["headers"] = ["retry-after": .string(String(seconds))]
                }
                return Data(JSONValue.object(safe).compactJSON().utf8)
            }
        }
        return bytes // Opaque output_item.done and encrypted reasoning remain byte-for-byte.
    }

    func finish(succeeded: Bool = false, status: Int = 502) async {
        if let accepted = claim {
            claim = nil
            await routes.agentModelScopes.finish(accepted, usage: usage, succeeded: succeeded)
            try? await routes.recordCodexModelCall(scope: accepted.scope, claim: accepted, phase: "finished", body: body,
                model: connection.model, usage: usage, status: status, transport: "websocket", receivedBytes: received, forwardedBytes: sent)
        } else if body["generate"] == false, let usage {
            // Warmup does not spend a call slot. If a provider reports any
            // usage for it, accounting must still retain that usage.
            await routes.agentModelScopes.observeCodexWarmupUsage(token: token, lane: lane, usage: usage)
        }
        busy = false
    }
}

struct AgentCodexWebSocketService: Service {
    let routes: Routes
    let host: String
    let port: Int
    var onListening: (@Sendable (Int) -> Void)? = nil
    static let path = "/inner/agent/codex/v1/responses"

    private enum Upgraded: Sendable {
        case socket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, Request, String)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }
    private func request(_ head: HTTPRequestHead) -> Request {
        var fields = HTTPFields()
        if let value = head.headers.first(name: "Authorization") { fields[.authorization] = value }
        return Request(method: .get, url: URI(string: head.uri), headers: fields)
    }
    private func authenticate(_ head: HTTPRequestHead) async throws -> Request {
        guard head.method == .GET, head.uri == Self.path else { throw AgentCodexSocketError(status: 403, code: "forbidden") }
        guard head.headers["Authorization"].count == 1 else { throw AgentCodexSocketError(status: 401, code: "unauthorized") }
        let req = request(head)
        let scope = try await routes.agentModelScopes.activeScope(token: routes.authenticateAgentCodex(req))
        try await routes.requireActiveAgentCodexScope(scope)
        return req
    }
    private func lane(_ head: HTTPRequestHead) throws -> String {
        let values = ["session-id", "thread-id"].map { head.headers.first(name: $0) ?? "" }
        guard values.contains(where: { !$0.isEmpty }), values.allSatisfy({ $0.utf8.count <= 256 && $0.allSatisfy { $0.isASCII && !$0.isWhitespace } }) else {
            throw AgentCodexSocketError(status: 400, code: "agent_socket_identity_required")
        }
        return Tokens.sha256(JSONValue.array(values.map(JSONValue.string)).compactJSON())
    }
    func run() async throws {
        let listener = try await bind()
        onListening?(listener.channel.localAddress?.port ?? 0)
        try await withTaskCancellationHandler {
          try await withGracefulShutdownHandler {
            try await withThrowingDiscardingTaskGroup { group in
                try await listener.executeThenClose { inbound in
                    for try await upgraded in inbound { group.addTask { await handle(upgraded) } }
                }
            }
          } onGracefulShutdown: { listener.channel.close(promise: nil) }
        } onCancel: { listener.channel.close(promise: nil) }
    }
    private func bind() async throws -> NIOAsyncChannel<EventLoopFuture<Upgraded>, Never> {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)
            .bind(host: host, port: port) { channel in channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketServerUpgrader<Upgraded>(maxFrameSize: AgentCodexGatewayLimits.requestBytes,
                    shouldUpgrade: { channel, head in
                        let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                        promise.completeWithTask { do { _ = try await authenticate(head); _ = try lane(head); return HTTPHeaders() } catch { return nil } }
                        return promise.futureResult
                    }, upgradePipelineHandler: { channel, head in channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1024, maxAccumulatedFrameCount: 2048, maxAccumulatedFrameSize: AgentCodexGatewayLimits.requestBytes))
                        return .socket(try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel,
                            configuration: .init(backPressureStrategy: .init(lowWatermark: 1, highWatermark: 2))), request(head), try lane(head))
                    } })
                return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(configuration: .init(
                    upgradeConfiguration: .init(upgraders: [upgrader], notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(AgentCodexHTTPResponseEncoder())
                            return .http(try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(wrappingChannelSynchronously: channel))
                        }
                    })))
            } }
    }
    private func handle(_ future: EventLoopFuture<Upgraded>) async {
        do {
            switch try await future.get() {
            case .socket(let channel, let request, let lane):
                let token = try routes.authenticateAgentCodex(request), id = UUID().uuidString
                let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let task = Task<Void, Never> {
                    for await _ in ready { break }
                    do { try Task.checkCancellation(); try await socket(channel, token: token, lane: lane) }
                    catch { /* Wire errors are sanitized inside socket. */ }
                }
                do {
                    try await routes.agentModelScopes.openCodexSocket(token: token, lane: lane, id: id, task: task)
                    signal.yield(()); signal.finish()
                    channel.channel.closeFuture.whenComplete { _ in task.cancel() }
                    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel(); channel.channel.close(promise: nil) }
                    await routes.agentModelScopes.closeCodexSocket(token: token, lane: lane, id: id)
                } catch {
                    task.cancel(); signal.finish()
                    try await channel.executeThenClose { _, output in
                        try await output.write(.init(fin: true, opcode: .text, data: ByteBuffer(string: AgentCodexSocketError.safe(error).json.compactJSON())))
                    }
                }
            case .http(let channel):
                try await channel.executeThenClose { inbound, output in
                    for try await part in inbound {
                        guard case .head(let head) = part else { continue }
                        var status = 400
                        do { _ = try await authenticate(head); _ = try lane(head) } catch { status = AgentCodexSocketError.safe(error).status }
                        try await output.write(contentsOf: [.head(.init(version: .http1_1, status: .init(statusCode: status), headers: ["Connection": "close", "Content-Length": "0"])), .end(nil)])
                        return
                    }
                }
            }
        } catch { /* No transport descriptions: these may contain credentials/URLs. */ }
    }
    private func socket(_ downstream: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, token: String, lane: String) async throws {
        try await downstream.executeThenClose { input, output in
            do {
                let scope = try await routes.agentModelScopes.activeScope(token: token)
                try await routes.requireActiveAgentCodexScope(scope)
                let credentials = try await routes.agentCredentials(provider: scope.provider, model: scope.model, reference: scope.credentialReference)
                let connection = try AgentResponsesConnection(provider: scope.provider, model: scope.model, credentials: credentials)
                let session = AgentCodexSocketSession(routes: routes, token: token, lane: lane, connection: connection)
                do {
                    let upstream = try await AgentCodexUpstream.connect(connection)
                    try await withTaskCancellationHandler {
                        try await upstream.executeThenClose { events, requests in
                            try await withThrowingTaskGroup(of: Void.self) { group in
                                group.addTask {
                                    for try await frame in input {
                                        switch frame.opcode {
                                        case .ping: try await output.write(.init(fin: true, opcode: .pong, data: frame.unmaskedData))
                                        case .pong: continue
                                        case .text:
                                            let body = try await session.prepare(Data(frame.unmaskedData.readableBytesView))
                                            try await requests.write(AgentCodexUpstream.text(body))
                                        case .connectionClose: return
                                        default: throw AgentCodexSocketError(status: 400, code: "invalid_websocket_frame")
                                        }
                                    }
                                }
                                group.addTask {
                                    for try await frame in events {
                                        switch frame.opcode {
                                        case .ping: try await requests.write(.init(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData))
                                        case .pong: continue
                                        case .text:
                                            let bytes = try await session.observe(Data(frame.unmaskedData.readableBytesView))
                                            try await output.write(.init(fin: true, opcode: .text, data: ByteBuffer(bytes: bytes)))
                                        default: throw AgentCodexSocketError(status: 400, code: "agent_incremental_context_lost")
                                        }
                                    }
                                    throw AgentCodexSocketError(status: 400, code: "agent_incremental_context_lost")
                                }
                                group.addTask {
                                    while true {
                                        let active = try await routes.agentModelScopes.activeScope(token: token)
                                        try await Task.sleep(for: .seconds(min(15, max(0, active.expiresAt.timeIntervalSinceNow))))
                                        let current = try await routes.agentModelScopes.activeScope(token: token)
                                        try await routes.requireActiveAgentCodexScope(current)
                                        // Unknown JSON events are ignored by pinned Codex and reset
                                        // its 300s message timer; WS ping alone does not reset it.
                                        try await output.write(.init(fin: true, opcode: .text, data: ByteBuffer(string: "{\"type\":\"dify.gateway.keepalive\"}")))
                                    }
                                }
                                defer { group.cancelAll(); upstream.channel.close(promise: nil) }
                                _ = try await group.next()
                            }
                        }
                    } onCancel: { upstream.channel.close(promise: nil); downstream.channel.close(promise: nil) }
                } catch {
                    await session.finish()
                    throw error
                }
            } catch {
                try? await output.write(.init(fin: true, opcode: .text, data: ByteBuffer(string: AgentCodexSocketError.safe(error).json.compactJSON())))
            }
        }
    }
}

/// The NIO async channel writes ByteBuffer bodies; HTTP/1's encoder accepts IOData.
private final class AgentCodexHTTPResponseEncoder: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part: OutboundOut
        switch unwrapOutboundIn(data) {
        case .head(let head): part = .head(head)
        case .body(let body): part = .body(.byteBuffer(body))
        case .end(let trailers): part = .end(trailers)
        }
        context.write(wrapOutboundOut(part), promise: promise)
    }
}
