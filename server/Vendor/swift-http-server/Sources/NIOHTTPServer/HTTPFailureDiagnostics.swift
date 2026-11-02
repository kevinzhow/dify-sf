// Local dify-sf diagnostics; see PATCHES.md. Request contents are never retained.
import Logging
import NIOCore
import NIOHTTP1

/// Shared only by handlers on one channel's event loop. Counts socket reads, not
/// an exact request length: a read can contain several pipelined requests.
final class HTTPFailureDiagnosticsState: @unchecked Sendable {
    var connectionBytes = 0
    var bodyBytes = 0
    var readingBody = false
    var requestID: String?
    var contentLength = "absent"
    var transferEncoding = "absent"

    static func requestID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 32,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value
    }

    func head(_ head: HTTPRequestHead) {
        self.bodyBytes = 0
        self.readingBody = true
        self.requestID = Self.requestID(head.headers.first(name: "x-request-id"))
        if let length = head.headers.first(name: "content-length") {
            self.contentLength = length.utf8.count <= 20 && !length.isEmpty
                && length.utf8.allSatisfy({ (48...57).contains($0) }) && UInt64(length) != nil ? length : "invalid"
        } else {
            self.contentLength = "absent"
        }
        let encodings = head.headers["transfer-encoding"]
        // Do not log arbitrary header values, even in a framing header.
        self.transferEncoding = encodings.isEmpty ? "absent"
            : encodings.count == 1 && encodings[0].lowercased() == "chunked" ? "chunked" : "other"
    }

    func metadata(includeHead: Bool) -> Logger.Metadata {
        var fields: Logger.Metadata = ["connection_bytes_received": "\(self.connectionBytes)"]
        if includeHead {
            fields["body_bytes_received"] = "\(self.bodyBytes)"
            fields["content_length"] = "\(self.contentLength)"
            fields["transfer_encoding"] = "\(self.transferEncoding)"
            if let requestID { fields["request_id"] = "\(requestID)" }
        }
        return fields
    }
}

/// Installed before HTTP decoding, after TLS when present. Retains a counter only.
final class HTTPIncomingByteCounter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: HTTPFailureDiagnosticsState
    init(state: HTTPFailureDiagnosticsState) { self.state = state }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let count = self.unwrapInboundIn(data).readableBytes
        self.state.connectionBytes += min(count, Int.max - self.state.connectionBytes)
        context.fireChannelRead(data)
    }
}

/// The standard NIO protocol error handler still sends its original response and
/// forwards the error here. No changes to parsing, buffering, or response bodies.
final class HTTPFailureDiagnosticsHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    let state: HTTPFailureDiagnosticsState
    let logger: Logger

    init(state: HTTPFailureDiagnosticsState, logger: Logger) {
        self.state = state
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head): self.state.head(head)
        case .body(let bytes):
            self.state.bodyBytes += min(bytes.readableBytes, Int.max - self.state.bodyBytes)
        case .end: self.state.readingBody = false
        }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let parser = error as? HTTPParserError {
            // HTTPParserError has fixed enum cases and fixed descriptions, with
            // no associated request data. Other errors are not reflected here.
            var fields = self.state.metadata(includeHead: self.state.readingBody)
            fields["error_type"] = "HTTPParserError"
            fields["parser_error"] = "\(parser.debugDescription)"
            fields["request_head_available"] = "\(self.state.readingBody)"
            self.logger.warning("HTTP/1.1 request parsing failed", metadata: fields)
        }
        context.fireErrorCaught(error)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .head(let head) = self.unwrapOutboundIn(data), (400..<500).contains(head.status.code) {
            var fields = self.state.metadata(includeHead: true)
            fields["status"] = "\(head.status.code)"
            self.logger.warning("HTTP request rejected", metadata: fields)
        }
        context.write(data, promise: promise)
    }
}

@available(*, unavailable)
extension HTTPIncomingByteCounter: Sendable {}
@available(*, unavailable)
extension HTTPFailureDiagnosticsHandler: Sendable {}
