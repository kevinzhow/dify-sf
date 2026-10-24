import Foundation

/// Server-scoped workspace credentials. Private credentials remain available only to their creator.
public struct StoredToolCredential: Sendable {
    public var id: String
    public var name: String
    public var provider: String
    public var createdBy: String
    public var shared: Bool
    public var config: String?
}

extension PostgresStore {
    public func toolCredentials(provider: String? = nil, viewer: String) async throws -> [StoredToolCredential] {
        try await bounded {
            var values: [StoredToolCredential] = []
            for try await (id, name, p, owner, shared, sealed) in try await self.client.query("""
                SELECT id, name, provider, created_by, shared, encrypted_config FROM tool_provider_credentials
                WHERE (shared OR created_by = \(viewer)) ORDER BY created_at DESC, id
                """, logger: self.logger).decode((String, String, String, String, Bool, String).self) {
                if provider == nil || provider == p {
                    values.append(StoredToolCredential(id: id, name: name, provider: p, createdBy: owner, shared: shared,
                                                      config: self.openCredential("tool_provider_credentials", id, sealed)))
                }
            }
            return values
        }
    }

    public func saveToolCredential(provider: String, id existingID: String? = nil, name: String, config: String, userId: String, shared: Bool) async throws -> String {
        let id = existingID ?? UUID().uuidString.lowercased()
        let sealed = try sealCredential("tool_provider_credentials", id, config)
        return try await modelsTransaction { tx in
            if existingID != nil {
                var owner: String?
                for try await value in try await tx.query("SELECT created_by FROM tool_provider_credentials WHERE id = \(id) AND provider = \(provider) FOR UPDATE", logger: self.logger).decode(String.self) { owner = value }
                guard owner == userId else { throw ModelStoreError.notFound("Tool credential not found") }
                _ = try await tx.query("UPDATE tool_provider_credentials SET name = \(name), encrypted_config = \(sealed), shared = \(shared) WHERE id = \(id)", logger: self.logger)
            } else {
                _ = try await tx.query("""
                    INSERT INTO tool_provider_credentials(id, provider, name, encrypted_config, created_by, shared)
                    VALUES (\(id), \(provider), \(name), \(sealed), \(userId), \(shared))
                    """, logger: self.logger)
            }
            return id
        }
    }

    public func deleteToolCredential(provider: String, id: String, userId: String) async throws {
        try await modelsTransaction { tx in
            var found = false
            for try await _ in try await tx.query("DELETE FROM tool_provider_credentials WHERE id = \(id) AND provider = \(provider) AND created_by = \(userId) RETURNING id", logger: self.logger).decode(String.self) { found = true }
            if !found { throw ModelStoreError.notFound("Tool credential not found") }
        }
    }
}
