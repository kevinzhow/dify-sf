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
    /// Outgoing mail (Dify's `MAIL_TYPE=smtp`, `SMTP_*`, `MAIL_DEFAULT_SEND_FROM`): unset = no mail (`MailConfig`).
    public var mail: MailConfig
    /// Forgot password (Dify's `RESET_PASSWORD_TOKEN_EXPIRY_MINUTES`, `FORGOT_PASSWORD_LOCKOUT_DURATION`,
    /// `EMAIL_SEND_IP_LIMIT_PER_MINUTE`) and the admins' reset links (`PasswordResetConfig`).
    public var passwordReset: PasswordResetConfig
    /// Protocol 1.12: changing the account's email (Dify's `CHANGE_EMAIL_TOKEN_EXPIRY_MINUTES`, `CHANGE_EMAIL_LOCKOUT_DURATION`).
    public var changeEmail: ChangeEmailConfig
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
    /// Protocol 1.9: the key that encrypts secrets at rest (model provider credentials, secret environment variables): base64
    /// of 32 random bytes. Empty = no key: the server refuses to store secrets (`503 secrets_key_missing`) and cannot read
    /// sealed ones; it never stores them in plaintext. Losing or changing the key makes stored secrets unreadable.
    public var secretsKey: String
    /// Protocol 1.17: local file storage and signed delivery. Empty signing key keeps uploads disabled.
    var files: FileStorageConfig
    /// Check model provider credentials with one request to the provider before saving them (`COLLAB_MODELS_VALIDATE`,
    /// default true; false for servers without internet access).
    public var modelsValidate: Bool
    /// Timeout of that request.
    public var modelsValidateTimeoutSeconds: Int
    /// Protocol 1.11: where the Web App of an app is served (Dify's `APP_WEB_URL`; the site's `app_base_url`), e.g.
    /// `https://apps.example.com`. Empty = the request's origin (`X-Forwarded-Host` / `-Proto`), else this server's address.
    public var webAppBaseURL: String
    /// Protocol 1.11: the Service API base (Dify's `SERVICE_API_URL`; `api_base_url` is it with `/v1`). Empty = as above.
    public var serviceAPIURL: String
    /// Protocol 1.16: how long a run may stay paused waiting for human input before the global deadline (Dify's
    /// `HUMAN_INPUT_GLOBAL_TIMEOUT_SECONDS`, default 7 days). A submission past it answers 412 and the timeout scanner
    /// stops the run; 0 disables the global deadline.
    public var humanInputGlobalTimeoutSeconds: Int
    /// Protocol 1.13: Dify's plugin daemon (models), e.g. `http://plugin_daemon:5002` (`COLLAB_PLUGIN_DAEMON_URL`; Dify's
    /// `PLUGIN_DAEMON_URL`). Empty = no model runtime: LLM nodes cannot run and `system-features` does not offer runs.
    public var pluginDaemonURL: String
    /// Its `SERVER_KEY` (`COLLAB_PLUGIN_DAEMON_KEY`; Dify's `PLUGIN_DAEMON_KEY`), sent as `X-Api-Key`.
    public var pluginDaemonKey: String
    /// The tenant dify-sf's workspace is in the daemon (`COLLAB_PLUGIN_DAEMON_TENANT`): plugins are installed per tenant.
    public var pluginDaemonTenant: String
    /// Bound on one daemon request, streaming included (`COLLAB_PLUGIN_DAEMON_TIMEOUT_SECONDS`; Dify's 600).
    public var pluginDaemonTimeoutSeconds: Int
    /// Protocol 1.14, draft runs: nodes running at once (`COLLAB_RUNTIME_MAX_WORKERS`; Dify's `GRAPH_ENGINE_MAX_WORKERS`, 10),
    /// the step limit (`COLLAB_RUNTIME_MAX_STEPS`; Dify's `WORKFLOW_MAX_EXECUTION_STEPS`, 500) and the time limit in seconds
    /// (`COLLAB_RUNTIME_MAX_TIME_SECONDS`; Dify's `WORKFLOW_MAX_EXECUTION_TIME`, 3600).
    public var runtimeMaxWorkers: Int
    public var runtimeMaxSteps: Int
    public var runtimeMaxTimeSeconds: Double
    /// Protocol 1.14: the code sandbox (`COLLAB_SANDBOX_URL` / `_KEY`), the SSRF proxy (`COLLAB_SSRF_PROXY_URL`) and Dify's
    /// code / template / HTTP request limits (RuntimeServiceClients.swift).
    public var runtimeServices: RuntimeServicesConfig

    /// The tenant id when `COLLAB_PLUGIN_DAEMON_TENANT` is unset (one workspace per server).
    public static let defaultPluginDaemonTenant = "00000000-0000-0000-0000-000000000001"

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
        humanInputGlobalTimeoutSeconds = reader.int(forKey: "collab.humanInputGlobalTimeoutSeconds", default: 604_800)
        testCommitDelayMillis = reader.int(forKey: "collab.test.commitDelayMillis", default: 0)
        logLevel = reader.string(forKey: "collab.log.level", default: "info")
        mail = MailConfig(reader: reader)
        passwordReset = PasswordResetConfig(reader: reader)
        changeEmail = ChangeEmailConfig(reader: reader)
        corsAllowedOrigins = reader.string(forKey: "collab.cors.allowedOrigins", default: "http://localhost:*,http://127.0.0.1:*,http://[::1]:*")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        testDefect = reader.string(forKey: "collab.test.defect", default: "")
        accessTokenMinutes = reader.int(forKey: "collab.auth.accessTokenMinutes", default: 60)
        refreshTokenDays = reader.int(forKey: "collab.auth.refreshTokenDays", default: 30)
        inviteExpiryHours = reader.int(forKey: "collab.auth.inviteExpiryHours", default: 72)
        loginMaxFailures = reader.int(forKey: "collab.auth.loginMaxFailures", default: 5)
        loginLockoutSeconds = reader.int(forKey: "collab.auth.loginLockoutSeconds", default: 86_400)
        secretsKey = reader.string(forKey: "collab.secrets.key", isSecret: true, default: "")
        files = FileStorageConfig(reader: reader)
        modelsValidate = reader.bool(forKey: "collab.models.validate", default: true)
        modelsValidateTimeoutSeconds = reader.int(forKey: "collab.models.validateTimeoutSeconds", default: 10)
        webAppBaseURL = reader.string(forKey: "collab.webapp.baseUrl", default: "").trimmingCharacters(in: .whitespaces)
        serviceAPIURL = reader.string(forKey: "collab.serviceApi.url", default: "").trimmingCharacters(in: .whitespaces)
        pluginDaemonURL = reader.string(forKey: "collab.pluginDaemon.url", default: "").trimmingCharacters(in: .whitespaces)
        pluginDaemonKey = reader.string(forKey: "collab.pluginDaemon.key", isSecret: true, default: "")
        pluginDaemonTenant = reader.string(forKey: "collab.pluginDaemon.tenant", default: Self.defaultPluginDaemonTenant)
            .trimmingCharacters(in: .whitespaces)
        pluginDaemonTimeoutSeconds = reader.int(forKey: "collab.pluginDaemon.timeoutSeconds", default: 600)
        runtimeMaxWorkers = max(1, reader.int(forKey: "collab.runtime.maxWorkers", default: 10))
        runtimeMaxSteps = max(1, reader.int(forKey: "collab.runtime.maxSteps", default: 500))
        runtimeMaxTimeSeconds = Double(max(1, reader.int(forKey: "collab.runtime.maxTimeSeconds", default: 3600)))
        runtimeServices = RuntimeServicesConfig(reader: reader)
    }
}

extension ServerConfig {
    /// All defaults (no environment, no arguments): for tests.
    public static var defaults: ServerConfig { ServerConfig(reader: ConfigReader(provider: InMemoryProvider(values: [:]))) }
}
