import Foundation
import PostgresNIO

/// (provider, model, model type): a custom model, or the target of a model setting.
public struct ModelKey: Hashable, Sendable {
    public var provider: String
    public var model: String
    public var modelType: String
    public init(provider: String, model: String, modelType: String) {
        self.provider = provider
        self.model = model
        self.modelType = modelType
    }
}

/// A stored credential. `config` is the decrypted credential JSON (UTF-8 text), nil when it cannot be decrypted (no key,
/// or another key than the one it was sealed with).
public struct StoredModelCredential: Sendable, Equatable {
    public var id: String
    public var name: String
    public var config: String?
    public var createdAt: Date
}

/// Everything stored about model providers (small: read whole, in one consistent snapshot).
public struct ModelProviderState: Sendable {
    /// provider id -> its credentials, newest first (Dify's order).
    public var providerCredentials: [String: [StoredModelCredential]] = [:]
    /// Providers with a settings row (Dify's custom `providers` row: while the provider has credentials).
    public var configuredProviders: Set<String> = []
    /// provider id -> its current credential (absent: none chosen, e.g. the current one was deleted).
    public var currentCredential: [String: String] = [:]
    /// custom model -> its credentials, newest first.
    public var modelCredentials: [ModelKey: [StoredModelCredential]] = [:]
    /// Custom models in the model list, in the order they were added.
    public var customModelOrder: [ModelKey] = []
    /// custom model -> its current credential (absent: none, Dify's `credential-removed`).
    public var customModelCredential: [ModelKey: String] = [:]
    /// Enabled/disabled settings.
    public var modelSettings: [ModelKey: Bool] = [:]
    /// model type -> (provider, model).
    public var defaults: [String: (provider: String, model: String)] = [:]
    public init() {}
}

public enum ModelStoreError: Error, Sendable, Equatable {
    case notFound(String)
    case nameTaken(String)
    case invalid(String)
}

/// Model provider settings and credentials (protocol 1.9). Credentials are sealed with the store's `cipher` (whole JSON,
/// context `provider_credentials:<id>` / `provider_model_credentials:<id>`); without a cipher every credential write
/// throws `SecretsKeyMissing`. Writes are serialised by one advisory lock (they are rare).
extension PostgresStore {
    static let modelsLock = 7318006

    func sealCredential(_ table: String, _ id: String, _ json: String) throws -> String {
        guard let cipher else { throw SecretsKeyMissing() }
        return try cipher.seal(json, context: "\(table):\(id)")
    }

    func openCredential(_ table: String, _ id: String, _ sealed: String) -> String? {
        guard let cipher else { return nil }
        do { return try cipher.open(sealed, context: "\(table):\(id)") } catch {
            logger.warning("credential \(id) (\(table)) cannot be decrypted with the configured key")
            return nil
        }
    }

    /// A transaction whose `ModelStoreError`/`SecretsKeyMissing` come out as themselves, under the model provider lock.
    func modelsTransaction<T: Sendable>(_ body: @escaping @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        try await bounded {
            do {
                return try await self.client.withTransaction(logger: self.logger) { tx in
                    _ = try await tx.query("SELECT pg_advisory_xact_lock(\(Self.modelsLock))", logger: self.logger)
                    return try await body(tx)
                }
            } catch let e as PostgresTransactionError {
                if let inner = e.closureError as? ModelStoreError { throw inner }
                if let inner = e.closureError as? SecretsKeyMissing { throw inner }
                throw e
            }
        }
    }

    // MARK: - Read

