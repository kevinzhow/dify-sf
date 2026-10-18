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

/// Signs in with email and password (protocol 1.8, `POST /v1/auth/login`) and hands out the access token; after a `401`
/// the next caller signs in again. One per process is enough (all clients of a worker may share one account: several
/// clients of one account are allowed, each with its own client id).
public actor ServerAuth {
    public let base: String
    public let email: String
    private let password: String
    private var token: String?
    private var pending: Task<String, Error>?

    /// `base` is `http://host:port` of the server itself (not a fault proxy: signing in is not what the harness tests).
    public init(base: String, email: String, password: String) {
        self.base = base
        self.email = email
        self.password = password
    }

    /// The current access token, signing in first if there is none (one sign-in at a time).
    public func accessToken() async throws -> String {
        if let token { return token }
        if let pending { return try await pending.value }
        let (base, email, password) = (self.base, self.email, self.password)
        let task = Task { try await Self.login(base: base, email: email, password: password).access }
        pending = task
        defer { pending = nil }
        let t = try await task.value
        token = t
        return t
    }

    /// The server refused `old` (401): forget it so that the next request signs in again.
    public func invalidate(_ old: String) {
        if token == old { token = nil }
    }

    /// `POST /v1/auth/login`: (access token, refresh token).
    public static func login(base: String, email: String, password: String) async throws -> (access: String, refresh: String) {
        let (status, data) = try await call("POST", "\(base)/v1/auth/login", ["email": email, "password": password])
        guard status == 200 else { throw TransportError.status(status, String(decoding: data, as: UTF8.self)) }
        return try tokens(data)
    }

    /// Makes sure the server has a workspace this account can sign in to: on a fresh server (`GET /v1/setup` says
    /// `not_started`) it installs the account as the owner (`POST /v1/setup`). Returns an access token.
    public static func ensureWorkspace(base: String, email: String, password: String, name: String) async throws -> String {
        let (s0, d0) = try await call("GET", "\(base)/v1/setup", nil)
        guard s0 == 200 else { throw TransportError.status(s0, String(decoding: d0, as: UTF8.self)) }
        if (try? JSONSerialization.jsonObject(with: d0) as? [String: Any])?["step"] as? String == "not_started" {
            let (s1, d1) = try await call("POST", "\(base)/v1/setup", ["email": email, "name": name, "password": password])
            if s1 == 201 { return try tokens(d1).access }
            // 409 setup_done: someone else installed it at the same moment; sign in below.
            guard s1 == 409 else { throw TransportError.status(s1, String(decoding: d1, as: UTF8.self)) }
        }
        return try await login(base: base, email: email, password: password).access
    }

    private static func tokens(_ data: Data) throws -> (access: String, refresh: String) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let a = o["access_token"] as? String,
              let r = o["refresh_token"] as? String else { throw TransportError.malformed("no tokens in the answer") }
        return (a, r)
    }

    private static func call(_ method: String, _ url: String, _ body: [String: String]?) async throws -> (Int, Data) {
        var r = HTTPClientRequest(url: url)
        r.method = HTTPMethod(rawValue: method)
        if let body {
            r.headers.add(name: "Content-Type", value: "application/json")
            r.body = .bytes(try JSONSerialization.data(withJSONObject: body))
        }
        let resp = try await HTTPClient.shared.execute(r, timeout: .seconds(15))
        return (Int(resp.status.code), Data(buffer: try await resp.body.collect(upTo: 1 << 20)))
    }
}

/// HTTP + SSE transport for one client (its own connection pool, so a stream can never starve a POST).
public final class HTTPTransport: Sendable {
    public let postBase: String
    public let eventsBase: String
    public let doc: String
    /// Protocol 1.8: every request carries `Authorization: Bearer <access token>` from here (nil: no header, for servers
    /// before 1.8).
    public let auth: ServerAuth?
    private let http: HTTPClient       // POSTs: read timeout, so a swallowed response cannot clog the pool
    private let streamHTTP: HTTPClient // SSE: long-lived; liveness is the client's silence watchdog

    /// `postBase`/`eventsBase` are `http://host:port`; they may differ so that harnesses can route the two
    /// channels through different fault proxies.
    public init(postBase: String, eventsBase: String, doc: String, auth: ServerAuth? = nil) {
        self.postBase = postBase
        self.eventsBase = eventsBase
        self.doc = doc
        self.auth = auth
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

    /// The bearer token (nil without `auth`). A failed sign-in counts as a failed request (the client retries).
    private func bearer() async throws -> String? {
        guard let auth else { return nil }
        return try await auth.accessToken()
    }

    private func refused(_ status: Int, token: String?) async {
        if status == 401, let token, let auth { await auth.invalidate(token) }
    }

    public func post(_ req: SubmitRequest, timeout: Duration) async throws -> SubmitResponse {
        let body = try WireJSON.encode(req)
        let token = try await bearer()
        return try await withTimeout(timeout) { [http, postBase, doc, self] in
            var r = HTTPClientRequest(url: "\(postBase)/v1/docs/\(doc)/ops")
            r.method = .POST
            r.headers.add(name: "Content-Type", value: "application/json")
            if let token { r.headers.add(name: "Authorization", value: "Bearer \(token)") }
            r.body = .bytes(body)
            let resp = try await http.execute(r, timeout: .seconds(Int64(timeout.components.seconds)))
            let buf = try await resp.body.collect(upTo: 8 << 20)
            let data = Data(buffer: buf)
            guard resp.status == .ok else {
                await self.refused(Int(resp.status.code), token: token)
                throw TransportError.status(Int(resp.status.code), String(decoding: data, as: UTF8.self))
            }
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
        let token = try await bearer()
        if let token { req.headers.add(name: "Authorization", value: "Bearer \(token)") }
        if let last = o.lastEventId { req.headers.add(name: "Last-Event-ID", value: String(last)) }
        let http = self.streamHTTP
        let r = req
        let resp = try await withTimeout(headTimeout) { try await http.execute(r, deadline: .distantFuture) }
        guard resp.status == .ok else {
            let buf = try await resp.body.collect(upTo: 1 << 16)
            await refused(Int(resp.status.code), token: token)
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
