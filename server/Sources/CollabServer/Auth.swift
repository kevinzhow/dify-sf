import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Workspace roles (Dify's `TenantAccountRole`). `owner`, `admin` and `editor` may edit workflows; `owner` and `admin` are
/// privileged (members, secrets in exports); `normal` and `dataset_operator` only read in the workflow editor.
public enum Role: String, Sendable, CaseIterable, Codable {
    case owner, admin, editor, normal
    case datasetOperator = "dataset_operator"

    /// Dify's `has_edit_permission`.
    public var canEdit: Bool { self == .owner || self == .admin || self == .editor }
    /// Dify's `is_admin_or_owner`.
    public var isPrivileged: Bool { self == .owner || self == .admin }
}

/// The member behind a request's access token.
struct Principal: Sendable {
    var account: StoredAccount
    var role: Role
    var sessionId: String
    var id: String { account.id }
}

/// What a route needs from its caller.
enum Access {
    /// Any member (reads, streams, own account).
    case member
    /// `owner`, `admin` or `editor` (every write to a workflow and its comments).
    case edit
    /// `owner` or `admin` (member management, secrets in exports).
    case privileged
}

/// Dify's login error rate limit (`login_error_rate_limit:<email>` in Redis, here in memory per process): every failed
/// sign-in for an email counts and renews the lockout window; with more than `maxFailures` failures in the window the
/// email is locked (`429`) until the window passes, even with the right password. A successful sign-in clears the count.
actor LoginLimiter {
    private var failures: [String: (count: Int, until: ContinuousClock.Instant)] = [:]
    let maxFailures: Int
    let lockout: Duration

    init(maxFailures: Int, lockoutSeconds: Int) {
        self.maxFailures = maxFailures
        lockout = .seconds(lockoutSeconds)
    }

    func isLocked(_ email: String) -> Bool {
        guard let f = failures[email] else { return false }
        if ContinuousClock.now >= f.until {
            failures[email] = nil
            return false
        }
        return f.count > maxFailures
    }

    func recordFailure(_ email: String) {
        let now = ContinuousClock.now
        let current = failures[email].flatMap { now < $0.until ? $0.count : nil } ?? 0
        failures[email] = (current + 1, now + lockout)
        if failures.count > 100_000 { failures = failures.filter { now < $0.value.until } }
    }

    func reset(_ email: String) { failures[email] = nil }
}

extension Routes {
    // MARK: - Authentication

    /// The bearer token of the request: `Authorization: Bearer <token>`, or (`allowQuery`, the event stream only, for the
    /// browser's native EventSource which cannot set headers) `?access_token=`. Never logged.
    func bearer(_ req: Request, allowQuery: Bool) -> String? {
        if let h = req.headers[.authorization] {
            let parts = h.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                let t = parts[1].trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            return nil
        }
        if allowQuery, let t = query(req)["access_token"], !t.isEmpty { return t }
        return nil
    }

    /// The caller, or `401 unauthorized`; then `403 forbidden` if its role does not allow `access`.
    func authenticate(_ req: Request, _ access: Access = .member, allowQuery: Bool = false) async throws -> Principal {
        guard let token = bearer(req, allowQuery: allowQuery), token.utf8.count <= 512 else {
            throw ServerError.unauthorized("missing bearer token")
        }
        let found: StoredPrincipal?
        do { found = try await store.principal(tokenHash: Tokens.sha256(token)) } catch { throw ServerError.unavailable("\(error)") }
        guard let found, found.account.status == "active", let role = found.account.role.flatMap(Role.init(rawValue:)) else {
            throw ServerError.unauthorized("invalid or expired access token")
        }
        let p = Principal(account: found.account, role: role, sessionId: found.sessionId)
        try authorize(p, access)
        return p
    }

    func authorize(_ p: Principal, _ access: Access) throws {
        switch access {
        case .member: return
        case .edit:
            if !p.role.canEdit { throw ServerError.http(status: 403, code: "forbidden", message: "the \(p.role.rawValue) role cannot edit") }
        case .privileged:
            if !p.role.isPrivileged {
                throw ServerError.http(status: 403, code: "forbidden", message: "only the workspace owner or an admin may do this")
            }
        }
    }

    // MARK: - Wire shapes

    struct AccountJSON: Encodable {
        var id: String
        var email: String
        var name: String
        var avatar_url: String?
        var role: String?
        var interface_language: String?
        var timezone: String?
        var created_at: String
    }

    func accountJSON(_ a: StoredAccount) -> AccountJSON {
        AccountJSON(id: a.id, email: a.email, name: a.name, avatar_url: signedAvatar(a.avatarUrl), role: a.role, interface_language: a.interfaceLanguage,
                    timezone: a.timezone, created_at: Self.timestamp(a.createdAt))
    }

    struct MemberJSON: Encodable {
        var id: String
        var name: String
        var email: String
        var avatar_url: String?
        var role: String
        var status: String
        var last_login_at: String?
        var created_at: String
    }

    func memberJSON(_ a: StoredAccount) -> MemberJSON {
        MemberJSON(id: a.id, name: a.name, email: a.email, avatar_url: signedAvatar(a.avatarUrl), role: a.role ?? "", status: a.status,
                   last_login_at: a.lastLoginAt.map(Self.timestamp), created_at: Self.timestamp(a.createdAt))
    }

    struct TokenPair: Encodable {
        var access_token: String
        var refresh_token: String
    }

    struct SignedIn: Encodable {
        var access_token: String
        var refresh_token: String
        var account: AccountJSON
    }

    /// New access + refresh tokens (stored hashed under `sessionId`).
    func newTokens() -> (pair: TokenPair, rows: [NewToken]) {
        let access = Tokens.random(), refresh = Tokens.random()
        let now = Date()
        return (TokenPair(access_token: access, refresh_token: refresh), [
            NewToken(hash: Tokens.sha256(access), kind: "access", expiresAt: now.addingTimeInterval(Double(config.accessTokenMinutes) * 60)),
            NewToken(hash: Tokens.sha256(refresh), kind: "refresh", expiresAt: now.addingTimeInterval(Double(config.refreshTokenDays) * 86_400)),
        ])
    }

    /// Starts a new session for the account: `{access_token, refresh_token, account}`.
    func signIn(_ account: StoredAccount, status: HTTPResponse.Status = .ok) async throws -> Response {
        let (pair, rows) = newTokens()
        do { try await store.storeTokens(rows, account: account.id, sessionId: UUID().uuidString.lowercased()) } catch {
            throw ServerError.unavailable("\(error)")
        }
        return try json(SignedIn(access_token: pair.access_token, refresh_token: pair.refresh_token, account: accountJSON(account)),
                        status: status)
    }
}
