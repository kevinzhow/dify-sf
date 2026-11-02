import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Synchronization
import Testing
@testable import CollabServer
@testable import NIOHTTPServer
#if os(Linux)
import Glibc
#endif

private final class FailureLog: Sendable {
    struct Entry: Sendable {
        let message: String
        let fields: [String: String]
    }
    let entries = Mutex<[Entry]>([])
    var snapshot: [Entry] { entries.withLock { $0 } }
    var logger: Logger { Logger(label: "http-failure-test") { _ in Handler(log: self) } }

    private struct Handler: LogHandler {
        let log: FailureLog
        var metadata: Logger.Metadata = [:]
        var logLevel = Logger.Level.info
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String,
                 file: String, function: String, line: UInt) {
            let fields = self.metadata.merging(metadata ?? [:]) { _, new in new }.mapValues { String(describing: $0) }
            log.entries.withLock { $0.append(.init(message: String(describing: message), fields: fields)) }
        }
    }
}

@Suite(.serialized)
struct HTTPFailureDiagnosticsTests {
    private func channel(_ log: FailureLog) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        let state = HTTPFailureDiagnosticsState()
        try channel.pipeline.syncOperations.addHandler(HTTPIncomingByteCounter(state: state))
        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
        try channel.pipeline.syncOperations.addHandler(HTTPFailureDiagnosticsHandler(state: state, logger: log.logger))
        return channel
    }

    private func buffer(_ value: String, _ channel: EmbeddedChannel) -> ByteBuffer {
        var buffer = channel.allocator.buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        return buffer
    }

    private func output(_ channel: EmbeddedChannel) throws -> String {
        var result = ""
        while let bytes = try channel.readOutbound(as: ByteBuffer.self) {
            result += bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes) ?? ""
        }
        return result
    }

    @Test func malformedHeadKeepsEmpty400AndLogsFixedCauseWithoutRequestContents() throws {
        let log = FailureLog(), channel = try channel(log)
        defer { _ = try? channel.finish() }
        let request = "POST /internal/agent/codex/fixture-private-capability?token=fixture-secret HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer fixture-secret\r\nContent-Length: bad\r\n\r\n"
        #expect(throws: HTTPParserError.self) { _ = try channel.writeInbound(buffer(request, channel)) }
        let response = try output(channel)
        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(response.lowercased().contains("content-length: 0\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
        let entry = try #require(log.snapshot.first { $0.message == "HTTP/1.1 request parsing failed" })
        #expect(entry.fields["parser_error"] == "invalid character in content-length header")
        #expect(entry.fields["error_type"] == "HTTPParserError")
        #expect(entry.fields["connection_bytes_received"] == String(request.utf8.count))
        #expect(entry.fields["request_head_available"] == "false")
        #expect(!String(describing: log.snapshot).contains("fixture-secret"))
        #expect(!String(describing: log.snapshot).contains("fixture-private-capability"))
    }

    @Test func malformedChunkLogsOnlyNormalizedFramingAndCurrentBodyCount() throws {
        let log = FailureLog(), channel = try channel(log)
        defer { _ = try? channel.finish() }
        let id = String(repeating: "a", count: 32)
        let head = "POST /private HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: \(id)\r\nTransfer-Encoding: chunked\r\n\r\n"
        _ = try channel.writeInbound(buffer(head, channel))
        let body = "1\r\na\r\nz\r\n"
        #expect(throws: HTTPParserError.self) { _ = try channel.writeInbound(buffer(body, channel)) }
        let entry = try #require(log.snapshot.first { $0.message == "HTTP/1.1 request parsing failed" })
        #expect(entry.fields["parser_error"] == "invalid character in chunk size header")
        #expect(entry.fields["request_id"] == id)
        #expect(entry.fields["transfer_encoding"] == "chunked")
        #expect(entry.fields["connection_bytes_received"] == String(head.utf8.count + body.utf8.count))
        #expect(entry.fields["body_bytes_received"] == "1")
    }

    @Test func validLargeBodyStillParsesAndApplication4xxRecordsFraming() throws {
        let log = FailureLog(), channel = try channel(log)
        defer { _ = try? channel.finish() }
        let length = 12 * 1024 * 1024, id = String(repeating: "b", count: 32)
        let head = "POST / HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: \(id)\r\nContent-Length: \(length)\r\n\r\n"
        _ = try channel.writeInbound(buffer(head, channel))
        _ = try channel.writeInbound(buffer(String(repeating: "x", count: length), channel))
        _ = try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .forbidden)))
        _ = try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        #expect(!log.snapshot.contains { $0.message == "HTTP/1.1 request parsing failed" })
        let entry = try #require(log.snapshot.first { $0.message == "HTTP request rejected" })
        #expect(entry.fields["status"] == "403")
        #expect(entry.fields["content_length"] == String(length))
        #expect(entry.fields["body_bytes_received"] == String(length))
        #expect(entry.fields["request_id"] == id)
    }

    @Test func aLaterMalformedHeadDoesNotInheritAnEndedRequestsIdentity() throws {
        let log = FailureLog(), channel = try channel(log)
        defer { _ = try? channel.finish() }
        _ = try channel.writeInbound(buffer("GET / HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: \(String(repeating: "c", count: 32))\r\n\r\n", channel))
        _ = try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
        _ = try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        #expect(throws: HTTPParserError.self) {
            _ = try channel.writeInbound(buffer("POST / HTTP/1.1\r\nContent-Length: bad\r\n\r\n", channel))
        }
        let entry = try #require(log.snapshot.first { $0.message == "HTTP/1.1 request parsing failed" })
        #expect(entry.fields["request_head_available"] == "false")
        #expect(entry.fields["request_id"] == nil)
    }

    @Test func applicationMetadataOmitsMessagesAndRejectsUnstructuredCodesAndIDs() {
        let fields = HTTPFailureDiagnostics.metadata(requestID: "Bearer fixture-secret", status: 400,
            code: "invalid code: fixture-secret", failureCase: "badRequest")
        #expect(fields["request_id"] == nil)
        #expect(fields["error_code"] == "unclassified")
        #expect(!String(describing: fields).contains("fixture-secret"))
    }

    #if os(Linux)
    @Test func actualTCPListenerLogsMalformedRequestsBeforeTheApplicationHandler() async throws {
        let log = FailureLog(), calls = Mutex(0)
        let server = NIOHTTPServer(logger: log.logger, configuration: try .init(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0), supportedHTTPVersions: [.http1_1], transportSecurity: .plaintext))
        let task = Task {
            try await server.serve { _, _, _, sender in
                calls.withLock { $0 += 1 }
                var writer = try await sender.send(.init(status: .ok))
                try await writer.finish()
            }
        }
        do {
            let addresses = try await server.listeningAddresses
            let address = try #require(addresses.first)
            let response = try await Task.detached {
                try Self.rawRequest(port: address.port, request: "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: bad\r\n\r\n")
            }.value
            #expect(response.hasPrefix("HTTP/1.1 400"))
            #expect(calls.withLock { $0 } == 0)
            #expect(log.snapshot.contains { $0.message == "HTTP/1.1 request parsing failed" })
            task.cancel()
            _ = await task.result
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    private static func rawRequest(port: Int, request: String) throws -> String {
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Glibc.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = Glibc.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array(request.utf8)
        let sent = bytes.withUnsafeBytes { Glibc.send(fd, $0.baseAddress!, $0.count, Int32(MSG_NOSIGNAL)) }
        guard sent == bytes.count else { throw POSIXError(.EIO) }
        var result = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Glibc.recv(fd, &chunk, chunk.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
            result.append(contentsOf: chunk.prefix(count))
        }
        return String(decoding: result, as: UTF8.self)
    }
    #endif
}
