import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTPTypes
import Testing
@testable import NIOHTTPServer
#if os(Linux)
import Glibc
#endif

@Suite(.serialized)
struct HTTPConnectionCloseTests {
    private func channel(connection: String? = nil) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 0)).wait()
        try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())
        var request = HTTPRequest(method: .post, scheme: "http", authority: "localhost", path: "/")
        request.headerFields[.connection] = connection
        _ = try channel.writeInbound(HTTPRequestPart.head(request))
        _ = try channel.writeInbound(HTTPRequestPart.end(nil))
        return channel
    }

    @Test(arguments: ["close", "ClOsE", "keep-alive, CLOSE", "keep-alive,\tclose"])
    func requestCloseWaitsUntilFinalResponseEnd(connection: String) throws {
        let channel = try channel(connection: connection)
        defer { _ = try? channel.finish() }
        _ = try channel.writeOutbound(HTTPResponsePart.head(.init(status: .ok)))
        let head = try #require(channel.readOutbound(as: HTTPResponsePart.self))
        guard case .head(let response) = head else { Issue.record("Missing head"); return }
        #expect(response.headerFields[.connection] == "close")
        #expect(channel.isActive)
        _ = try channel.writeOutbound(HTTPResponsePart.body(ByteBuffer(string: "streamed")))
        #expect(channel.isActive)
        _ = try channel.writeOutbound(HTTPResponsePart.end(nil))
        #expect(!channel.isActive)
    }

    @Test func serverSelectedCloseWaitsUntilFinalResponseEnd() throws {
        let channel = try channel()
        defer { _ = try? channel.finish() }
        _ = try channel.writeOutbound(HTTPResponsePart.head(.init(status: .ok, headerFields: [.connection: "CLOSE"])))
        #expect(channel.isActive)
        _ = try channel.writeOutbound(HTTPResponsePart.end(nil))
        #expect(!channel.isActive)
    }

    @Test func informationalResponseDoesNotCloseOrConsumeFinalPolicy() throws {
        let channel = try channel(connection: "close")
        defer { _ = try? channel.finish() }
        _ = try channel.writeOutbound(HTTPResponsePart.head(.init(status: .continue)))
        let interim = try #require(channel.readOutbound(as: HTTPResponsePart.self))
        guard case .head(let response) = interim else { Issue.record("Missing informational head"); return }
        #expect(response.headerFields[.connection] == nil)
        #expect(channel.isActive)
        _ = try channel.writeOutbound(HTTPResponsePart.head(.init(status: .ok)))
        #expect(channel.isActive)
        _ = try channel.writeOutbound(HTTPResponsePart.end(nil))
        #expect(!channel.isActive)
    }

    @Test(arguments: ["keep-alive", "disclose"])
    func ordinaryRequestsRemainReusable(connection: String) throws {
        let channel = try channel(connection: connection)
        defer { _ = try? channel.finish() }
        _ = try channel.writeOutbound(HTTPResponsePart.head(.init(status: .ok)))
        _ = try channel.writeOutbound(HTTPResponsePart.end(nil))
        #expect(channel.isActive)
    }

    #if os(Linux)
    @Test(arguments: [false, true])
    func actualTCPClosesAfterCompleteStreamAndPreservesPipelining(pipelined: Bool) async throws {
        let server = NIOHTTPServer(logger: Logger(label: "http-close-test"), configuration: try .init(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0), supportedHTTPVersions: [.http1_1], transportSecurity: .plaintext))
        let task = Task {
            try await server.serve { _, _, reader, sender in
                var reader = reader, ended = false
                while !ended {
                    ended = try await reader.read { _, trailers in
                        if case .some = trailers { return true }
                        return false
                    }
                }
                var writer = try await sender.send(.init(status: .ok, headerFields: [.contentLength: "2"]))
                try await Task.sleep(for: .milliseconds(30))
                var bytes = NIOHTTPServer.Reader.Buffer(copying: "ok".utf8)
                try await writer.write(buffer: &bytes)
                try await writer.finish()
            }
        }
        do {
            let addresses = try await server.listeningAddresses
            let address = try #require(addresses.first)
            let response = try await Task.detached {
                let request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}"
                let final = "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}"
                return try Self.rawRequest(port: address.port, request: (pipelined ? request + request : "") + final)
            }.value
            let count = pipelined ? 3 : 1
            #expect(response.components(separatedBy: "HTTP/1.1 200").count - 1 == count)
            #expect(!response.contains("HTTP/1.1 400"))
            #expect(response.lowercased().components(separatedBy: "connection: close").count - 1 == 1)
            #expect(response.components(separatedBy: "\r\n\r\nok").count - 1 == count)
            task.cancel(); _ = await task.result
        } catch {
            task.cancel(); _ = await task.result
            throw error
        }
    }

    /// Reads through EOF, so a missing transport close fails even after all bytes arrive.
    private static func rawRequest(port: Int, request: String) throws -> String {
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Glibc.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = Glibc.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
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
