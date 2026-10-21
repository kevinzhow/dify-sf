import CollabModels
import CollabStore
@testable import CollabServer

func humanInputTestConfig(_ base: ServerConfig = .defaults) -> ServerConfig {
    var config = base
    config.humanInputWebEnabled = true
    config.humanInputEmailEnabled = true
    return config
}

func withHumanInputServer(config: ServerConfig = .defaults, secretsKey: Bool = true, models: ModelService? = nil,
                         _ body: @Sendable @escaping (API, PostgresStore, DocumentRegistry) async throws -> Void) async throws {
    try await withServer(config: humanInputTestConfig(config), secretsKey: secretsKey, models: models, body)
}

func withHumanInputServerAndRoutes(config: ServerConfig = .defaults, secretsKey: Bool = true, models: ModelService? = nil,
                                  _ body: @Sendable @escaping (API, PostgresStore, Routes) async throws -> Void) async throws {
    try await withServerAndRoutes(config: humanInputTestConfig(config), secretsKey: secretsKey, models: models, body)
}

func withHumanInputRunningServer(config: ServerConfig = .defaults,
                                _ body: @Sendable @escaping (API, Int, DocumentRegistry) async throws -> Void) async throws {
    try await withRunningServer(config: humanInputTestConfig(config), body)
}
