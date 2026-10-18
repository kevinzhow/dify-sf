import Foundation
import PostgresNIO

/// An account with its workspace role (protocol 1.8; Dify's `Account` + `TenantAccountJoin`). `role` is nil for an account
/// that is no longer a member.
public struct StoredAccount: Sendable, Equatable {
    public var id: String
    public var email: String
    public var name: String
    public var avatarUrl: String?
    public var passwordHash: String?
    public var passwordSalt: String?
    /// `active`, `pending` (invited, not activated yet) or `banned`.
    public var status: String
    public var interfaceLanguage: String?
    public var timezone: String?
    public var createdAt: Date
    public var lastLoginAt: Date?
    public var role: String?
}

/// The caller of a request, as found through its access token.
public struct StoredPrincipal: Sendable, Equatable {
    public var account: StoredAccount
    /// Groups every token of one sign-in (logout revokes them all).
    public var sessionId: String
}

/// One bearer token to store (only its SHA-256 is kept).
public struct NewToken: Sendable {
    public var hash: String
    public var kind: String
    public var expiresAt: Date
    public init(hash: String, kind: String, expiresAt: Date) {
        self.hash = hash
        self.kind = kind
        self.expiresAt = expiresAt
    }
}

public enum AccountStoreError: Error, Sendable, Equatable {
    /// `POST /setup` after an account exists.
    case setupDone
    /// Another account has this email (ignoring case).
    case emailTaken
    case notFound
}

/// Outcome of inviting one email.
public enum InviteOutcome: Sendable, Equatable {
    case invited(accountId: String)
    case alreadyMember
}

/// What an activation token refers to.
public struct StoredInvitation: Sendable, Equatable {
    public var accountId: String
    public var email: String
    public var role: String
    /// The account has a password already (activated, or it signed in with the invitation): the link is spent.
    public var accountActive: Bool
}

/// Accounts, members, sessions, invitations and client bindings (protocol 1.8). Plain SQL; every operation is bounded by
/// `operationTimeout`.
extension PostgresStore {
    static let accountColumns = """
        a.id, a.email, a.name, a.avatar_url, a.password_hash, a.password_salt, a.status, a.interface_language, a.timezone,
        a.created_at, a.last_login_at, m.role
        """

    typealias AccountRow = (String, String, String, String?, String?, String?, String, String?, String?, Date, Date?, String?)

    static func account(_ r: AccountRow) -> StoredAccount {
        StoredAccount(id: r.0, email: r.1, name: r.2, avatarUrl: r.3, passwordHash: r.4, passwordSalt: r.5, status: r.6,
                      interfaceLanguage: r.7, timezone: r.8, createdAt: r.9, lastLoginAt: r.10, role: r.11)
    }

    /// A transaction whose `AccountStoreError`s come out as themselves (postgres-nio wraps errors of the closure).
    func transaction<T: Sendable>(_ body: @escaping @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        do {
            return try await client.withTransaction(logger: logger) { try await body($0) }
        } catch let e as PostgresTransactionError {
            if let inner = e.closureError as? AccountStoreError { throw inner }
            throw e
        }
    }

    // MARK: - Setup

    public func accountCount() async throws -> Int {
        try await bounded {
            for try await n in try await self.client.query("SELECT count(*)::bigint FROM accounts", logger: self.logger).decode(Int.self) {
                return n
            }
            return 0
        }
    }

    /// Dify's install: creates the first account as the workspace owner, only while no account exists (`setupDone`
    /// otherwise; concurrent installs are serialised by an advisory lock).
    public func createOwner(id: String, email: String, name: String, passwordHash: String, passwordSalt: String,
                            interfaceLanguage: String?, timezone: String?) async throws -> StoredAccount {
        try await bounded {
            try await self.transaction { tx in
                _ = try await tx.query("SELECT pg_advisory_xact_lock(7318005)", logger: self.logger)
                var count = 0
                for try await n in try await tx.query("SELECT count(*)::bigint FROM accounts", logger: self.logger).decode(Int.self) { count = n }
                guard count == 0 else { throw AccountStoreError.setupDone }
                _ = try await tx.query("""
                    INSERT INTO accounts (id, email, name, password_hash, password_salt, status, interface_language, timezone, last_login_at)
                    VALUES (\(id), \(email), \(name), \(passwordHash), \(passwordSalt), 'active', \(interfaceLanguage), \(timezone), now())
                    """, logger: self.logger)
                _ = try await tx.query("INSERT INTO members (account_id, role) VALUES (\(id), 'owner')", logger: self.logger)
            }
            guard let a = try await self.accountImpl(where: "a.id", id) else { throw AccountStoreError.notFound }
            return a
        }
    }

