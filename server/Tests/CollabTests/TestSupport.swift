import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Logging
import PostgresNIO
import Testing
import VaporTesting
@testable import CollabServer

/// Postgres for the integration tests (see server/run-db-tests.sh); nil = those suites are skipped.
let testDbHost = ProcessInfo.processInfo.environment["TEST_DB_HOST"]

/// Boots a PostgresClient on a fresh, empty schema for the duration of `body`, so that every test has its own database
/// (accounts are per server: "set up once" must be testable, and tests run in parallel).
/// The store has a random secrets key (protocol 1.9) unless `secretsKey` is false (a server without COLLAB_SECRETS_KEY).
func withStore<T: Sendable>(secretsKey: Bool = true, cipher: (any SecretCipher)? = nil,
                            _ body: @Sendable (PostgresStore, Logger) async throws -> T) async throws -> T {
    try await withStoreAndSchema(secretsKey: secretsKey, cipher: cipher) { store, logger, _ in try await body(store, logger) }
}

/// Like `withStore`, but hands over the schema name too: a test that needs a second, independent connection (to hold a
/// row lock while the Store API under test waits on it) builds its own client with the same `search_path`. Opening it
/// from the store's own client would be the wrong test — the waiter could be blocked on the pool, not on the row.
func withStoreAndSchema<T: Sendable>(secretsKey: Bool = true, cipher: (any SecretCipher)? = nil,
                                     _ body: @Sendable (PostgresStore, Logger, String) async throws -> T) async throws -> T {
    var logger = Logger(label: "test")
    logger.logLevel = .error
    let port = Int(ProcessInfo.processInfo.environment["TEST_DB_PORT"] ?? "5432") ?? 5432
    let schema = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
    let base = PostgresClient.Configuration(host: testDbHost!, port: port, username: "collab", password: "collab", database: "collab", tls: .disable)
    let admin = PostgresClient(configuration: base, backgroundLogger: logger)
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await admin.run() }
        var created = false
        for _ in 0..<50 where !created {
            do {
                _ = try await admin.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"), logger: logger)
                created = true
            } catch { try await Task.sleep(for: .milliseconds(100)) }
        }
        group.cancelAll()
    }
    var cfg = base
    cfg.options.additionalStartupParameters = [("search_path", String(schema))]
    let client = PostgresClient(configuration: cfg, backgroundLogger: logger)
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await client.run(); return nil }
        let store = PostgresStore(client: client, logger: logger, cipher: secretsKey ? (cipher ?? SecretsKey.random()) : nil)
        var migrated = false
        for _ in 0..<50 where !migrated {
            do { try await store.migrate(); migrated = true } catch { try await Task.sleep(for: .milliseconds(100)) }
        }
        let result = try await body(store, logger, String(schema))
        group.cancelAll()
        return result
    }!
}

/// The routes of one server (`Routes`) over Vapor's in-memory test client, with JSON helpers.
struct API {
    let client: any TestClient

    struct Answer {
        var status: Int
        var text: String
        var json: [String: Value] {
            guard case .map(let m)? = try? WireJSON.decode(Value.self, from: Data(text.utf8)) else { return [:] }
            return m
        }
        var errorCode: String? {
            if case .map(let e)? = json["error"], case .string(let c)? = e["code"] { return c }
            return nil
        }
        func str(_ k: String) -> String { if case .string(let s)? = json[k] { return s }; return "" }
        func list(_ k: String) -> [Value] { if case .list(let xs)? = json[k] { return xs }; return [] }
        func obj(_ k: String) -> [String: Value] { if case .map(let m)? = json[k] { return m }; return [:] }
    }

    func send(_ method: HTTPRequest.Method, _ path: String, _ body: String? = nil, token: String? = nil,
              headers extra: [(String, String)] = []) async throws -> Answer {
        var headers = HTTPFields()
        if let token { headers[.authorization] = "Bearer \(token)" }
        for (k, v) in extra { headers[HTTPField.Name(k)!] = v }
        let res = try await client.send(method, headers: headers, to: .init(stringLiteral: path)) { req in
            if let body { req.body = .init(string: body) }
        }
        let text = res.status.code == 204 ? "" : (try? await res.body.requireString()) ?? ""
        return Answer(status: Int(res.status.code), text: text)
    }

