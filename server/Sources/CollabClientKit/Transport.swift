import AsyncHTTPClient
import CollabCore
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

public enum TransportError: Error, Sendable {
    case status(Int, String)
    case timeout
    case malformed(String)
}

/// HTTP + SSE transport for one client (its own connection pool, so a stream can never starve a POST).
public final class HTTPTransport: Sendable {
    public let postBase: String
    public let eventsBase: String
    public let doc: String
    private let http: HTTPClient       // POSTs: read timeout, so a swallowed response cannot clog the pool
    private let streamHTTP: HTTPClient // SSE: long-lived; liveness is the client's silence watchdog

    /// `postBase`/`eventsBase` are `http://host:port`; they may differ so that harnesses can route the two
    /// channels through different fault proxies.
    public init(postBase: String, eventsBase: String, doc: String) {
        self.postBase = postBase
        self.eventsBase = eventsBase
        self.doc = doc
        var cfg = HTTPClient.Configuration()
        cfg.timeout = .init(connect: .seconds(5), read: .seconds(20))
        cfg.connectionPool = .init(idleTimeout: .seconds(30), concurrentHTTP1ConnectionsPerHostSoftLimit: 4)
        http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: cfg)
        var scfg = HTTPClient.Configuration()
        scfg.timeout = .init(connect: .seconds(5))
        scfg.connectionPool = .init(idleTimeout: .seconds(30), concurrentHTTP1ConnectionsPerHostSoftLimit: 2)
        streamHTTP = HTTPClient(eventLoopGroupProvider: .singleton, configuration: scfg)
    }

    public func shutdown() async {
        try? await http.shutdown()
        try? await streamHTTP.shutdown()
    }

    public func post(_ req: SubmitRequest, timeout: Duration) async throws -> SubmitResponse {
        let body = try WireJSON.encode(req)
        return try await withTimeout(timeout) { [http, postBase, doc] in
            var r = HTTPClientRequest(url: "\(postBase)/v1/docs/\(doc)/ops")
            r.method = .POST
            r.headers.add(name: "Content-Type", value: "application/json")
            r.body = .bytes(body)
            let resp = try await http.execute(r, timeout: .seconds(Int64(timeout.components.seconds)))
            let buf = try await resp.body.collect(upTo: 8 << 20)
            let data = Data(buffer: buf)
            guard resp.status == .ok else { throw TransportError.status(Int(resp.status.code), String(decoding: data, as: UTF8.self)) }
            return try WireJSON.decode(SubmitResponse.self, from: data)
        }
    }

    /// Opens the stream and feeds every event (and a `.ping` for any keep-alive/comment byte) to `onEvent` until it ends.
    public func stream(_ o: StreamOpen, headTimeout: Duration, onEvent: @Sendable (StreamEvent) async -> Void) async throws {
        var q = "client=\(o.client ?? "")"
        if let f = o.from { q += "&from=\(f)" }
        if let p = o.proto { q += "&proto=\(p)" }
        var req = HTTPClientRequest(url: "\(eventsBase)/v1/docs/\(doc)/events?\(q)")
        req.method = .GET
        req.headers.add(name: "Accept", value: "text/event-stream")
        if let last = o.lastEventId { req.headers.add(name: "Last-Event-ID", value: String(last)) }
        let http = self.streamHTTP
        let r = req
        let resp = try await withTimeout(headTimeout) { try await http.execute(r, deadline: .distantFuture) }
        guard resp.status == .ok else {
            let buf = try await resp.body.collect(upTo: 1 << 16)
            throw TransportError.status(Int(resp.status.code), String(buffer: buf))
        }
        var parser = SSEParser()
        for try await chunk in resp.body {
            let msgs = parser.feed(chunk.readableBytesView)
            if msgs.isEmpty { await onEvent(.ping) }  // bytes arrived (heartbeat comment or partial frame): the connection is alive
            for m in msgs {
                if let ev = try? StreamEvent.parse(event: m.event, data: m.data) { await onEvent(ev) } else { await onEvent(.ping) }
            }
        }
    }
}
