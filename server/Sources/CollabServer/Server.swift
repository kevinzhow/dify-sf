import Configuration
import CollabStore
import Foundation
import Logging
import PostgresNIO
import ServiceLifecycle
import Vapor

/// Sends keep-alive pings on every open stream and closes them on graceful shutdown.
struct StreamMaintenance: Service {
    let registry: DocumentRegistry
    let intervalSeconds: Int

    func run() async throws {
        try await withGracefulShutdownHandler {
            while !Task.isCancelled {
                do {
                    try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(intervalSeconds)) }
                } catch { break }
                await registry.pingAll()
            }
        } onGracefulShutdown: {
            Task { await registry.finishAll() }
        }
    }
}

public enum CollabServerMain {
    /// Boots the server: Postgres pool, migrations, Vapor application, stream maintenance, all under one ServiceGroup.
    public static func run() async throws {
        let reader = ConfigReader(providers: [CommandLineArgumentsProvider(), EnvironmentVariablesProvider()])
        let config = ServerConfig(reader: reader)
        let level = Logger.Level(rawValue: config.logLevel) ?? .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
        var logger = Logger(label: "collab-server")
        logger.logLevel = level

        var pgConfig = PostgresClient.Configuration(host: config.dbHost, port: config.dbPort, username: config.dbUser,
                                                    password: config.dbPassword, database: config.dbName, tls: .disable)
        pgConfig.options.maximumConnections = config.dbPoolSize
        pgConfig.options.additionalStartupParameters = [
            ("idle_in_transaction_session_timeout", "\(config.dbIdleInTransactionTimeoutMs)"),
            ("lock_timeout", "\(config.dbLockTimeoutMs)"),
            ("statement_timeout", "\(config.dbStatementTimeoutMs)"),
        ]
        pgConfig.options.minimumConnections = 2
        let pg = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        // Protocol 1.9: secrets at rest are encrypted with COLLAB_SECRETS_KEY. A malformed key stops the server (better than
        // silently refusing every secret); no key at all is allowed: secrets are then refused, never stored in plaintext.
        let secretsKey = try SecretsKey.from(setting: config.secretsKey)
        if secretsKey == nil {
            logger.warning("COLLAB_SECRETS_KEY is not set: model provider credentials and secret environment variables cannot be stored")
        }
        let store = PostgresStore(client: pg, logger: logger, operationTimeout: .milliseconds(config.dbOperationTimeoutMs), cipher: secretsKey)
        let models = try ModelService.live(config: config)
        logger.info("model providers: \(models.catalog.providers.count) definitions, credential checks \(config.modelsValidate ? "on" : "off")")
        let registry = DocumentRegistry(store: store, config: config, logger: logger)

        let app = try Application(.production,
                                  configuration: ServerConfiguration(address: .hostname(config.httpHost, port: config.httpPort)),
                                  configReader: reader.scoped(to: "collab.http"))
        app.middleware.use(CORSPolicy(allowedOrigins: config.corsAllowedOrigins), at: .beginning)
        let routes = try Routes(registry: registry, store: store, config: config, logger: logger, models: models)
        try routes.register(on: app)
        // Protocol 1.16: the work a stopped server left behind (answered pauses, deadlines that passed, unsent mail) runs
        // **after** the migrations, as part of the migrator's service: a server that starts during an upgrade must not
        // read a schema that is still changing, and a read that fails then must be retried rather than swallowed.
        let startupWork = StartupRecovery(routes: routes, logger: logger)
        let databaseReady = DatabaseReadiness()

        // A disabled optional service must not enter ServiceGroup and return
        // immediately: its successful return otherwise aborts the whole server.
        let agentMaintenanceServices: [ServiceGroupConfiguration.ServiceConfiguration] = config.agentService.isConfigured
            ? [.init(service: Named(name: "agent-maintenance", base: AgentMaintenance(routes: routes, readiness: databaseReady), logger: logger))]
            : []
        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: Named(name: "postgres", base: pg, logger: logger)),
                    .init(service: Named(name: "migrator", base: Migrator(store: store, logger: logger,
                        staleRunSeconds: config.runtimeMaxTimeSeconds + 300, blobs: routes.blobs,
                        afterMigration: startupWork, readiness: databaseReady), logger: logger)),
                    .init(service: Named(name: "streams", base: StreamMaintenance(registry: registry, intervalSeconds: config.ssePingSeconds), logger: logger)),
                ] + agentMaintenanceServices + [
                    // Protocol 1.16: node and global human-input deadlines, scanned in the product, not only in tests.
                    .init(service: Named(name: "human-input-timeouts",
                                         base: HumanInputTimeouts(routes: routes, intervalSeconds: config.humanInputScanSeconds, logger: logger, readiness: databaseReady),
                                         logger: logger)),
                    .init(service: Named(name: "annotation-index", base: AnnotationIndexWorker(routes: routes, readiness: databaseReady), logger: logger)),
                    .init(service: Named(name: "http", base: app, logger: logger)),
                ],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger))
        logger.info("starting on \(config.httpHost):\(config.httpPort), database \(config.dbHost):\(config.dbPort)/\(config.dbName)")
        try await group.run()
    }
}