    public func modelProviderState() async throws -> ModelProviderState {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                _ = try await tx.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", logger: self.logger)
                var s = ModelProviderState()
                for try await (id, provider, name, config, created) in try await tx.query("""
                    SELECT id, provider, name, encrypted_config, created_at FROM provider_credentials ORDER BY created_at DESC, id DESC
                    """, logger: self.logger).decode((String, String, String, String, Date).self) {
                    s.providerCredentials[provider, default: []].append(
                        StoredModelCredential(id: id, name: name, config: self.openCredential("provider_credentials", id, config), createdAt: created))
                }
                for try await (provider, current) in try await tx.query("SELECT provider, current_credential_id FROM provider_settings",
                                                                         logger: self.logger).decode((String, String?).self) {
                    s.configuredProviders.insert(provider)
                    if let current { s.currentCredential[provider] = current }
                }
                for try await (id, provider, model, type, name, config, created) in try await tx.query("""
                    SELECT id, provider, model, model_type, name, encrypted_config, created_at FROM provider_model_credentials
                    ORDER BY created_at DESC, id DESC
                    """, logger: self.logger).decode((String, String, String, String, String, String, Date).self) {
                    s.modelCredentials[ModelKey(provider: provider, model: model, modelType: type), default: []].append(
                        StoredModelCredential(id: id, name: name, config: self.openCredential("provider_model_credentials", id, config),
                                              createdAt: created))
                }
                for try await (provider, model, type, current) in try await tx.query("""
                    SELECT provider, model, model_type, current_credential_id FROM provider_models ORDER BY created_at, model
                    """, logger: self.logger).decode((String, String, String, String?).self) {
                    let key = ModelKey(provider: provider, model: model, modelType: type)
                    s.customModelOrder.append(key)
                    if let current { s.customModelCredential[key] = current }
                }
                for try await (provider, model, type, enabled) in try await tx.query("""
                    SELECT provider, model, model_type, enabled FROM provider_model_settings
                    """, logger: self.logger).decode((String, String, String, Bool).self) {
                    s.modelSettings[ModelKey(provider: provider, model: model, modelType: type)] = enabled
                }
                for try await (type, provider, model) in try await tx.query("SELECT model_type, provider, model FROM default_models",
                                                                             logger: self.logger).decode((String, String, String).self) {
                    s.defaults[type] = (provider, model)
                }
                return s
            }
        }
    }

    // MARK: - Provider credentials

    /// Dify's `_generate_next_api_key_name`: "API KEY <highest n + 1>".
    static func nextKeyName(_ names: [String]) -> String {
        let numbers = names.compactMap { name -> Int? in
            let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3, parts[0] == "API", parts[1] == "KEY" else { return nil }
            return Int(parts[2])
        }
        return "API KEY \((numbers.max() ?? 0) + 1)"
    }

    /// Dify's `create_provider_credential`: a new credential (named `name`, or the next "API KEY n"); it becomes the current
    /// one when the provider has none. Returns its id.
    public func createProviderCredential(provider: String, name: String?, config: String, createdBy: String?) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let sealed = try sealCredential("provider_credentials", id, config)
        return try await modelsTransaction { tx in
            var names: [String] = []
            for try await n in try await tx.query("SELECT name FROM provider_credentials WHERE provider = \(provider)", logger: self.logger)
                .decode(String.self) { names.append(n) }
            if let name, names.contains(name) { throw ModelStoreError.nameTaken("Credential with name '\(name)' already exists.") }
            let finalName = name ?? Self.nextKeyName(names)
            _ = try await tx.query("""
                INSERT INTO provider_credentials (id, provider, name, encrypted_config, created_by)
                VALUES (\(id), \(provider), \(finalName), \(sealed), \(createdBy))
                """, logger: self.logger)
            _ = try await tx.query("""
                INSERT INTO provider_settings (provider, current_credential_id) VALUES (\(provider), \(id))
                ON CONFLICT (provider) DO UPDATE SET current_credential_id = COALESCE(provider_settings.current_credential_id, EXCLUDED.current_credential_id),
                    updated_at = now()
                """, logger: self.logger)
            return id
        }
    }

    /// The decrypted config of one credential (for `[__HIDDEN__]`), `notFound` if it is not the provider's.
    public func providerCredential(provider: String, id: String) async throws -> StoredModelCredential {
        try await bounded {
            for try await (name, config, created) in try await self.client.query("""
                SELECT name, encrypted_config, created_at FROM provider_credentials WHERE provider = \(provider) AND id = \(id)
                """, logger: self.logger).decode((String, String, Date).self) {
                return StoredModelCredential(id: id, name: name, config: self.openCredential("provider_credentials", id, config), createdAt: created)
            }
            throw ModelStoreError.notFound("Credential record not found.")
        }
    }

    public func updateProviderCredential(provider: String, id: String, name: String?, config: String) async throws {
        let sealed = try sealCredential("provider_credentials", id, config)
        try await modelsTransaction { tx in
            if let name {
                for try await _ in try await tx.query("""
                    SELECT 1 FROM provider_credentials WHERE provider = \(provider) AND name = \(name) AND id <> \(id)
                    """, logger: self.logger) { throw ModelStoreError.nameTaken("Credential with name '\(name)' already exists.") }
            }
            var found = false
            for try await _ in try await tx.query("""
                UPDATE provider_credentials SET encrypted_config = \(sealed), name = COALESCE(\(name), name), updated_at = now()
                WHERE provider = \(provider) AND id = \(id) RETURNING id
                """, logger: self.logger) { found = true }
            if !found { throw ModelStoreError.notFound("Credential record not found.") }
        }
    }

    /// Dify's `delete_provider_credential`: the last credential takes the provider's settings row with it; deleting the
    /// current one leaves the provider without a current credential.
    public func deleteProviderCredential(provider: String, id: String) async throws {
        try await modelsTransaction { tx in
            var count = 0
            for try await n in try await tx.query("SELECT count(*)::bigint FROM provider_credentials WHERE provider = \(provider)", logger: self.logger)
                .decode(Int.self) { count = n }
            var found = false
            for try await _ in try await tx.query("DELETE FROM provider_credentials WHERE provider = \(provider) AND id = \(id) RETURNING id",
                                                  logger: self.logger) { found = true }
            guard found else { throw ModelStoreError.notFound("Credential record not found.") }
            if count <= 1 {
                _ = try await tx.query("DELETE FROM provider_settings WHERE provider = \(provider)", logger: self.logger)
            } else {
                _ = try await tx.query("""
                    UPDATE provider_settings SET current_credential_id = NULL, updated_at = now()
                    WHERE provider = \(provider) AND current_credential_id = \(id)
                    """, logger: self.logger)
            }
        }
    }

    public func switchProviderCredential(provider: String, id: String) async throws {
        try await modelsTransaction { tx in
            var found = false
            for try await _ in try await tx.query("SELECT 1 FROM provider_credentials WHERE provider = \(provider) AND id = \(id)", logger: self.logger) {
                found = true
            }
            guard found else { throw ModelStoreError.notFound("Credential record not found.") }
            var updated = false
            for try await _ in try await tx.query("""
                UPDATE provider_settings SET current_credential_id = \(id), updated_at = now() WHERE provider = \(provider) RETURNING provider
                """, logger: self.logger) { updated = true }
            if !updated { throw ModelStoreError.notFound("Provider record not found.") }
        }
    }

    // MARK: - Custom model credentials

    /// Dify's `create_custom_model_credential`: the model joins the model list (with this credential) if it is not there.
    public func createModelCredential(_ key: ModelKey, name: String?, config: String, createdBy: String?) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let sealed = try sealCredential("provider_model_credentials", id, config)
        return try await modelsTransaction { tx in
            var names: [String] = []
            for try await n in try await tx.query("""
                SELECT name FROM provider_model_credentials WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType)
                """, logger: self.logger).decode(String.self) { names.append(n) }
            if let name, names.contains(name) {
                throw ModelStoreError.nameTaken("Model credential with name '\(name)' already exists for \(key.model).")
            }
            let finalName = name ?? Self.nextKeyName(names)
            _ = try await tx.query("""
                INSERT INTO provider_model_credentials (id, provider, model, model_type, name, encrypted_config, created_by)
                VALUES (\(id), \(key.provider), \(key.model), \(key.modelType), \(finalName), \(sealed), \(createdBy))
                """, logger: self.logger)
            _ = try await tx.query("""
                INSERT INTO provider_models (provider, model, model_type, current_credential_id)
                VALUES (\(key.provider), \(key.model), \(key.modelType), \(id)) ON CONFLICT DO NOTHING
                """, logger: self.logger)
            return id
        }
    }

    public func modelCredential(_ key: ModelKey, id: String) async throws -> StoredModelCredential {
        try await bounded {
            for try await (name, config, created) in try await self.client.query("""
                SELECT name, encrypted_config, created_at FROM provider_model_credentials
                WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) AND id = \(id)
                """, logger: self.logger).decode((String, String, Date).self) {
                return StoredModelCredential(id: id, name: name, config: self.openCredential("provider_model_credentials", id, config), createdAt: created)
            }
            throw ModelStoreError.notFound("Credential record not found.")
        }
    }

    public func updateModelCredential(_ key: ModelKey, id: String, name: String?, config: String) async throws {
        let sealed = try sealCredential("provider_model_credentials", id, config)
        try await modelsTransaction { tx in
            if let name {
                for try await _ in try await tx.query("""
                    SELECT 1 FROM provider_model_credentials
                    WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) AND name = \(name) AND id <> \(id)
                    """, logger: self.logger) {
                    throw ModelStoreError.nameTaken("Model credential with name '\(name)' already exists for \(key.model).")
                }
            }
            var found = false
            for try await _ in try await tx.query("""
                UPDATE provider_model_credentials SET encrypted_config = \(sealed), name = COALESCE(\(name), name), updated_at = now()
                WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) AND id = \(id) RETURNING id
                """, logger: self.logger) { found = true }
            if !found { throw ModelStoreError.notFound("Credential record not found.") }
        }
    }

    /// Dify's `delete_custom_model_credential`: the model's last credential takes the model out of the list; deleting its
    /// current one leaves it without (Dify's `credential-removed`).
    public func deleteModelCredential(_ key: ModelKey, id: String) async throws {
        try await modelsTransaction { tx in
            var count = 0
            for try await n in try await tx.query("""
                SELECT count(*)::bigint FROM provider_model_credentials
                WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType)
                """, logger: self.logger).decode(Int.self) { count = n }
            var found = false
            for try await _ in try await tx.query("""
                DELETE FROM provider_model_credentials
                WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) AND id = \(id) RETURNING id
                """, logger: self.logger) { found = true }
            guard found else { throw ModelStoreError.notFound("Credential record not found.") }
            if count <= 1 {
                _ = try await tx.query("""
                    DELETE FROM provider_models WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType)
                    """, logger: self.logger)
            } else {
                _ = try await tx.query("""
                    UPDATE provider_models SET current_credential_id = NULL, updated_at = now()
                    WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) AND current_credential_id = \(id)
                    """, logger: self.logger)
            }
        }
    }

    /// Dify's `add_model_credential_to_model` (`POST .../models/credentials/switch`): adds the model with this credential, or
    /// makes it the model's current one (`invalid` if it already is).
    public func addModelCredentialToModel(_ key: ModelKey, id: String) async throws {
        try await modelsTransaction { tx in
            try await self.requireModelCredential(tx, key, id)
            var exists = false
            var current: String?
            for try await c in try await tx.query("""
                SELECT current_credential_id FROM provider_models
                WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) FOR UPDATE
                """, logger: self.logger).decode(String?.self) {
                exists = true
                current = c
            }
            if !exists {
                _ = try await tx.query("""
                    INSERT INTO provider_models (provider, model, model_type, current_credential_id) VALUES (\(key.provider), \(key.model), \(key.modelType), \(id))
                    """, logger: self.logger)
            } else if current == id {
                throw ModelStoreError.invalid("Can't add same credential")
            } else {
                _ = try await tx.query("""
                    UPDATE provider_models SET current_credential_id = \(id), updated_at = now()
                    WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType)
                    """, logger: self.logger)
            }
        }
    }

    /// Dify's `switch_custom_model_credential` (`POST .../models` with `config_from: custom-model`): the model must be in the
    /// list.
    public func switchCustomModelCredential(_ key: ModelKey, id: String) async throws {
        try await modelsTransaction { tx in
            try await self.requireModelCredential(tx, key, id)
            var updated = false
            for try await _ in try await tx.query("""
                UPDATE provider_models SET current_credential_id = \(id), updated_at = now()
                WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) RETURNING model
                """, logger: self.logger) { updated = true }
            if !updated { throw ModelStoreError.notFound("The custom model record not found.") }
        }
    }

    func requireModelCredential(_ tx: PostgresConnection, _ key: ModelKey, _ id: String) async throws {
        for try await _ in try await tx.query("""
            SELECT 1 FROM provider_model_credentials
            WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType) AND id = \(id)
            """, logger: logger) { return }
        throw ModelStoreError.notFound("Credential record not found.")
    }

    /// Dify's `delete_custom_model`: out of the list (its credentials stay).
    public func deleteCustomModel(_ key: ModelKey) async throws {
        try await modelsTransaction { tx in
            _ = try await tx.query("""
                DELETE FROM provider_models WHERE provider = \(key.provider) AND model = \(key.model) AND model_type = \(key.modelType)
                """, logger: self.logger)
        }
    }

    // MARK: - Settings and defaults

    public func setModelEnabled(_ key: ModelKey, _ enabled: Bool) async throws {
        try await modelsTransaction { tx in
            _ = try await tx.query("""
                INSERT INTO provider_model_settings (provider, model, model_type, enabled) VALUES (\(key.provider), \(key.model), \(key.modelType), \(enabled))
                ON CONFLICT (provider, model, model_type) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now()
                """, logger: self.logger)
        }
    }

    public func setDefaultModel(type: String, provider: String, model: String) async throws {
        try await modelsTransaction { tx in
            _ = try await tx.query("""
                INSERT INTO default_models (model_type, provider, model) VALUES (\(type), \(provider), \(model))
                ON CONFLICT (model_type) DO UPDATE SET provider = EXCLUDED.provider, model = EXCLUDED.model, updated_at = now()
                """, logger: self.logger)
        }
    }

    /// Stores (provider, model) as the default of `type` unless one exists; answers the stored default either way (Dify's
    /// "pick the first available model and save it", race-free).
    public func defaultModelIfAbsent(type: String, provider: String, model: String) async throws -> (provider: String, model: String) {
        try await modelsTransaction { tx in
            _ = try await tx.query("""
                INSERT INTO default_models (model_type, provider, model) VALUES (\(type), \(provider), \(model)) ON CONFLICT (model_type) DO NOTHING
                """, logger: self.logger)
            for try await (p, m) in try await tx.query("SELECT provider, model FROM default_models WHERE model_type = \(type)", logger: self.logger)
                .decode((String, String).self) { return (p, m) }
            return (provider, model)
        }
    }
}
