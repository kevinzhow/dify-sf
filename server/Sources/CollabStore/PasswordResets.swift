import Foundation
import PostgresNIO

/// A stored password-reset token (only its SHA-256 is kept): Dify's forgot-password token data plus dify-sf's admin links.
public struct StoredPasswordReset: Sendable, Equatable {
    /// nil for an email without an account.
    public var accountId: String?
    public var email: String
    /// SHA-256 of token and code (`verify` only).
    public var codeHash: String?
    /// `verify`, `reset` or `link`.
    public var phase: String
}

/// Forgot password (Dify's `RedisForgotPasswordTokenGateway`, here in Postgres with hashed tokens) and the admins' reset
/// links. Every operation is bounded by `operationTimeout`.
extension PostgresStore {
    /// Stores a new token. Like Dify's per-account "current token", a new email code (`verify`) replaces every earlier
    /// `verify` / `reset` token of the email, and a new admin link (`link`) every earlier link of the account. Expired tokens
    /// are cleaned up on the way.
    public func issuePasswordReset(tokenHash: String, accountId: String?, email: String, codeHash: String?, phase: String,
                                   createdBy: String?, expiresAt: Date) async throws {
        try await bounded {
            try await self.transaction { tx in
                _ = try await tx.query("DELETE FROM password_resets WHERE expires_at <= now()", logger: self.logger)
                if phase == "link" {
                    _ = try await tx.query("DELETE FROM password_resets WHERE account_id = \(accountId) AND phase = 'link'", logger: self.logger)
                } else {
                    _ = try await tx.query("""
                        DELETE FROM password_resets WHERE lower(email) = \(email.lowercased()) AND phase IN ('verify', 'reset')
                        """, logger: self.logger)
                }
                _ = try await tx.query("""
                    INSERT INTO password_resets (token_hash, account_id, email, code_hash, phase, created_by, expires_at)
                    VALUES (\(tokenHash), \(accountId), \(email), \(codeHash), \(phase), \(createdBy), \(expiresAt))
                    """, logger: self.logger)
            }
        }
    }

    /// The unexpired token of `phase`, or nil.
    public func passwordReset(tokenHash: String, phase: String) async throws -> StoredPasswordReset? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT account_id, email, code_hash, phase FROM password_resets
                WHERE token_hash = \(tokenHash) AND phase = \(phase) AND expires_at > now()
                """, logger: self.logger)
            for try await r in rows.decode((String?, String, String?, String).self) {
                return StoredPasswordReset(accountId: r.0, email: r.1, codeHash: r.2, phase: r.3)
            }
            return nil
        }
    }

    /// Dify's `promote`: spends the unexpired `verify` token and stores a `reset` token for the same email in its place
    /// (valid until `expiresAt`). False if the `verify` token is gone (used, replaced or expired).
    public func promotePasswordReset(oldHash: String, newHash: String, expiresAt: Date) async throws -> Bool {
        try await bounded {
            try await self.transaction { tx in
                var found: (String?, String)?
                for try await r in try await tx.query("""
                    DELETE FROM password_resets WHERE token_hash = \(oldHash) AND phase = 'verify' AND expires_at > now()
                    RETURNING account_id, email
                    """, logger: self.logger).decode((String?, String).self) {
                    found = r
                }
                guard let (account, email) = found else { return false }
                _ = try await tx.query("""
                    INSERT INTO password_resets (token_hash, account_id, email, phase, expires_at)
                    VALUES (\(newHash), \(account), \(email), 'reset', \(expiresAt))
                    """, logger: self.logger)
                return true
            }
        }
    }

    /// Dify's `claim_reset`: spends an unexpired `reset` token or admin `link` and returns it; nil if there is none.
    public func claimPasswordReset(tokenHash: String) async throws -> StoredPasswordReset? {
        try await bounded {
            let rows = try await self.client.query("""
                DELETE FROM password_resets WHERE token_hash = \(tokenHash) AND phase IN ('reset', 'link') AND expires_at > now()
                RETURNING account_id, email, code_hash, phase
                """, logger: self.logger)
            for try await r in rows.decode((String?, String, String?, String).self) {
                return StoredPasswordReset(accountId: r.0, email: r.1, codeHash: r.2, phase: r.3)
            }
            return nil
        }
    }

    /// Sets the account's new password in one transaction with what goes with it: every session of the account is revoked,
    /// every other reset token and link of the account is spent, and an invited account that had not activated yet becomes
    /// active (the password is its way in, as Dify activates a pending account at its first sign-in). False if the account
    /// does not exist.
    public func resetPassword(accountId: String, hash: String, salt: String) async throws -> Bool {
        try await bounded {
            try await self.transaction { tx in
                var updated = false
                for try await _ in try await tx.query("""
                    UPDATE accounts SET password_hash = \(hash), password_salt = \(salt),
                           status = CASE WHEN status = 'pending' THEN 'active' ELSE status END
                    WHERE id = \(accountId) RETURNING id
                    """, logger: self.logger) {
                    updated = true
                }
                guard updated else { return false }
                _ = try await tx.query("DELETE FROM sessions WHERE account_id = \(accountId)", logger: self.logger)
                _ = try await tx.query("DELETE FROM password_resets WHERE account_id = \(accountId)", logger: self.logger)
                return true
            }
        }
    }
}
