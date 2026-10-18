import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing
@testable import CollabServer

/// The HTTP server's connection timeouts seen from a raw TCP client (see Vendor/swift-http-server/PATCHES.md): an event
/// stream is a response that never ends, so no timeout meant for reading a request may cut it, while a client that
/// trickles a request head is still disconnected.
@Suite("HTTP connection timeouts", .enabled(if: testDbHost != nil))
struct ConnectionTimeoutTests {
    /// Vapor's fixed read-header timeout (NIOHTTPServerConfiguration.ConnectionTimeouts.defaults; Vapor has no setting).
    static let readHeaderTimeout = 30.0
    /// How long the stream test stays connected; must be above `readHeaderTimeout` to mean anything.
    static let streamHoldSeconds = Double(ProcessInfo.processInfo.environment["TEST_SSE_HOLD_SECONDS"] ?? "") ?? 40

    @Test func anEventStreamOutlivesTheReadHeaderTimeoutAndKeepsGettingPings() async throws {
        let config = ServerConfig.defaults
        let hold = Self.streamHoldSeconds
        try await withRunningServer(config: config) { api, port, registry in
            let owner = try await api.setupOwner()
            let doc = "t-hold-\(UUID().uuidString.lowercased().prefix(8))"
            #expect(try await api.put("/v1/docs/\(doc)", #"{"template":"example"}"#, token: owner).status == 201)
            // The pings of the real server (collab-server runs the same service in its service group).
            let pinger = Task { try await StreamMaintenance(registry: registry, intervalSeconds: config.ssePingSeconds).run() }
            defer { pinger.cancel() }

            let (text, closedAfter) = try await withRawConnection(port: port) { conn in
                try await conn.send("GET /v1/docs/\(doc)/events?proto=1.8 HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(owner)\r\nAccept: text/event-stream\r\n\r\n")
                _ = try await conn.wait(upTo: hold) { $0.closedAt != nil }
                return (conn.text, conn.closedAfter)
            }
            await registry.finishAll()
            #expect(text.hasPrefix("HTTP/1.1 200"), "\(text.prefix(200))")
            #expect(text.contains("event: ready"))
            #expect(closedAfter == nil, "the server closed the stream after \(closedAfter.map { "\($0)" } ?? "")")
            let pings = text.components(separatedBy: ": ping\n\n").count - 1
            #expect(pings >= Int(hold) / config.ssePingSeconds - 1, "\(pings) pings in \(hold) s")
        }
    }

    @Test func aNewConnectionThatNeverFinishesItsRequestHeadIsClosed() async throws {
        try await withRunningServer { _, port, _ in
            let closedAfter = try await withRawConnection(port: port) { conn in
                try await conn.send("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n")  // no blank line: the head never ends
                _ = try await conn.wait(upTo: Self.readHeaderTimeout + 15) { $0.closedAt != nil }
                return conn.closedAfter
            }
            Self.expectClosedByReadHeaderTimeout(closedAfter)
        }
    }

    @Test func theNextRequestHeadOnAKeptAliveConnectionIsStillTimed() async throws {
        try await withRunningServer { _, port, _ in
            let (answer, closedAfter) = try await withRawConnection(port: port) { conn in
                try await conn.send("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                _ = try await conn.wait(upTo: 10) { $0.text.contains(#""status":"ok""#) || $0.closedAt != nil }
                let answer = conn.text
                // The response is complete; from here on the server is waiting for the next request head.
                let start = ContinuousClock.now
                try await conn.send("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n")
                _ = try await conn.wait(upTo: Self.readHeaderTimeout + 15) { $0.closedAt != nil }
                return (answer, conn.closedAt.map { $0 - start })
            }
            #expect(answer.hasPrefix("HTTP/1.1 200") && !answer.lowercased().contains("connection: close"), "\(answer)")
            Self.expectClosedByReadHeaderTimeout(closedAfter)
        }
    }

    static func expectClosedByReadHeaderTimeout(_ closedAfter: Duration?, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let closedAfter else {
            Issue.record("still open \(readHeaderTimeout + 15) s after an incomplete request head", sourceLocation: sourceLocation)
            return
        }
        #expect(closedAfter >= .seconds(readHeaderTimeout - 3) && closedAfter <= .seconds(readHeaderTimeout + 10),
                "closed after \(closedAfter)", sourceLocation: sourceLocation)
    }
}

/// One raw TCP connection to the test server: exactly the bytes a test sends, everything the server answers, and the
/// moment the server closed the connection.
final class RawConnection: Sendable {
    struct State: Sendable {
        var text = ""
        var closedAt: ContinuousClock.Instant?
    }

    let openedAt = ContinuousClock.now
    private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private let state = Mutex(State())

    init(outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) { self.outbound = outbound }

    func send(_ text: String) async throws { try await outbound.write(ByteBuffer(string: text)) }

    var text: String { state.withLock { $0.text } }
    var closedAt: ContinuousClock.Instant? { state.withLock { $0.closedAt } }
    /// Time from opening to the server closing the connection; nil while it is open.
    var closedAfter: Duration? { closedAt.map { $0 - openedAt } }

    fileprivate func received(_ chunk: String) { state.withLock { $0.text += chunk } }
    fileprivate func ended() { state.withLock { $0.closedAt = $0.closedAt ?? .now } }

    /// Waits until `condition` holds or `seconds` have passed; whether it held.
    func wait(upTo seconds: Double, until condition: (State) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if state.withLock({ condition($0) }) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return state.withLock { condition($0) }
    }
}

/// Connects to the test server, runs `body`, then closes the connection (if the server has not already).
func withRawConnection<T: Sendable>(port: Int, _ body: @Sendable @escaping (RawConnection) async throws -> T) async throws -> T {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    let raw = channel.channel
    return try await channel.executeThenClose { inbound, outbound in
        let conn = RawConnection(outbound: outbound)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                defer { raw.close(promise: nil) }
                return try await body(conn)
            }
            do {
                for try await chunk in inbound { conn.received(String(buffer: chunk)) }
            } catch {}
            conn.ended()
            return try await group.next()!
        }
    }
}
