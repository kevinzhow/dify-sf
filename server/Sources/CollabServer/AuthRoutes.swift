import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Accounts (docs/protocol.md, "Accounts", protocol 1.8): Dify 1.17.1's install, email + password sign-in, account
/// settings, members and invitations, for one workspace per server (Dify's community edition).
extension Routes {
    func registerAuth(on r: any RoutesBuilder) {
        r.get("v1", "setup") { req in await handle(req) { try await setupStatus() } }
        r.post("v1", "setup") { req in await handle(req) { try await setup(req) } }
        r.post("v1", "auth", "login") { req in await handle(req) { try await login(req) } }
        r.post("v1", "auth", "refresh") { req in await handle(req) { try await refresh(req) } }
        r.post("v1", "auth", "logout") { req in await handle(req) { try await logout(req) } }
        r.get("v1", "account") { req in await handle(req) { try await account(req) } }
        r.put("v1", "account", "name") { req in await handle(req) { try await updateName(req) } }
        r.put("v1", "account", "password") { req in await handle(req) { try await updatePassword(req) } }
        r.get("v1", "workspace", "members") { req in await handle(req) { try await members(req) } }
        r.post("v1", "workspace", "members", "invite-email") { req in await handle(req) { try await invite(req) } }
        r.put("v1", "workspace", "members", ":member", "update-role") { req in await handle(req) { try await updateRole(req) } }
        r.delete("v1", "workspace", "members", ":member") { req in await handle(req) { try await removeMember(req) } }
        r.post("v1", "activate", "check") { req in await handle(req) { try await checkActivation(req, token: nil) } }
        r.get("v1", "activate", "check") { req in await handle(req) { try await checkActivation(req, token: query(req)["token"] ?? "") } }
        r.post("v1", "activate") { req in await handle(req) { try await activate(req) } }
        registerPasswordReset(on: r)
        registerAccountSettings(on: r)
    }

    // MARK: - Validation

    static func bad(_ code: String, _ message: String) -> ServerError { .http(status: 400, code: code, message: message) }

