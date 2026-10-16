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
        pgConfig.options.minimumConnections = 2
        let pg = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        let store = PostgresStore(client: pg, logger: logger)
        let registry = DocumentRegistry(store: store, config: config, logger: logger)

        let app = try Application(.production,
                                  configuration: ServerConfiguration(address: .hostname(config.httpHost, port: config.httpPort)),
                                  configReader: reader.scoped(to: "collab.http"))
        Routes(registry: registry, store: store, config: config, logger: logger).register(on: app)

        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: pg),
                    .init(service: Migrator(store: store, logger: logger)),
                    .init(service: StreamMaintenance(registry: registry, intervalSeconds: config.ssePingSeconds)),
                    .init(service: app),
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

    func run() async throws {
        var delay = 0.2
        for attempt in 1...60 {
            do {
                try await store.migrate()
                logger.info("database schema ready")
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
