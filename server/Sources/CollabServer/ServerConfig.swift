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

    public init(reader: ConfigReader) {
        httpHost = reader.string(forKey: "collab.http.host", default: "127.0.0.1")
        httpPort = reader.int(forKey: "collab.http.port", default: 8080)
        dbHost = reader.string(forKey: "collab.db.host", default: "127.0.0.1")
        dbPort = reader.int(forKey: "collab.db.port", default: 5432)
        dbUser = reader.string(forKey: "collab.db.user", default: "collab")
        dbPassword = reader.string(forKey: "collab.db.password", isSecret: true, default: "collab")
        dbName = reader.string(forKey: "collab.db.name", default: "collab")
        dbPoolSize = reader.int(forKey: "collab.db.poolSize", default: 16)
        ssePingSeconds = reader.int(forKey: "collab.sse.pingSeconds", default: 10)
        maxReplay = reader.int(forKey: "collab.maxReplay", default: 2000)
        snapshotEvery = reader.int(forKey: "collab.snapshotEvery", default: 200)
        testCommitDelayMillis = reader.int(forKey: "collab.test.commitDelayMillis", default: 0)
        logLevel = reader.string(forKey: "collab.log.level", default: "info")
        corsAllowedOrigins = reader.string(forKey: "collab.cors.allowedOrigins", default: "http://localhost:*,http://127.0.0.1:*,http://[::1]:*")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        testDefect = reader.string(forKey: "collab.test.defect", default: "")
    }
}

extension ServerConfig {
    /// All defaults (no environment, no arguments): for tests.
    public static var defaults: ServerConfig { ServerConfig(reader: ConfigReader(provider: InMemoryProvider(values: [:]))) }
}