/// What a stopped server left behind, run once the migrations have made the schema readable (protocol 1.16): the runs
/// whose answer arrived while it was down, the deadlines that passed, and the human-input mail that never went out. Each
/// piece asks the database again and retries a transient failure, because "the read failed" is not "there is nothing to
/// do" — the periodic services only cover work produced from now on.
struct StartupRecovery: Sendable {
    let routes: Routes
    let logger: Logger
    /// How many times a failing piece is tried before the pass ends (it is tried again on the next start).
    var attempts: Int = 5

    func run() async {
        var delay = 0.5
        // The resumed runs first: their pauses may then be ended by the timeout scan in the same pass.
        for name in ["resume answered runs", "sweep human-input timeouts", "deliver human-input mail"] {
            for attempt in 1...attempts {
                do {
                    switch name {
                    case "resume answered runs":
                        let resumed = try await routes.resumeRunsWaitingAfterRestartStrict()
                        if resumed > 0 { logger.info("resumed \(resumed) answered run(s) after a restart") }
                    case "sweep human-input timeouts":
                        let swept = await routes.sweepHumanInputTimeouts(now: Date())
                        if swept.timedOut > 0 || swept.expired > 0 {
                            logger.info("human input timeout scan at startup: \(swept.timedOut) form(s), \(swept.expired) run(s)")
                        }
                    default:
                        let mailed = await routes.deliverPendingHumanInputMail()
                        if mailed > 0 { logger.info("human input mail at startup: \(mailed) message(s) delivered") }
                    }
                    break
                } catch {
                    logger.warning("startup recovery (\(name)) attempt \(attempt) failed: \(error)")
                    if attempt < attempts { try? await Task.sleep(for: .seconds(delay)); delay = min(delay * 2, 8) }
                }
            }
        }
    }
}

/// Runs the (idempotent) migrations once the pool is up, retrying while Postgres is still starting.
struct Migrator: Service {
    let store: PostgresStore
    let logger: Logger
    /// Protocol 1.14: a run "running" for longer than this ran in a server that stopped.
    var staleRunSeconds: Double = 3900
    var blobs: (any BlobStore)? = nil
    /// Protocol 1.16: what a stopped server left behind, run once the schema is ready (nil: nothing).
    var afterMigration: StartupRecovery?
    var readiness: DatabaseReadiness? = nil

    func run() async throws {
        var delay = 0.2
        var migrated = false
        for attempt in 1...60 {
            do {
                try await store.migrate()
                logger.info("database schema ready")
                // Protocol 1.10: documents of older servers get their app row (Studio).
                let apps = try await store.backfillApps()
                if apps > 0 { logger.info("created the app rows of \(apps) documents of an older server") }
                // Protocol 1.11: apps of older servers get their Web App site.
                let sites = try await store.backfillSites()
                if sites > 0 { logger.info("created the Web App sites of \(sites) apps of an older server") }
                // Protocol 1.14: draft runs still "running" past the time limit ran in a server that stopped.
                try await store.failStaleWorkflowRuns(error: "The server stopped while the run was running",
                                                      startedBefore: Date().addingTimeInterval(-staleRunSeconds))
                // Protocol 1.9: secrets that older servers stored in plaintext are encrypted once a key is configured.
                let sealed = try await store.sealLegacySecrets()
                if sealed.sealed > 0 { logger.info("encrypted \(sealed.sealed) secrets stored in plaintext by an older server") }
                if sealed.plaintextLeft > 0 {
                    logger.warning("\(sealed.plaintextLeft) secrets are still stored in plaintext: set COLLAB_SECRETS_KEY to encrypt them")
                }
                migrated = true
                // The schema is ready: the recovery work may read it. Each piece retries on its own terms.
                if let afterMigration { await afterMigration.run() }
                await readiness?.markReady()
                break
            } catch {
                logger.warning("database not ready (attempt \(attempt)): \(error)")
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 1.5, 2)
            }
        }
        guard migrated, let blobs else { try await gracefulShutdown(); return }
        // Sweep only after migration. Disk/database failures retain pending metadata for the next pass.
        while !Task.isCancelled {
            do { _ = try await UploadReconciler.run(store: store, blobs: blobs) }
            catch { logger.warning("unfinished file cleanup will be retried") }
            do { try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(300)) } }
            catch { break }
        }
    }
}

/// Logs when a service of the group stops (and why): a service that ends early takes its neighbours down with it.
struct Named<S: Service>: Service {
    let name: String
    let base: S
    let logger: Logger

    func run() async throws {
        do {
            try await base.run()
            logger.warning("service \(name) finished")
        } catch {
            logger.warning("service \(name) failed: \(String(reflecting: error))")
            throw error
        }
    }
}

/// Recovery workers must not race the schema migration or the initial recovery pass.
actor DatabaseReadiness {
    private var ready = false
    func markReady() { ready = true }
    func wait() async throws {
        while !ready { try await Task.sleep(for: .milliseconds(50)) }
    }
}