    func get(_ path: String, token: String? = nil) async throws -> Answer { try await send(.get, path, token: token) }
    func post(_ path: String, _ body: String? = nil, token: String? = nil) async throws -> Answer { try await send(.post, path, body, token: token) }
    func put(_ path: String, _ body: String? = nil, token: String? = nil) async throws -> Answer { try await send(.put, path, body, token: token) }
    func delete(_ path: String, _ body: String? = nil, token: String? = nil) async throws -> Answer { try await send(.delete, path, body, token: token) }
    func patch(_ path: String, _ body: String? = nil, token: String? = nil) async throws -> Answer { try await send(.patch, path, body, token: token) }

    /// `POST /v1/setup` on a fresh database: the owner's access token.
    func setupOwner(email: String = "owner@example.com", name: String = "Olivia", password: String = "owner-pass-1") async throws -> String {
        let a = try await post("/v1/setup", #"{"email":"\#(email)","name":"\#(name)","password":"\#(password)"}"#)
        #expect(a.status == 201, "setup: \(a.text)")
        return a.str("access_token")
    }

    /// Invites `email` with `role` (as `inviter`), activates the link, returns (account id, access token).
    func member(_ email: String, role: String, name: String = "Member", password: String = "member-pass-1",
                inviter: String) async throws -> (id: String, token: String) {
        let inv = try await post("/v1/workspace/members/invite-email", #"{"emails":["\#(email)"],"role":"\#(role)"}"#, token: inviter)
        #expect(inv.status == 201, "invite: \(inv.text)")
        guard case .map(let r)? = inv.list("invitation_results").first, case .string(let url)? = r["url"],
              let token = url.split(separator: "token=").last.map(String.init) else {
            Issue.record("no activation link: \(inv.text)")
            return ("", "")
        }
        let act = try await post("/v1/activate", #"{"token":"\#(token)","name":"\#(name)","password":"\#(password)"}"#)
        #expect(act.status == 200, "activate: \(act.text)")
        if case .string(let id)? = act.obj("account")["id"] { return (id, act.str("access_token")) }
        return ("", act.str("access_token"))
    }
}

/// Runs `body` against the routes of a server on a fresh database.
func withServer(config: ServerConfig = .defaults, secretsKey: Bool = true, models: ModelService? = nil,
                _ body: @Sendable @escaping (API, PostgresStore, DocumentRegistry) async throws -> Void) async throws {
    try await withStore(secretsKey: secretsKey) { store, logger in
        let registry = DocumentRegistry(store: store, config: config, logger: logger)
        try await withApp(configure: { app in
            try Routes(registry: registry, store: store, config: config, logger: logger, models: models).register(on: app)
        }) { app in
            try await app.testing { client in try await body(API(client: client), store, registry) }
        }
    }
}

/// Like `withServer`, but over a real listening socket (Vapor's live test mode): for what only a TCP connection shows, such
/// as the HTTP server's connection timeouts. `body` also gets the bound port.
func withRunningServer(config: ServerConfig = .defaults,
                       _ body: @Sendable @escaping (API, Int, DocumentRegistry) async throws -> Void) async throws {
    try await withStore { store, logger in
        let registry = DocumentRegistry(store: store, config: config, logger: logger)
        try await withApp(configure: { app in
            try Routes(registry: registry, store: store, config: config, logger: logger).register(on: app)
        }) { app in
            try await app.testing(.running) { client in
                guard let port = client.port else { Issue.record("the live test server has no port"); return }
                try await body(API(client: client), port, registry)
            }
        }
    }
}

/// Sets up the owner on the fresh database behind `client`: headers with its bearer token.
func ownerHeaders(_ client: any TestClient) async throws -> HTTPFields {
    let token = try await API(client: client).setupOwner()
    var h = HTTPFields()
    h[.authorization] = "Bearer \(token)"
    return h
}
