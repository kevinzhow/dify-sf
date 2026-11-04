import Foundation
import NIOHTTP1
import Logging
import NIOCore
import Synchronization

/// Transport observations only. Never log frame contents, close reasons, URLs,
/// capabilities or error descriptions. Sequence numbers distinguish the first
/// observed termination from cancellation and channel closure during cleanup;
/// they do not establish which remote system caused the failure.
final class AgentCodexSocketDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case admission, upstreamConnect = "upstream_connect"
        case downstreamRead = "downstream_read", upstreamRead = "upstream_read"
        case requestPrepare = "request_prepare", responseObserve = "response_observe"
        case upstreamWrite = "upstream_write", downstreamWrite = "downstream_write"
        case scopeCheck = "scope_check", lifecycle
        case upstreamChannel = "upstream_channel", downstreamChannel = "downstream_channel"
    }
    enum End: String, Sendable { case eof, closeFrame = "close_frame", unexpectedFrame = "unexpected_frame", error, cancelled, channelClosed = "channel_closed" }

    let socketID: String
    let logger: Logger
    let clientRequestID = UUID().uuidString
    private let base: Logger.Metadata
    private let handshakeFields = Mutex<Logger.Metadata>([:])
    private let started = ContinuousClock.now
    var metadata: Logger.Metadata { base.merging(handshakeFields.withLock { $0 }) { _, new in new } }
    private let sequence = Mutex(0)

    init(logger: Logger, socketID: String, requestID: String?) {
        self.logger = logger; self.socketID = socketID
        var fields: Logger.Metadata = ["socket_id": "\(socketID)"]
        if let id = HTTPFailureDiagnostics.validatedRequestID(requestID) { fields["request_id"] = "\(id)" }
        base = fields
    }

    /// Allowlist only correlation IDs; never dump response headers or close reason text.
    static func requestID(_ value: String?, secrets: [String] = []) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              !secrets.contains(where: { !$0.isEmpty && value.contains($0) }) else { return nil }
        return value
    }

    func connecting(url: URLComponents, channel: Channel) {
        var fields: Logger.Metadata = ["upstream_client_request_id": "\(clientRequestID)",
            "endpoint_scheme": "\(url.scheme ?? "unknown")", "endpoint_port": "\(url.port ?? (url.scheme == "https" ? 443 : 80))"]
        // Host/IP and ports only: never path, query, userinfo or full endpoint URL.
        if let host = Self.requestID(url.host) { fields["endpoint_host"] = "\(host)" }
        handshakeFields.withLock { $0.merge(fields) { _, new in new } }
        logger.info("codex websocket upstream connecting", metadata: metadata)
    }

    /// ClientBootstrap runs pipeline setup before TCP connect; addresses are only
    /// authoritative once the channel is active (or an HTTP response arrives).
    func peer(channel: Channel) {
        guard let ip = channel.remoteAddress?.ipAddress, let port = channel.remoteAddress?.port else { return }
        let first = handshakeFields.withLock { fields in
            guard fields["upstream_peer_ip"] == nil else { return false }
            fields["upstream_peer_ip"] = "\(ip)"; fields["upstream_peer_port"] = "\(port)"
            if let local = channel.localAddress?.port { fields["upstream_local_port"] = "\(local)" }
            return true
        }
        if first { logger.info("codex websocket upstream peer", metadata: metadata) }
    }

    func handshake(_ head: HTTPResponseHead, secrets: [String]) {
        var fields: Logger.Metadata = ["upstream_handshake_status": "\(head.status.code)",
            "upstream_client_request_id": "\(clientRequestID)"]
        for (header, name) in [("x-request-id", "upstream_request_id"), ("cf-ray", "upstream_edge_request_id")] {
            let values = head.headers[header]
            if values.count == 1, let id = Self.requestID(values.first, secrets: secrets) { fields[name] = "\(id)" }
        }
        handshakeFields.withLock { $0.merge(fields) { _, new in new } }
        logger.info("codex websocket upstream handshake", metadata: metadata)
    }

    func recovery(attempt: Int, delayMilliseconds: Int) {
        logger.info("codex websocket recovery backoff", metadata: metadata.merging([
            "recovery_attempt": "\(attempt)", "backoff_ms": "\(delayMilliseconds)"] ) { _, new in new })
    }

    func rotation(count: Int) {
        logger.info("codex websocket connection rotation", metadata: metadata.merging([
            "reconnect_reason": "connection_expired", "rotation_count": "\(count)"] ) { _, new in new })
    }

    func ended(_ stage: Stage, _ end: End, error: (any Error)? = nil, closeCode: UInt16? = nil) {
        let ordinal = sequence.withLock { value in value += 1; return value }
        var fields = metadata
        let elapsed = started.duration(to: .now).components
        fields["elapsed_ms"] = "\(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)"
        fields["stage"] = "\(stage.rawValue)"
        fields["end"] = "\(end.rawValue)"
        fields["terminal_sequence"] = "\(ordinal)"
        fields["first_observed"] = "\(ordinal == 1)"
        if let closeCode { fields["close_code"] = "\(closeCode)" }
        if let error {
            fields["error_type"] = "\(String(reflecting: type(of: error)))"
            if let io = error as? IOError { fields["system_errno"] = "\(io.errnoCode)" }
            let safe = AgentCodexSocketError.safe(error)
            let classified = HTTPFailureDiagnostics.metadata(requestID: nil, status: safe.status,
                code: safe.code, failureCase: "websocket")
            fields["status"] = classified["status"]
            fields["error_code"] = classified["error_code"]
        }
        logger.warning("codex websocket terminal", metadata: fields)
    }
}
