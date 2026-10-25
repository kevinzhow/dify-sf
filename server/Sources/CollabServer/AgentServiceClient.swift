// Transport for dify-sf-agent/1. Retry identities belong to the Swift execution, never an HTTP connection.
import AsyncHTTPClient
import CollabRuntime
import Foundation
import NIOCore
import NIOHTTP1

struct AgentServiceClient: Sendable {
    static let protocolName = "dify-sf-agent/1"
    let config: AgentServiceConfig
    var client: HTTPClient = .shared

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

    func request(_ method: HTTPMethod, path: String, body: JSONObject? = nil, runToken: String? = nil) async throws -> (Int, JSONValue) {
        var request = HTTPClientRequest(url: try endpoint(path))
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

    /// Reposting after an uncertain response uses the exact same payload and capability. It never starts a new loop.
    func start(_ operation: JSONObject, token: String) async throws -> String {
        var lastError: (any Error)?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (status, result) = try await request(.POST, path: "/v1/operations", body: operation, runToken: token)
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

    /// Reconnection queries durable state. It never re-issues the agent operation or depends on a browser stream.
    func result(run: String, operation: String, deadline: Date,
                isAborted: @Sendable () -> Bool) async throws -> JSONValue {
        let id = try Self.pathID(run)
        var transientFailures = 0
        while Date() < deadline {
            try Task.checkCancellation()
            if isAborted() { throw CancellationError() }
            do {
                let (status, value) = try await request(.GET, path: "/v1/runs/\(id)")
                guard status == 200, value["run_id"] == .string(run), value["operation_id"] == .string(operation),
                      let state = value["status"]?.string else {
                    throw Self.invalidResponse()
                }
                transientFailures = 0
                switch state {
                case "succeeded", "paused", "failed", "cancelled":
                    guard value["result"]?.object != nil, case .int(let event)? = value["last_event_id"], event > 0 else {
                        throw Self.invalidResponse()
                    }
                    return value
                case "running", "accepted", "cancelling": break
                default: throw Self.invalidResponse()
                }
            } catch let error as NodeError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch {
                transientFailures += 1
                guard transientFailures < 4 else {
                    throw NodeError("AgentServiceUnavailable", "The agent operation status is unavailable")
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw NodeError("AgentTimeout", "The agent operation exceeded its deadline")
    }

    func acknowledge(run: String, generation: Int, event: Int) async throws {
        let id = try Self.pathID(run)
        let (status, _) = try await request(.POST, path: "/v1/runs/\(id)/ack",
            body: ["generation": .int(generation), "result_event_id": .int(event)])
        guard status == 200 else { throw Self.invalidResponse() }
    }

    func cancel(run: String, generation: Int) async throws {
        let id = try Self.pathID(run)
        let (status, _) = try await request(.POST, path: "/v1/runs/\(id)/cancel", body: ["generation": .int(generation)])
        guard [200, 202, 409].contains(status) else { throw Self.invalidResponse() }
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
        guard [200, 202, 204].contains(status) else { throw Self.invalidResponse() }
    }
}