    /// Dify's `EmailStr`, simplified: one `@`, a non-empty local part, a dotted domain, no whitespace, at most 254 bytes.
    static func validEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard s.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("."), !s.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 32 }) else { return false }
        return true
    }

    static func email(_ raw: String?) throws -> String {
        let e = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard validEmail(e) else { throw bad("bad_request", "invalid email address") }
        return e
    }

    /// Dify: names are at most 30 characters (`min` 3 for a rename in the account settings).
    static func name(_ raw: String?, min: Int = 1) throws -> String {
        let n = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count >= min, n.count <= 30, !n.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw bad("bad_request", "name must be \(min)-30 characters")
        }
        return n
    }

    static func password(_ raw: String?) throws -> String {
        guard let p = raw, Passwords.isValid(p) else { throw bad("invalid_password", Passwords.ruleMessage) }
        return p
    }

    /// Optional free-form settings (`interface_language`, `timezone`): at most 64 printable bytes.
    static func setting(_ raw: String?) throws -> String? {
        guard let s = raw, !s.isEmpty else { return nil }
        guard s.utf8.count <= 64, !s.unicodeScalars.contains(where: { $0.value < 32 }) else { throw bad("bad_request", "invalid setting") }
        return s
    }

    func decode<T: Decodable>(_ req: Request, _ t: T.Type, _ shape: String) async throws -> T {
        let data = try await body(req)
        do { return try WireJSON.decode(T.self, from: data) } catch { throw ServerError.badRequest("body must be \(shape)") }
    }

    func storeCall<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as ServerError { throw e } catch let e as AccountStoreError {
            switch e {
            case .setupDone: throw ServerError.http(status: 409, code: "setup_done", message: "the workspace is already set up")
            case .emailTaken: throw ServerError.http(status: 409, code: "email_taken", message: "an account with this email exists")
            case .notFound: throw ServerError.missing("unknown account")
            }
        } catch {
            throw ServerError.unavailable("\(error)")
        }
    }

    // MARK: - Setup (Dify's /console/api/setup)

    private func setupStatus() async throws -> Response {
        let n = try await storeCall { try await store.accountCount() }
        struct Step: Encodable { var step: String }
        return try json(Step(step: n == 0 ? "not_started" : "finished"))
    }

    private func setup(_ req: Request) async throws -> Response {
        struct Body: Decodable {
            var email: String?; var name: String?; var password: String?; var interface_language: String?; var language: String?
            var timezone: String?
        }
        let b = try await decode(req, Body.self, #"{"email","name","password"}"#)
        let email = try Self.email(b.email), name = try Self.name(b.name), password = try Self.password(b.password)
        // `language` is Dify's name for it in /setup.
        let lang = try Self.setting(b.interface_language ?? b.language), tz = try Self.setting(b.timezone)
        let (hash, salt) = try Passwords.hash(password)
        let owner = try await storeCall {
            try await store.createOwner(id: UUID().uuidString.lowercased(), email: email, name: name, passwordHash: hash,
                                        passwordSalt: salt, interfaceLanguage: lang, timezone: tz)
        }
        return try await signIn(owner, status: .created)
    }

    // MARK: - Sign-in

    /// Hash compared against when the email is unknown, so that the answer takes as long as for a wrong password.
    private static let dummy: (hash: String, salt: String) = (try? Passwords.hash("not-a-password-0")) ?? ("", "")

    private func login(_ req: Request) async throws -> Response {
        struct Body: Decodable { var email: String?; var password: String?; var remember_me: Bool?; var invite_token: String? }
        let b = try await decode(req, Body.self, #"{"email","password","remember_me"?,"invite_token"?}"#)
        let email = (b.email ?? "").trimmingCharacters(in: .whitespaces)
        let password = b.password ?? ""
        let key = email.lowercased()
        let invalid = ServerError.http(status: 401, code: "invalid_credentials", message: "Invalid email or password.")
        guard !email.isEmpty, !password.isEmpty else { throw invalid }
        if await limiter.isLocked(key) {
            throw ServerError.http(status: 429, code: "login_rate_limited", message: "Too many incorrect password attempts. Please try again later.")
        }
        let found = try await storeCall { try await store.account(email: email) }
        guard let account = found else {
            _ = Passwords.verify(password, hash: Self.dummy.hash, salt: Self.dummy.salt)
            await limiter.recordFailure(key)
            throw invalid
        }
        var signedIn = account
        if let hash = account.passwordHash, let salt = account.passwordSalt {
            guard Passwords.verify(password, hash: hash, salt: salt) else {
                await limiter.recordFailure(key)
                throw invalid
            }
        } else {
            // Dify: an invited account without a password signs in with its invitation token, which sets the password.
            guard let token = b.invite_token, !token.isEmpty, Passwords.isValid(password),
                  let inv = try await storeCall({ try await store.invitation(tokenHash: Tokens.sha256(token)) }),
                  inv.accountId == account.id else {
                _ = Passwords.verify(password, hash: Self.dummy.hash, salt: Self.dummy.salt)
                await limiter.recordFailure(key)
                throw invalid
            }
            let (hash, salt) = try Passwords.hash(password)
            guard try await storeCall({
                try await store.activate(tokenHash: Tokens.sha256(token), name: nil, passwordHash: hash, passwordSalt: salt,
                                         interfaceLanguage: nil, timezone: nil)
            }) != nil, let reloaded = try await storeCall({ try await store.account(id: account.id) }) else { throw invalid }
            signedIn = reloaded
        }
        if signedIn.status == "banned" { throw ServerError.http(status: 403, code: "account_banned", message: "Account is banned.") }
        guard signedIn.role != nil else {
            throw ServerError.http(status: 403, code: "forbidden", message: "this account is not a member of the workspace")
        }
        await limiter.reset(key)
        try await storeCall { try await store.touchLogin(signedIn.id) }
        return try await signIn(signedIn)
    }

    /// Refresh-token rotation: the old refresh token is spent, a new pair is issued in the same session. The old access
    /// token stays valid until it expires (as Dify's).
    private func refresh(_ req: Request) async throws -> Response {
        struct Body: Decodable { var refresh_token: String? }
        let b = try await decode(req, Body.self, #"{"refresh_token"}"#)
        let invalid = ServerError.unauthorized("invalid or expired refresh token")
        guard let old = b.refresh_token, !old.isEmpty, old.utf8.count <= 512 else { throw invalid }
        let (pair, rows) = newTokens()
        guard let accountId = try await storeCall({ try await store.rotateRefresh(oldHash: Tokens.sha256(old), newTokens: rows) }) else { throw invalid }
        // A member that was removed or banned in the meantime gets no working pair.
        guard let a = try await storeCall({ try await store.account(id: accountId) }), a.role != nil, a.status == "active" else {
            try? await store.revokeAccountSessions(accountId)
            throw invalid
        }
        return try json(pair)
    }

    private func logout(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        try await storeCall { try await store.revokeSession(p.sessionId) }
        return Response(status: .noContent)
    }

    // MARK: - Own account (Dify's account settings)

    private func account(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        return try json(Self.accountJSON(p.account))
    }

    private func updateName(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        struct Body: Decodable { var name: String? }
        let b = try await decode(req, Body.self, #"{"name"}"#)
        let name = try Self.name(b.name, min: 3)
        try await storeCall { try await store.updateAccountName(p.id, name: name) }
        var a = p.account
        a.name = name
        return try json(Self.accountJSON(a))
    }

    private func updatePassword(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        struct Body: Decodable { var password: String?; var new_password: String?; var repeat_new_password: String? }
        let b = try await decode(req, Body.self, #"{"password","new_password","repeat_new_password"}"#)
        guard b.new_password == b.repeat_new_password else { throw Self.bad("invalid_password", "the new passwords do not match") }
        if let hash = p.account.passwordHash, let salt = p.account.passwordSalt {
            guard let current = b.password, Passwords.verify(current, hash: hash, salt: salt) else {
                throw Self.bad("invalid_password", "the current password is incorrect")
            }
        }
        let new = try Self.password(b.new_password)
        let (hash, salt) = try Passwords.hash(new)
        try await storeCall { try await store.updatePassword(p.id, hash: hash, salt: salt) }
        return Response(status: .noContent)
    }

    // MARK: - Members (Dify's /workspaces/current/members)

    private func members(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        let all = try await storeCall { try await store.members() }
        struct List: Encodable { var accounts: [MemberJSON] }
        return try json(List(accounts: all.map(Self.memberJSON)))
    }

    /// No mail server: like Dify without mail, the answer carries each activation link (`/activate?token=...`, relative to
    /// the web app).
    private func invite(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        struct Body: Decodable { var emails: [String]?; var role: String? }
        let b = try await decode(req, Body.self, #"{"emails":[...],"role"}"#)
        guard let raw = b.role, let role = Role(rawValue: raw), role != .owner else { throw Self.bad("invalid_role", "invalid role") }
        let emails = b.emails ?? []
        guard !emails.isEmpty, emails.count <= 100 else { throw ServerError.badRequest("emails must list 1-100 addresses") }
        struct Result: Encodable { var email: String; var status: String; var url: String?; var message: String? }
        var results: [Result] = []
        var seen = Set<String>()
        for raw in emails {
            let e = raw.trimmingCharacters(in: .whitespaces)
            guard Self.validEmail(e) else { results.append(Result(email: raw, status: "failed", message: "invalid email address")); continue }
            guard seen.insert(e.lowercased()).inserted else { continue }
            let token = Tokens.random()
            let outcome = try await storeCall {
                try await store.invite(email: e, newAccountId: UUID().uuidString.lowercased(), role: role.rawValue, invitedBy: p.id,
                                       tokenHash: Tokens.sha256(token),
                                       expiresAt: Date().addingTimeInterval(Double(config.inviteExpiryHours) * 3600))
            }
            switch outcome {
            case .invited:
                let q = e.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? e
                results.append(Result(email: e, status: "success", url: "/activate?email=\(q)&token=\(token)"))
            case .alreadyMember:
                results.append(Result(email: e, status: "already_member", message: "Account already in workspace."))
            }
        }
        struct Answer: Encodable { var invitation_results: [Result] }
        return try json(Answer(invitation_results: results), status: .created)
    }

    private func memberId(_ req: Request) throws -> String {
        guard let id = req.parameters.get("member"), Self.validClientId(id) else { throw ServerError.missing("unknown member") }
        return id
    }

    /// Dify's `update_member_role`: privileged only; not oneself (`cannot_operate_self`); nobody becomes or stops being the
    /// owner here (ownership transfer is not part of this step).
    private func updateRole(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        let id = try memberId(req)
        struct Body: Decodable { var role: String? }
        let b = try await decode(req, Body.self, #"{"role"}"#)
        guard let raw = b.role, let role = Role(rawValue: raw), role != .owner else { throw Self.bad("invalid_role", "invalid role") }
        if id == p.id { throw Self.bad("cannot_operate_self", "Cannot operate self.") }
        guard let target = try await storeCall({ try await store.account(id: id) }), let current = target.role else {
            throw ServerError.missing("unknown member")
        }
        if current == Role.owner.rawValue {
            throw ServerError.http(status: 403, code: "forbidden", message: "the owner's role cannot be changed")
        }
        try await storeCall { try await store.updateRole(id, role: role.rawValue) }
        struct Done: Encodable { var result = "success" }
        return try json(Done())
    }

    /// Dify's `remove_member_from_tenant`: privileged only; not oneself; never the owner.
    private func removeMember(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        let id = try memberId(req)
        if id == p.id { throw Self.bad("cannot_operate_self", "Cannot operate self.") }
        guard let target = try await storeCall({ try await store.account(id: id) }), let current = target.role else {
            throw ServerError.missing("unknown member")
        }
        if current == Role.owner.rawValue { throw ServerError.http(status: 403, code: "forbidden", message: "the owner cannot be removed") }
        try await storeCall { try await store.removeMember(id) }
        struct Done: Encodable { var result = "success" }
        return try json(Done())
    }

    // MARK: - Activation (Dify's /activate)

    private func checkActivation(_ req: Request, token: String?) async throws -> Response {
        let t: String
        if let token { t = token } else {
            struct Body: Decodable { var token: String? }
            t = try await decode(req, Body.self, #"{"token"}"#).token ?? ""
        }
        struct Invited: Encodable {
            var email: String
            var workspace_name: String
            // Dify's members of the check: a valid dify-sf link is always for a pending account that still needs its name and password.
            var account_status = "pending"
            var requires_setup = true
        }
        struct Check: Encodable { var is_valid: Bool; var data: Invited? }
        guard !t.isEmpty, t.utf8.count <= 512, let inv = try await storeCall({ try await store.invitation(tokenHash: Tokens.sha256(t)) }),
              !inv.accountActive else {
            return try json(Check(is_valid: false, data: nil))
        }
        return try json(Check(is_valid: true, data: Invited(email: inv.email, workspace_name: try await workspaceName())))
    }

    /// Dify names the community edition's workspace "<owner name>'s Workspace".
    func workspaceName() async throws -> String {
        let all = try await storeCall { try await store.members() }
        guard let owner = all.first(where: { $0.role == Role.owner.rawValue }) else { return "Workspace" }
        return "\(owner.name)'s Workspace"
    }

    private func activate(_ req: Request) async throws -> Response {
        struct Body: Decodable { var token: String?; var name: String?; var password: String?; var interface_language: String?; var timezone: String? }
        let b = try await decode(req, Body.self, #"{"token","name","password","interface_language"?,"timezone"?}"#)
        let token = b.token ?? ""
        let name = try Self.name(b.name), password = try Self.password(b.password)
        let lang = try Self.setting(b.interface_language), tz = try Self.setting(b.timezone)
        let invalid = Self.bad("invalid_token", "The token is invalid or has expired.")
        guard !token.isEmpty, token.utf8.count <= 512 else { throw invalid }
        let (hash, salt) = try Passwords.hash(password)
        let activated: String?
        do {
            activated = try await store.activate(tokenHash: Tokens.sha256(token), name: name, passwordHash: hash, passwordSalt: salt,
                                                 interfaceLanguage: lang, timezone: tz)
        } catch AccountStoreError.notFound {
            throw invalid
        } catch {
            throw ServerError.unavailable("\(error)")
        }
        guard let id = activated, let account = try await storeCall({ try await store.account(id: id) }) else { throw invalid }
        return try await signIn(account)
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters: safe inside a query value.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
