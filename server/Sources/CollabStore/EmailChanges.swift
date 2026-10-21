import Foundation
import PostgresNIO

/// A stored change-email token (protocol 1.12; only its SHA-256 is kept): Dify's `ChangeEmailTokenData`.
public struct StoredEmailChange: Sendable, Equatable {
    public var accountId: String
    /// The address the code went to (the account's own for `old_email`, the new one for `new_email`).
    public var email: String
    /// The account's address when the change began.
    public var oldEmail: String
    /// SHA-256 of token and code (`old_email`, `new_email` only).
    public var codeHash: String?
    /// `old_email`, `old_email_verified`, `new_email` or `new_email_verified`.
    public var phase: String
}

/// The outcome of [PostgresStore.changeEmail].
public enum EmailChangeOutcome: Sendable, Equatable {
    case changed(StoredAccount)
    /// Another account has the new address (ignoring case).
    case emailInUse
    /// The account is gone, or its address is no longer the one the change began with.
    case notFound
}

/// Changing the account's email (protocol 1.12; Dify's `TokenManager` tokens of type `change_email`, here in Postgres with
/// hashed tokens). Every operation is bounded by `operationTimeout`.
extension PostgresStore {
    /// Stores a new token for the account. Like Dify's one "current token" per account and type, it replaces every earlier
    /// change-email token of the account. Expired tokens are cleaned up on the way.
    public func issueEmailChange(tokenHash: String, accountId: String, email: String, oldEmail: String, codeHash: String?,
                                 phase: String, expiresAt: Date) async throws {
        try await bounded {
            try await self.transaction { tx in
                _ = try await tx.query("DELETE FROM email_changes WHERE expires_at <= now() OR account_id = \(accountId)", logger: self.logger)
                _ = try await tx.query("""
                    INSERT INTO email_changes (token_hash, account_id, email, old_email, code_hash, phase, expires_at)
                    VALUES (\(tokenHash), \(accountId), \(email), \(oldEmail), \(codeHash), \(phase), \(expiresAt))
                    """, logger: self.logger)
            }
        }
    }

    /// The unexpired token, or nil.
    public func emailChange(tokenHash: String) async throws -> StoredEmailChange? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT account_id, email, old_email, code_hash, phase FROM email_changes
                WHERE token_hash = \(tokenHash) AND expires_at > now()
                """, logger: self.logger)
            for try await r in rows.decode((String, String, String, String?, String).self) {
                return StoredEmailChange(accountId: r.0, email: r.1, oldEmail: r.2, codeHash: r.3, phase: r.4)
            }
            return nil
        }
    }

    /// Dify's `promote`: spends the unexpired token of `phase` (`old_email` or `new_email`) and stores `<phase>_verified`
    /// for the same addresses in its place (and in place of every other token of the account). False if it is gone.
    public func promoteEmailChange(oldHash: String, phase: String, newHash: String, expiresAt: Date) async throws -> Bool {
        try await bounded {
            try await self.transaction { tx in
                var found: (String, String, String)?
                for try await r in try await tx.query("""
                    DELETE FROM email_changes WHERE token_hash = \(oldHash) AND phase = \(phase) AND expires_at > now()
                    RETURNING account_id, email, old_email
                    """, logger: self.logger).decode((String, String, String).self) {
                    found = r
                }
                guard let (account, email, old) = found else { return false }
                _ = try await tx.query("DELETE FROM email_changes WHERE account_id = \(account)", logger: self.logger)
                _ = try await tx.query("""
                    INSERT INTO email_changes (token_hash, account_id, email, old_email, phase, expires_at)
                    VALUES (\(newHash), \(account), \(email), \(old), \(phase + "_verified"), \(expiresAt))
                    """, logger: self.logger)
                return true
            }
        }
    }

    /// Dify's `reset_email`: in one transaction, spends the account's unexpired `new_email_verified` token for `newEmail`
    /// and changes the address, if the account still has `expectedOldEmail` and nobody else has `newEmail` (ignoring
    /// case). Nil if there is no such token (the token stays when another account has the address).
    public func changeEmail(tokenHash: String, accountId: String, newEmail: String) async throws -> EmailChangeOutcome? {
        try await bounded {
            try await self.transaction { tx in
                var token: (String, String)?
                for try await r in try await tx.query("""
                    SELECT email, old_email FROM email_changes
                    WHERE token_hash = \(tokenHash) AND account_id = \(accountId) AND phase = 'new_email_verified' AND expires_at > now()
                    FOR UPDATE
                    """, logger: self.logger).decode((String, String).self) {
                    token = r
                }
                guard let (email, old) = token, email.lowercased() == newEmail.lowercased() else { return nil }
                // Serialises changes to the same address (the unique index is on lower(email) only through this check).
                _ = try await tx.query("SELECT pg_advisory_xact_lock(7318006)", logger: self.logger)
                var taken = false
                for try await _ in try await tx.query("""
                    SELECT 1 FROM accounts WHERE lower(email) = \(newEmail.lowercased()) AND id <> \(accountId)
                    """, logger: self.logger) {
                    taken = true
                }
                if taken { return .emailInUse }
                var updated = false
                for try await _ in try await tx.query("""
                    UPDATE accounts SET email = \(newEmail) WHERE id = \(accountId) AND lower(email) = \(old.lowercased()) RETURNING id
                    """, logger: self.logger) {
                    updated = true
                }
                guard updated else { return .notFound }
                _ = try await tx.query("DELETE FROM email_changes WHERE account_id = \(accountId)", logger: self.logger)
                // Reset codes and links went to (or name) the old address.
                _ = try await tx.query("DELETE FROM password_resets WHERE account_id = \(accountId)", logger: self.logger)
                return .changed(try await self.accountImpl(tx, id: accountId))
            }
        }
    }

    /// Whether an account has this address (ignoring case).
    public func emailExists(_ email: String) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query("SELECT 1 FROM accounts WHERE lower(email) = \(email.lowercased())",
                                                           logger: self.logger) {
                return true
            }
            return false
        }
    }

    /// Dify's `PATCH /account/profile`: sets the given fields (nil = unchanged) and answers the account; nil if it is gone.
    public func updateProfile(_ id: String, name: String?, interfaceLanguage: String?, timezone: String?, avatar: String? = nil, avatarWorkspace: String? = nil) async throws -> StoredAccount? {
        try await bounded {
            var found = false
            for try await _ in try await self.client.query("""
                UPDATE accounts SET name = COALESCE(\(name), name), interface_language = COALESCE(\(interfaceLanguage), interface_language),
                       timezone = COALESCE(\(timezone), timezone),
                       avatar_url = CASE WHEN \(avatar)::text = '' THEN NULL ELSE COALESCE(\(avatar), avatar_url) END
                WHERE id = \(id) AND (\(avatar)::text IS NULL OR \(avatar) = '' OR EXISTS (
                    SELECT 1 FROM upload_files WHERE id = \(avatar) AND workspace_id = \(avatarWorkspace) AND ready
                        AND created_by_role = 'account' AND created_by = \(id)))
                RETURNING id
                """, logger: self.logger) {
                found = true
            }
            return found ? try await self.accountImpl(where: "a.id", id) : nil
        }
    }

    func accountImpl(_ tx: PostgresConnection, id: String) async throws -> StoredAccount {
        let rows = try await tx.query("""
            SELECT \(unescaped: Self.accountColumns) FROM accounts a LEFT JOIN members m ON m.account_id = a.id WHERE a.id = \(id)
            """, logger: logger)
        for try await r in rows.decode(AccountRow.self) { return Self.account(r) }
        throw AccountStoreError.notFound
    }
}
