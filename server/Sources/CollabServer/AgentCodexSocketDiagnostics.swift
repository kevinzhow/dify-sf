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

    let logger: Logger
    let metadata: Logger.Metadata
    private let sequence = Mutex(0)

    init(logger: Logger, socketID: String, requestID: String?) {
        self.logger = logger
        var fields: Logger.Metadata = ["socket_id": "\(socketID)"]
        if let id = HTTPFailureDiagnostics.validatedRequestID(requestID) { fields["request_id"] = "\(id)" }
        metadata = fields
    }

    func ended(_ stage: Stage, _ end: End, error: (any Error)? = nil, closeCode: UInt16? = nil) {
        let ordinal = sequence.withLock { value in value += 1; return value }
        var fields = metadata
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
