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
        // Protocol 1.16: runs that were answered while the server was down are resumed here, through the same path an
        // answer uses. Detached: serving requests matters more than this catching up.
        Task.detached {
            let resumed = await routes.resumeRunsWaitingAfterRestart()
            if resumed > 0 { logger.info("resumed \(resumed) answered run(s) after a restart") }
            // A stopped server also leaves pauses whose deadline passed: the startup scan ends or resumes them.
            let swept = await routes.sweepHumanInputTimeouts(now: Date())
            if swept.timedOut > 0 || swept.expired > 0 {
                logger.info("human input timeout scan at startup: \(swept.timedOut) form(s), \(swept.expired) run(s)")
            }
        }

        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: Named(name: "postgres", base: pg, logger: logger)),
                    .init(service: Named(name: "migrator", base: Migrator(store: store, logger: logger, staleRunSeconds: config.runtimeMaxTimeSeconds + 300), logger: logger)),
                    .init(service: Named(name: "streams", base: StreamMaintenance(registry: registry, intervalSeconds: config.ssePingSeconds), logger: logger)),
                    // Protocol 1.16: node and global human-input deadlines, scanned in the product, not only in tests.
                    .init(service: Named(name: "human-input-timeouts",
                                         base: HumanInputTimeouts(routes: routes, intervalSeconds: config.humanInputScanSeconds, logger: logger),
                                         logger: logger)),
                    .init(service: Named(name: "http", base: app, logger: logger)),
                ],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger))
        logger.info("starting on \(config.httpHost):\(config.httpPort), database \(config.dbHost):\(config.dbPort)/\(config.dbName)")
        try await group.run()
    }
}

/// Runs the (idempotent) migrations once the pool is up, retrying while Postgres is still starting.
struct Migrator: Service {
    let store: PostgresStore
    let logger: Logger
    /// Protocol 1.14: a run "running" for longer than this ran in a server that stopped.
    var staleRunSeconds: Double = 3900

    func run() async throws {
        var delay = 0.2
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
                break
            } catch {
                logger.warning("database not ready (attempt \(attempt)): \(error)")
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 1.5, 2)
            }
        }
        // Stay alive until shutdown: a finished service would not stop the group, but keep the lifecycle simple.
        try await gracefulShutdown()
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
