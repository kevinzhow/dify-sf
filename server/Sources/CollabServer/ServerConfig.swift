import Configuration
import Foundation

/// Runtime configuration, read through swift-configuration from environment variables and command-line
/// arguments (`--collab.http.port 8080` or `COLLAB_HTTP_PORT=8080`).
public struct ServerConfig: Sendable {
    public var httpHost: String
    public var httpPort: Int
    public var dbHost: String
    public var dbPort: Int
    public var dbUser: String
    public var dbPassword: String
    public var dbName: String
    public var dbPoolSize: Int
    /// Postgres kills a session that sits idle inside a transaction this long (a half-open connection that holds the
    /// document row lock would otherwise block that document forever).
    public var dbIdleInTransactionTimeoutMs: Int
    /// A commit that cannot get the document row lock within this time fails (503, the client retries).
    public var dbLockTimeoutMs: Int
    public var dbStatementTimeoutMs: Int
    /// Client-side bound on any single database operation (covers connections that die without telling us).
    public var dbOperationTimeoutMs: Int
    /// Seconds between SSE keep-alive pings.
    public var ssePingSeconds: Int
    /// A reconnecting client further behind than this gets a snapshot instead of a replay.
    public var maxReplay: Int
    /// Write a checkpoint every N committed ops.
    public var snapshotEvery: Int
    /// Fault injection for tests: extra delay (milliseconds) before every commit. 0 in production.
    public var testCommitDelayMillis: Int
    public var logLevel: String
    /// Browser origins allowed to call the API (CORS). Entries: exact origin, `scheme://host:*` (any port), or `*`.
    public var corsAllowedOrigins: [String]
    /// TEST ONLY: deliberately break the server so that the harness can prove it notices
    /// (`ackBeforeCommit`, `skipStaleCheck`). Empty in every real deployment.
    public var testDefect: String
    /// Accounts (protocol 1.8), Dify's defaults: access tokens live 60 minutes, refresh tokens 30 days, activation links 72 hours.
    public var accessTokenMinutes: Int
    public var refreshTokenDays: Int
    public var inviteExpiryHours: Int
    /// Dify's login error rate limit: more than `loginMaxFailures` failed sign-ins for one email lock it for
    /// `loginLockoutSeconds` (Dify: 5 and 86400), counted from the last failure. Per server process.
    public var loginMaxFailures: Int
    public var loginLockoutSeconds: Int

    public init(reader: ConfigReader) {
        httpHost = reader.string(forKey: "collab.http.host", default: "127.0.0.1")
        httpPort = reader.int(forKey: "collab.http.port", default: 8080)
        dbHost = reader.string(forKey: "collab.db.host", default: "127.0.0.1")
        dbPort = reader.int(forKey: "collab.db.port", default: 5432)
        dbUser = reader.string(forKey: "collab.db.user", default: "collab")
        dbPassword = reader.string(forKey: "collab.db.password", isSecret: true, default: "collab")
        dbName = reader.string(forKey: "collab.db.name", default: "collab")
        dbPoolSize = reader.int(forKey: "collab.db.poolSize", default: 16)
        dbIdleInTransactionTimeoutMs = reader.int(forKey: "collab.db.idleInTransactionTimeoutMs", default: 15_000)
        dbLockTimeoutMs = reader.int(forKey: "collab.db.lockTimeoutMs", default: 10_000)
        dbStatementTimeoutMs = reader.int(forKey: "collab.db.statementTimeoutMs", default: 30_000)
        dbOperationTimeoutMs = reader.int(forKey: "collab.db.operationTimeoutMs", default: 20_000)
        ssePingSeconds = reader.int(forKey: "collab.sse.pingSeconds", default: 10)
        maxReplay = reader.int(forKey: "collab.maxReplay", default: 2000)
        snapshotEvery = reader.int(forKey: "collab.snapshotEvery", default: 200)
        testCommitDelayMillis = reader.int(forKey: "collab.test.commitDelayMillis", default: 0)
        logLevel = reader.string(forKey: "collab.log.level", default: "info")
        corsAllowedOrigins = reader.string(forKey: "collab.cors.allowedOrigins", default: "http://localhost:*,http://127.0.0.1:*,http://[::1]:*")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        testDefect = reader.string(forKey: "collab.test.defect", default: "")
        accessTokenMinutes = reader.int(forKey: "collab.auth.accessTokenMinutes", default: 60)
        refreshTokenDays = reader.int(forKey: "collab.auth.refreshTokenDays", default: 30)
        inviteExpiryHours = reader.int(forKey: "collab.auth.inviteExpiryHours", default: 72)
        loginMaxFailures = reader.int(forKey: "collab.auth.loginMaxFailures", default: 5)
        loginLockoutSeconds = reader.int(forKey: "collab.auth.loginLockoutSeconds", default: 86_400)
    }
}

extension ServerConfig {
    /// All defaults (no environment, no arguments): for tests.
    public static var defaults: ServerConfig { ServerConfig(reader: ConfigReader(provider: InMemoryProvider(values: [:]))) }
}
