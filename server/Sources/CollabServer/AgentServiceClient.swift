// Transport for dify-sf-agent/1. Retry identities belong to the Swift execution, never an HTTP connection.
import AsyncHTTPClient
import CollabRuntime
import Foundation
import NIOCore
import NIOHTTP1
import Logging

struct AgentServiceClient: Sendable {
    static let protocolName = "dify-sf-agent/1"
    let config: AgentServiceConfig
    var client: HTTPClient = .shared
    var logger: Logger? = nil

    private func endpoint(_ path: String) throws -> String {
        guard var url = URLComponents(string: config.url), ["http", "https"].contains(url.scheme ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw NodeError("AgentServiceUnavailable", "The agent service URL is not configured correctly")
        }
        url.path = path
        guard let result = url.url?.absoluteString else { throw Self.invalidResponse() }
        return result
    }

    private static func pathID(_ value: String) throws -> String {
        // IDs enter paths, not URL templates; the service's persisted run IDs are UUIDs.
        guard !value.isEmpty, value.utf8.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw invalidResponse()
        }
        return value
    }

    private static func invalidResponse() -> NodeError {
        NodeError("AgentServiceProtocolError", "The agent service returned an invalid response")
    }

    func request(_ method: HTTPMethod, path: String, body: JSONObject? = nil, runToken: String? = nil, query: [String: String] = [:]) async throws -> (Int, JSONValue) {
        var destination = URLComponents(string: try endpoint(path))!
        if !query.isEmpty { destination.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = HTTPClientRequest(url: destination.url!.absoluteString)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer " + config.key)
        if let runToken { request.headers.add(name: "X-Agent-Run-Token", value: runToken) }
        if var body {
            body["protocol"] = .string(Self.protocolName)
            let bytes = JSONValue.object(body).compactJSON()
            guard bytes.utf8.count <= 8 << 20 else { throw NodeError("AgentRequestTooLarge", "The agent request is too large") }
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(string: bytes))
        }
        let response = try await client.execute(request, timeout: .seconds(30))
        let bytes = try await response.body.collect(upTo: 8 << 20)
        let value = try JSONValue.parse(Array(bytes.readableBytesView))
        guard value["protocol"] == .string(Self.protocolName) else { throw Self.invalidResponse() }
        return (Int(response.status.code), value)
    }

    /// Opt-in is necessary even when the sandbox supervisor is present. A failed probe grants no shell.
    func shellAvailable() async -> Bool {
        guard config.shellEnabled else { return false }
        guard let (status, value) = try? await request(.GET, path: "/v1/health") else { return false }
        return status == 200 && value["sandbox"] == "isolated"
    }

    /// Reposting after an uncertain response uses the exact same payload and capability. It never starts a new loop.
    func start(_ operation: JSONObject, token: String) async throws -> String {
        var lastError: (any Error)?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (status, result) = try await request(.POST, path: "/v1/operations", body: operation, runToken: token)
                if status == 503 {
                    if attempt < 2 { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))); continue }
                    throw NodeError("AgentServiceUnavailable", "The agent service is temporarily unavailable")
                }
                guard [200, 202].contains(status), let run = result["run_id"]?.string else {
                    // A concrete rejection is not retried, including a generation/digest conflict.
                    throw NodeError("AgentOperationRejected", "The agent service rejected this operation (HTTP \(status))")
                }
                return try Self.pathID(run)
            } catch let error as NodeError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                if attempt < 2 { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
            }
        }
        _ = lastError // Never disclose an upstream response, URL or authentication header in node records.
        throw NodeError("AgentServiceUnavailable", "The agent operation could not be confirmed")
    }

    /// Durable SSE replay is independent from the browser. Reconnect with the last committed cursor, never restart a loop.
    func result(run: String, operation: String, deadline: Date,
                isAborted: @Sendable () -> Bool,
                onEvent: @Sendable (Int, String, JSONObject) async throws -> Void = { _, _, _ in }) async throws -> JSONValue {
        let id = try Self.pathID(run)
        var cursor = 0, failures = 0
        while Date() < deadline {
            try Task.checkCancellation()
            if isAborted() { throw CancellationError() }
            do {
                var req = HTTPClientRequest(url: try endpoint("/v1/runs/\(id)/events") + "?after=\(cursor)")
                req.headers.add(name: "Authorization", value: "Bearer " + config.key)
                req.headers.add(name: "Accept", value: "text/event-stream")
                let response = try await client.execute(req, timeout: .seconds(max(1, Int64(deadline.timeIntervalSinceNow))))
                guard response.status.code != 410 else { throw NodeError("AgentEventHistoryLost", "Agent event history is no longer available") }
                guard response.status.code == 200 else {
                    if response.status.code == 503 { throw AgentTransientTransport() }
                    throw Self.invalidResponse()
                }
                var buffer = [UInt8]()
                for try await bytes in response.body {
                    try Task.checkCancellation()
                    if isAborted() { throw CancellationError() }
                    guard Date() < deadline else { throw NodeError("AgentTimeout", "The agent operation exceeded its deadline") }
                    buffer.append(contentsOf: bytes.readableBytesView.filter { $0 != 13 })
                    guard buffer.count <= 2 << 20 else { throw Self.invalidResponse() }
                    while let end = buffer.indices.dropLast().first(where: { buffer[$0] == 10 && buffer[$0 + 1] == 10 }) {
                        let frame = String(decoding: buffer[..<end], as: UTF8.self)
                        buffer.removeFirst(end + 2)
                        guard let event = try Self.parseEvent(frame) else { continue }
                        if event.id <= cursor { continue }
                        guard event.id == cursor + 1 else { throw Self.invalidResponse() }
                        try await onEvent(event.id, event.name, event.data)
                        cursor = event.id // Advance only after the database commit succeeded.
                        failures = 0
                    }
                }
                let (status, value) = try await request(.GET, path: "/v1/runs/\(id)")
                guard status == 200, value["run_id"] == .string(run), value["operation_id"] == .string(operation),
                      let state = value["status"]?.string else { throw Self.invalidResponse() }
                if ["succeeded", "paused", "failed", "cancelled"].contains(state) {
                    guard value["result"]?.object != nil, case .int(let last)? = value["last_event_id"], last > 0, cursor == last else {
                        throw Self.invalidResponse()
                    }
                    return value
                }
                guard ["running", "accepted", "cancelling"].contains(state) else { throw Self.invalidResponse() }
            } catch let error as NodeError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch {
                failures += 1
                guard failures < 4 else { throw NodeError("AgentServiceUnavailable", "The agent event stream is unavailable") }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NodeError("AgentTimeout", "The agent operation exceeded its deadline")
    }

    static func parseEvent(_ frame: String) throws -> (id: Int, name: String, data: JSONObject)? {
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.allSatisfy({ $0.isEmpty || $0.hasPrefix(":") }) { return nil }
        guard let raw = lines.first(where: { $0.hasPrefix("id: ") }), let id = Int(raw.dropFirst(4)), id > 0,
              let name = lines.first(where: { $0.hasPrefix("event: ") }).map({ String($0.dropFirst(7)) }), !name.isEmpty,
              let payload = lines.first(where: { $0.hasPrefix("data: ") }),
              let data = try JSONValue.parse(Data(payload.dropFirst(6).utf8)).object else { throw invalidResponse() }
        return (id, name, data)
    }

    func activeRuns() async throws -> [JSONValue] {
        let (status, value) = try await request(.GET, path: "/v1/runs", query: ["state": "active"])
        guard status == 200, let runs = value["runs"]?.array, runs.count <= 10_000 else { throw Self.invalidResponse() }
        return runs
    }

    func acknowledge(run: String, generation: Int, event: Int) async throws {
        let id = try Self.pathID(run)
        let (status, _) = try await request(.POST, path: "/v1/runs/\(id)/ack",
            body: ["generation": .int(generation), "result_event_id": .int(event)])
        guard [200, 404, 409, 410].contains(status) else { throw Self.invalidResponse() }
        if status != 200 { logger?.warning("agent acknowledgement already removed or superseded; outbox entry resolved") }
    }

    func cancel(run: String, generation: Int) async throws {
        let id = try Self.pathID(run)
        let (status, _) = try await request(.POST, path: "/v1/runs/\(id)/cancel", body: ["generation": .int(generation)])
        guard [200, 202, 404, 409, 410].contains(status) else { throw Self.invalidResponse() }
    }

    func lease(execution: String, generation: Int) async throws {
        let id = try Self.pathID(execution)
        let (status, _) = try await request(.POST, path: "/v1/executions/\(id)/lease",
            body: ["generation": .int(generation), "ttl_seconds": 120])
        guard status == 200 else { throw Self.invalidResponse() }
    }

    func cleanup(execution: String, generation: Int) async throws {
        let id = try Self.pathID(execution)
        let (status, _) = try await request(.DELETE, path: "/v1/executions/\(id)", body: ["generation": .int(generation)])
        guard [200, 202, 204, 404, 409, 410].contains(status) else { throw Self.invalidResponse() }
    }
}

private struct AgentTransientTransport: Error {}