    // MARK: - Accounts

    public func account(id: String) async throws -> StoredAccount? {
        try await bounded { try await self.accountImpl(where: "a.id", id) }
    }

    /// Case-insensitive.
    public func account(email: String) async throws -> StoredAccount? {
        try await bounded { try await self.accountImpl(where: "lower(a.email)", email.lowercased()) }
    }

    func accountImpl(where column: String, _ value: String) async throws -> StoredAccount? {
        let sql = "SELECT \(Self.accountColumns) FROM accounts a LEFT JOIN members m ON m.account_id = a.id WHERE \(column) = $1"
        var bindings = PostgresBindings()
        bindings.append(value)
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql, binds: bindings), logger: logger)
        for try await r in rows.decode(AccountRow.self) { return Self.account(r) }
        return nil
    }

    /// Every account that is a member, owner first, then by creation (Dify's member list).
    public func members() async throws -> [StoredAccount] {
        try await bounded {
            var out: [StoredAccount] = []
            let rows = try await self.client.query("""
                SELECT a.id, a.email, a.name, a.avatar_url, a.password_hash, a.password_salt, a.status, a.interface_language,
                       a.timezone, a.created_at, a.last_login_at, m.role
                FROM accounts a JOIN members m ON m.account_id = a.id
                ORDER BY (m.role = 'owner') DESC, m.created_at, a.id
                """, logger: self.logger)
            for try await r in rows.decode(AccountRow.self) { out.append(Self.account(r)) }
            return out
        }
    }

    /// id -> (name, avatar) of every account (members or not: authors of old comments keep their names).
    public func accountNames() async throws -> [String: (name: String, avatarUrl: String?)] {
        try await bounded {
            var out: [String: (name: String, avatarUrl: String?)] = [:]
            for try await (id, name, avatar) in try await self.client.query("SELECT id, name, avatar_url FROM accounts", logger: self.logger)
                .decode((String, String, String?).self) {
                out[id] = (name, avatar)
            }
            return out
        }
    }

    public func touchLogin(_ id: String) async throws {
        try await bounded { _ = try await self.client.query("UPDATE accounts SET last_login_at = now() WHERE id = \(id)", logger: self.logger) }
    }

    public func updateAccountName(_ id: String, name: String) async throws {
        try await bounded { _ = try await self.client.query("UPDATE accounts SET name = \(name) WHERE id = \(id)", logger: self.logger) }
    }

    public func updatePassword(_ id: String, hash: String, salt: String) async throws {
        try await bounded {
            _ = try await self.client.query("UPDATE accounts SET password_hash = \(hash), password_salt = \(salt) WHERE id = \(id)", logger: self.logger)
        }
    }

    // MARK: - Sessions

    /// Stores the tokens of one sign-in (or one refresh) under `sessionId`.
    public func storeTokens(_ tokens: [NewToken], account: String, sessionId: String) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO sessions (token_hash, account_id, session_id, kind, expires_at)
                SELECT u.h, \(account), \(sessionId), u.k, u.e FROM unnest(\(tokens.map(\.hash))::text[], \(tokens.map(\.kind))::text[],
                       \(tokens.map(\.expiresAt))::timestamptz[]) AS u(h, k, e)
                """, logger: self.logger)
        }
    }

    /// The member behind an unexpired token of `kind`, or nil (unknown, expired, revoked, not a member any more).
    public func principal(tokenHash: String, kind: String = "access") async throws -> StoredPrincipal? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT a.id, a.email, a.name, a.avatar_url, a.password_hash, a.password_salt, a.status, a.interface_language,
                       a.timezone, a.created_at, a.last_login_at, m.role, s.session_id
                FROM sessions s JOIN accounts a ON a.id = s.account_id JOIN members m ON m.account_id = a.id
                WHERE s.token_hash = \(tokenHash) AND s.kind = \(kind) AND s.expires_at > now()
                """, logger: self.logger)
            for try await r in rows.decode((String, String, String, String?, String?, String?, String, String?, String?, Date, Date?, String?, String).self) {
                let a = Self.account((r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7, r.8, r.9, r.10, r.11))
                return StoredPrincipal(account: a, sessionId: r.12)
            }
            return nil
        }
    }

    /// Refresh-token rotation in one transaction: the old refresh token is consumed (deleted) and the new tokens join its
    /// session. Nil if the old token is unknown, expired or already used.
    public func rotateRefresh(oldHash: String, newTokens: [NewToken]) async throws -> String? {
        try await bounded {
            try await self.transaction { tx in
                var found: (String, String)?
                for try await r in try await tx.query("""
                    DELETE FROM sessions WHERE token_hash = \(oldHash) AND kind = 'refresh' AND expires_at > now()
                    RETURNING account_id, session_id
                    """, logger: self.logger).decode((String, String).self) {
                    found = r
                }
                guard let (account, session) = found else { return nil }
                _ = try await tx.query("""
                    INSERT INTO sessions (token_hash, account_id, session_id, kind, expires_at)
                    SELECT u.h, \(account), \(session), u.k, u.e FROM unnest(\(newTokens.map(\.hash))::text[], \(newTokens.map(\.kind))::text[],
                           \(newTokens.map(\.expiresAt))::timestamptz[]) AS u(h, k, e)
                    """, logger: self.logger)
                // Housekeeping: expired tokens of this account.
                _ = try await tx.query("DELETE FROM sessions WHERE account_id = \(account) AND expires_at <= now()", logger: self.logger)
                return account
            }
        }
    }

    /// Logout: every token of the sign-in.
    public func revokeSession(_ sessionId: String) async throws {
        try await bounded { _ = try await self.client.query("DELETE FROM sessions WHERE session_id = \(sessionId)", logger: self.logger) }
    }

    /// Every token of the account (it was removed from the workspace).
    public func revokeAccountSessions(_ accountId: String) async throws {
        try await bounded { _ = try await self.client.query("DELETE FROM sessions WHERE account_id = \(accountId)", logger: self.logger) }
    }

    // MARK: - Members and invitations

    /// Dify's `invite_new_member`: a new email gets a pending account (no password) and membership; an existing account
    /// that is not a member becomes one again. Either way an invitation token is stored. A current member is
    /// `alreadyMember` (nothing stored).
    public func invite(email: String, newAccountId: String, role: String, invitedBy: String, tokenHash: String,
                       expiresAt: Date) async throws -> InviteOutcome {
        try await bounded {
            try await self.transaction { tx in
                var existing: (String, String?)?
                for try await r in try await tx.query("""
                    SELECT a.id, m.role FROM accounts a LEFT JOIN members m ON m.account_id = a.id WHERE lower(a.email) = \(email.lowercased())
                    FOR UPDATE OF a
                    """, logger: self.logger).decode((String, String?).self) {
                    existing = r
                }
                let accountId: String
                if let (id, memberRole) = existing {
                    if memberRole != nil { return .alreadyMember }
                    accountId = id
                } else {
                    accountId = newAccountId
                    let name = String(email.split(separator: "@").first ?? Substring(email))
                    _ = try await tx.query("""
                        INSERT INTO accounts (id, email, name, status) VALUES (\(accountId), \(email), \(name), 'pending')
                        """, logger: self.logger)
                }
                _ = try await tx.query("""
                    INSERT INTO members (account_id, role, invited_by) VALUES (\(accountId), \(role), \(invitedBy))
                    """, logger: self.logger)
                _ = try await tx.query("""
                    INSERT INTO invitations (token_hash, account_id, email, role, invited_by, expires_at)
                    VALUES (\(tokenHash), \(accountId), \(email), \(role), \(invitedBy), \(expiresAt))
                    """, logger: self.logger)
                return .invited(accountId: accountId)
            }
        }
    }

    /// The unused, unexpired invitation behind a token whose account is still a member; nil otherwise.
    public func invitation(tokenHash: String) async throws -> StoredInvitation? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT i.account_id, a.email, m.role, a.password_hash IS NOT NULL
                FROM invitations i JOIN accounts a ON a.id = i.account_id JOIN members m ON m.account_id = a.id
                WHERE i.token_hash = \(tokenHash) AND i.used_at IS NULL AND i.expires_at > now()
                """, logger: self.logger)
            for try await r in rows.decode((String, String, String, Bool).self) {
                return StoredInvitation(accountId: r.0, email: r.1, role: r.2, accountActive: r.3)
            }
            return nil
        }
    }

    /// Accepts an invitation: sets the pending account's name and password, activates it and spends the token. Nil if the
    /// token is not (any more) valid or the account already has a password.
    public func activate(tokenHash: String, name: String?, passwordHash: String, passwordSalt: String,
                         interfaceLanguage: String?, timezone: String?) async throws -> String? {
        try await bounded {
            try await self.transaction { tx in
                var accountId: String?
                for try await id in try await tx.query("""
                    UPDATE invitations SET used_at = now()
                    WHERE token_hash = \(tokenHash) AND used_at IS NULL AND expires_at > now()
                      AND EXISTS (SELECT 1 FROM members m WHERE m.account_id = invitations.account_id)
                    RETURNING account_id
                    """, logger: self.logger).decode(String.self) {
                    accountId = id
                }
                guard let accountId else { return nil }
                var updated = false
                for try await _ in try await tx.query("""
                    UPDATE accounts SET name = COALESCE(\(name), name), password_hash = \(passwordHash), password_salt = \(passwordSalt),
                           status = 'active', interface_language = COALESCE(\(interfaceLanguage), interface_language),
                           timezone = COALESCE(\(timezone), timezone), last_login_at = now()
                    WHERE id = \(accountId) AND password_hash IS NULL RETURNING id
                    """, logger: self.logger) {
                    updated = true
                }
                // Throwing rolls the transaction back, so the token stays unspent for an account that cannot use it.
                guard updated else { throw AccountStoreError.notFound }
                return accountId
            }
        }
    }

    /// Changes a member's role. `notFound` if the account is not a member.
    public func updateRole(_ accountId: String, role: String) async throws {
        try await bounded {
            var found = false
            for try await _ in try await self.client.query("UPDATE members SET role = \(role) WHERE account_id = \(accountId) RETURNING account_id",
                                                           logger: self.logger) {
                found = true
            }
            if !found { throw AccountStoreError.notFound }
        }
    }

    /// Removes a member and revokes its sessions. An account that never activated (pending) is deleted with its
    /// invitations, as Dify does with orphaned pending accounts; an active account stays (it authored things).
    public func removeMember(_ accountId: String) async throws {
        try await bounded {
            try await self.transaction { tx in
                var found = false
                for try await _ in try await tx.query("DELETE FROM members WHERE account_id = \(accountId) RETURNING account_id", logger: self.logger) {
                    found = true
                }
                guard found else { throw AccountStoreError.notFound }
                _ = try await tx.query("DELETE FROM sessions WHERE account_id = \(accountId)", logger: self.logger)
                _ = try await tx.query("DELETE FROM invitations WHERE account_id = \(accountId)", logger: self.logger)
                _ = try await tx.query("DELETE FROM accounts WHERE id = \(accountId) AND status = 'pending' AND password_hash IS NULL", logger: self.logger)
            }
        }
    }

    // MARK: - Client ids (protocol 1.8)

    /// The account a client id of the document belongs to, if any.
    public func clientAccount(_ doc: String, client c: String) async throws -> String? {
        try await bounded {
            for try await a in try await self.client.query("SELECT account_id FROM client_accounts WHERE doc_id = \(doc) AND client_id = \(c)",
                                                           logger: self.logger).decode(String.self) {
                return a
            }
            return nil
        }
    }

    /// Binds the client id to `account` unless it is bound already; returns the account it is bound to (afterwards).
    public func bindClient(_ doc: String, client c: String, account: String) async throws -> String {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO client_accounts (doc_id, client_id, account_id) VALUES (\(doc), \(c), \(account)) ON CONFLICT DO NOTHING
                """, logger: self.logger)
            for try await a in try await self.client.query("SELECT account_id FROM client_accounts WHERE doc_id = \(doc) AND client_id = \(c)",
                                                           logger: self.logger).decode(String.self) {
                return a
            }
            return account
        }
    }

    /// client id -> (account, name, avatar) for every bound client id of the document.
    public func clientDirectory(_ doc: String) async throws -> [String: (account: String, name: String, avatarUrl: String?)] {
        try await bounded {
            var out: [String: (account: String, name: String, avatarUrl: String?)] = [:]
            for try await (c, a, n, av) in try await self.client.query("""
                SELECT ca.client_id, a.id, a.name, a.avatar_url FROM client_accounts ca JOIN accounts a ON a.id = ca.account_id
                WHERE ca.doc_id = \(doc)
                """, logger: self.logger).decode((String, String, String, String?).self) {
                out[c] = (a, n, av)
            }
            return out
        }
    }
}
