import CollabRuntime
import CollabCore
import CollabStore
import Configuration
import Foundation
import HTTPTypes
import Vapor

/// Forgot password (docs/protocol.md, "Password reset"): Dify 1.17.1's `/forgot-password` flow (api/controllers/console/auth/
/// forgot_password.py, services/account_forgot_password_service.py) with its codes, expiry and rate limits, the system
/// features the sign-in page reads to know whether mail is set up, and dify-sf's admin reset links for servers without mail.
public struct PasswordResetConfig: Sendable {
    /// Dify's `RESET_PASSWORD_TOKEN_EXPIRY_MINUTES` (5): how long an email code and the reset token after it are valid.
    public var tokenMinutes: Int
    /// Dify's send limit (`reset_password_rate_limit`: 1 mail per 60 seconds per address; a constant in Dify).
    public var sendIntervalSeconds: Int
    /// Dify's `FORGOT_PASSWORD_VERIFICATION_FAILURE_LIMIT` (5, a constant): more wrong codes than this lock the email.
    public var verifyMaxFailures: Int
    /// Dify's `FORGOT_PASSWORD_LOCKOUT_DURATION` (86400 s), renewed by every wrong code.
    public var lockoutSeconds: Int
    /// Dify's `EMAIL_SEND_IP_LIMIT_PER_MINUTE` (50).
    public var emailSendIpLimitPerMinute: Int
    /// dify-sf: how long an admin's reset link is valid (24 hours).
    public var linkHours: Int

    public init(reader: ConfigReader) {
        tokenMinutes = max(1, reader.int(forKey: "collab.auth.resetPasswordTokenMinutes", default: 5))
        sendIntervalSeconds = reader.int(forKey: "collab.auth.resetPasswordSendIntervalSeconds", default: 60)
        verifyMaxFailures = reader.int(forKey: "collab.auth.forgotPasswordMaxFailures", default: 5)
        lockoutSeconds = reader.int(forKey: "collab.auth.forgotPasswordLockoutSeconds", default: 86_400)
        emailSendIpLimitPerMinute = reader.int(forKey: "collab.auth.emailSendIpLimitPerMinute", default: 50)
        linkHours = max(1, reader.int(forKey: "collab.auth.resetLinkHours", default: 24))
    }
}

/// Dify's account email security gateway (`RedisAccountEmailSecurityGateway.is_ip_limited`, in memory per process): every
/// mail request from an IP counts, the count lives 60 seconds from the last counted request; above `perMinute` the IP is
/// refused, and a second excess within 10 minutes freezes it for an hour.
actor EmailSendIPLimiter {
    private var minute: [String: (count: Int, until: ContinuousClock.Instant)] = [:]
    private var hour: [String: ContinuousClock.Instant] = [:]
    private var freeze: [String: ContinuousClock.Instant] = [:]

    func isLimited(_ ip: String, perMinute: Int) -> Bool {
        let now = ContinuousClock.now
        if let f = freeze[ip], now < f { return true }
        let current = minute[ip].flatMap { now < $0.until ? $0.count : nil } ?? 0
        if current > perMinute {
            if let h = hour[ip], now < h {
                freeze[ip] = now + .seconds(3600)
            } else {
                hour[ip] = now + .seconds(600)
            }
            return true
        }
        minute[ip] = (current + 1, now + .seconds(60))
        if minute.count > 100_000 {
            minute = minute.filter { now < $0.value.until }
            hour = hour.filter { now < $0.value }
            freeze = freeze.filter { now < $0.value }
        }
        return false
    }
}

/// Dify's `RateLimiter(max_attempts=1)` for reset mails: one mail per address per window.
actor SendIntervalLimiter {
    private var last: [String: ContinuousClock.Instant] = [:]

    func isLimited(_ key: String, window: Duration) -> Bool {
        guard let t = last[key] else { return false }
        return ContinuousClock.now < t + window
    }

    func record(_ key: String, window: Duration) {
        let now = ContinuousClock.now
        last[key] = now
        if last.count > 100_000 { last = last.filter { now < $0.value + window } }
    }
}

/// Dify's verification failure limit (`forgot_password_error_rate_limit:<email>`): every wrong code counts and renews the
/// lockout; with more than `max` failures the email is locked until the lockout passes. A right code clears the count.
actor VerifyFailureLimiter {
    private var failures: [String: (count: Int, until: ContinuousClock.Instant)] = [:]

    func isLocked(_ key: String, max: Int) -> Bool {
        guard let f = failures[key], ContinuousClock.now < f.until else { return false }
        return f.count > max
    }

    func recordFailure(_ key: String, lockout: Duration) {
        let now = ContinuousClock.now
        let current = failures[key].flatMap { now < $0.until ? $0.count : nil } ?? 0
        failures[key] = (current + 1, now + lockout)
        if failures.count > 100_000 { failures = failures.filter { now < $0.value.until } }
    }

    func reset(_ key: String) { failures[key] = nil }
}

/// The forgot-password limits of one server process (Dify keeps them in Redis).
final class PasswordResetLimits: Sendable {
    let ip = EmailSendIPLimiter()
    let send = SendIntervalLimiter()
    let verify = VerifyFailureLimiter()
}

extension Routes {
    func registerPasswordReset(on r: any RoutesBuilder) {
        r.get("v1", "system-features") { req in await handle(req) { try await systemFeatures() } }
        r.post("v1", "forgot-password") { req in await handle(req) { try await sendResetCode(req) } }
        r.post("v1", "forgot-password", "validity") { req in await handle(req) { try await checkResetCode(req) } }
        r.post("v1", "forgot-password", "resets") { req in await handle(req) { try await resetPassword(req) } }
        r.post("v1", "workspace", "members", ":member", "reset-password-link") { req in
            await handle(req) { try await resetPasswordLink(req) }
        }
    }

    var outbox: MailOutbox { MailOutbox(sender: SMTPMailSender(config: config.mail), logger: logger) }

    /// SHA-256 of a token and its code: what a `verify` token stores instead of the code.
    static func codeHash(token: String, code: String) -> String { Tokens.sha256("\(token):\(code)") }

    /// Dify's `SecureForgotPasswordCodeGenerator`: six random digits.
    static func resetCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<6).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined()
    }

    // MARK: - System features (Dify's /console/api/system-features)

    /// The members of Dify's system features the sign-in pages read: dify-sf signs in with email + password only, has no
    /// sign-up, and can send mail when it is configured (`is_email_setup`, which enables "Forgot your password?").
    private func systemFeatures() async throws -> Response {
        struct Features: Encodable {
            var enable_email_code_login = false
            var enable_email_password_login = true
            var is_allow_register = false
            var is_email_setup: Bool
            /// 1.12: the account page offers changing the email (Dify's `ENABLE_CHANGE_EMAIL`; dify-sf needs mail for it).
            var enable_published_apps = true
            var enable_file_upload: Bool
            var enable_change_email: Bool
            /// 1.13 (dify-sf only): what the workflow runtime can run; absent without a model runtime (plugin daemon).
            var workflow_runtime: WorkflowRuntime?
            var inline_agent: Bool
            var inline_agent_shell: Bool
        }
        struct WorkflowRuntime: Encodable {
            var protocol_version = "1.21"
            /// Durable, creator-scoped console Chatflow conversations (published/end-user runs remain separate).
            var chatflow = true
            var published_run = true
            /// 1.21: helpers use installed models; semantic replies additionally need Weaviate.
            var helper_generation: Bool
            var helper_tts: Bool
            var annotation_semantic_index: Bool
            /// The node types `POST .../workflows/draft/nodes/{node}/run` runs.
            var single_node_run: [String]
            /// 1.14: the node types a draft run (`POST .../workflows/draft/run`) runs; a graph with others is refused.
            var draft_run: [String]
            /// 1.16: human input is served — a draft run pauses at a `human-input` node, its form is answered through
            /// `POST /v1/form/human_input/{token}`, `GET /v1/workflow/{run}/events` rebuilds a paused run's state, and
            /// the node's own form (`.../human-input/nodes/{node}/form/{preview,run}`) is rendered from its config.
            var human_input: Bool
            var human_input_email: Bool
        }
        let mail = config.mail.isConfigured
        // Web forms do not need a model daemon. That explicit rollout switch
        // can expose pure workflow runs without advertising unconfigured LLMs.
        let singleTypes = Self.singleRunNodeTypes.filter { runtimeConfigured || $0 != NodeType.llm }
        let draftTypes = Self.draftRunNodeTypes.filter {
            (config.humanInputWebEnabled || $0 != NodeType.humanInput) && (runtimeConfigured || $0 != NodeType.llm)
        }
        let runtime = runtimeConfigured || config.humanInputWebEnabled
            ? WorkflowRuntime(helper_generation: runtimeConfigured, helper_tts: runtimeConfigured,
                              annotation_semantic_index: runtimeConfigured && !config.annotationWeaviateURL.isEmpty,
                              single_node_run: singleTypes, draft_run: draftTypes,
                              human_input: config.humanInputWebEnabled,
                              human_input_email: config.humanInputWebEnabled && config.humanInputEmailEnabled && mail) : nil
        return try json(Features(is_email_setup: mail, enable_file_upload: config.files.isConfigured, enable_change_email: mail, workflow_runtime: runtime,
            inline_agent: config.agentService.inlineEnabled && config.agentService.isConfigured,
            inline_agent_shell: config.agentService.inlineEnabled && config.agentService.isConfigured ? await AgentServiceClient(config: config.agentService).shellAvailable() : false))
    }

    // MARK: - Forgot password (Dify's /forgot-password, /forgot-password/validity, /forgot-password/resets)

    /// Sends a six-digit code to the email and answers a token for the next step. An email without an account gets Dify's
    /// "not associated with any account" mail and the same answer, so the answer does not tell whether an account exists.
    private func sendResetCode(_ req: Request) async throws -> Response {
        struct Body: Decodable { var email: String?; var language: String? }
        let b = try await decode(req, Body.self, #"{"email","language"?}"#)
        let email = try Self.email(b.email)
        let language = b.language == "zh-Hans" ? "zh-Hans" : "en-US"
        let outbox = outbox
        guard outbox.isEnabled else {
            throw Self.bad("mail_not_configured", "Mail is not configured on this server: ask the workspace owner or an admin for a reset link.")
        }
        let reset = config.passwordReset
        if await passwordResetLimits.ip.isLimited(req.peerAddress?.host ?? "unknown", perMinute: reset.emailSendIpLimitPerMinute) {
            throw ServerError.http(status: 429, code: "email_send_ip_limit",
                                   message: "Too many emails have been sent from this IP address recently. Please try again later.")
        }
        let account = try await storeCall { try await store.account(email: email) }
        let destination = account?.email ?? email.lowercased()
        let window = Duration.seconds(reset.sendIntervalSeconds)
        if await passwordResetLimits.send.isLimited(destination.lowercased(), window: window) {
            let minutes = max(1, (reset.sendIntervalSeconds + 59) / 60)
            throw ServerError.http(status: 429, code: "password_reset_rate_limit_exceeded",
                                   message: "Too many password reset emails have been sent. Please try again in \(minutes) minutes.")
        }
        let code = Self.resetCode(), token = Tokens.random()
        try await storeCall {
            try await store.issuePasswordReset(tokenHash: Tokens.sha256(token), accountId: account?.id, email: destination,
                                               codeHash: Self.codeHash(token: token, code: code), phase: "verify", createdBy: nil,
                                               expiresAt: Date().addingTimeInterval(Double(reset.tokenMinutes) * 60))
        }
        if account != nil {
            outbox.post(MailTemplates.resetPassword(to: destination, code: code, minutes: reset.tokenMinutes, language: language),
                        kind: "password reset")
        } else {
            outbox.post(MailTemplates.resetPasswordUnknownAccount(to: destination, language: language), kind: "password reset")
        }
        await passwordResetLimits.send.record(destination.lowercased(), window: window)
        struct Sent: Encodable { var result = "success"; var data: String }
        return try json(Sent(data: token))
    }

    /// Checks the code of a `verify` token; a right code spends it and answers the token that resets the password.
    private func checkResetCode(_ req: Request) async throws -> Response {
        struct Body: Decodable { var email: String?; var code: String?; var token: String? }
        let b = try await decode(req, Body.self, #"{"email","code","token"}"#)
        let email = try Self.email(b.email)
        guard let token = b.token, !token.isEmpty, token.utf8.count <= 512 else { throw ServerError.badRequest("token is required") }
        let code = b.code ?? ""
        let reset = config.passwordReset
        let key = email.lowercased()
        if await passwordResetLimits.verify.isLocked(key, max: reset.verifyMaxFailures) {
            throw ServerError.http(status: 429, code: "email_password_reset_limit",
                                   message: "Too many failed password reset attempts. Please try again in 24 hours.")
        }
        let invalidToken = Self.bad("invalid_token", "The token is invalid or has expired.")
        guard let stored = try await storeCall({ try await store.passwordReset(tokenHash: Tokens.sha256(token), phase: "verify") }) else {
            throw invalidToken
        }
        guard stored.email.lowercased() == key else { throw Self.bad("invalid_email", "The email address is not valid.") }
        guard let expected = stored.codeHash,
              Passwords.constantTimeEqual(Array(Self.codeHash(token: token, code: code).utf8), Array(expected.utf8)) else {
            await passwordResetLimits.verify.recordFailure(key, lockout: .seconds(reset.lockoutSeconds))
            throw Self.bad("email_code_error", "Email code is invalid or expired.")
        }
        let next = Tokens.random()
        guard try await storeCall({
            try await store.promotePasswordReset(oldHash: Tokens.sha256(token), newHash: Tokens.sha256(next),
                                                 expiresAt: Date().addingTimeInterval(Double(reset.tokenMinutes) * 60))
        }) else { throw invalidToken }
        await passwordResetLimits.verify.reset(key)
        struct Valid: Encodable { var is_valid = true; var email: String; var token: String }
        return try json(Valid(email: key, token: next))
    }

    /// Sets the new password with a reset token (from a right code, or an admin's link). Spends the token, revokes every
    /// session of the account and activates an invited account that had not activated yet.
    private func resetPassword(_ req: Request) async throws -> Response {
        struct Body: Decodable { var token: String?; var new_password: String?; var password_confirm: String? }
        let b = try await decode(req, Body.self, #"{"token","new_password","password_confirm"}"#)
        guard let token = b.token, !token.isEmpty, token.utf8.count <= 512 else { throw ServerError.badRequest("token is required") }
        let password = try Self.password(b.new_password)
        _ = try Self.password(b.password_confirm)
        guard password == b.password_confirm else { throw Self.bad("password_mismatch", "The passwords do not match.") }
        guard let claimed = try await storeCall({ try await store.claimPasswordReset(tokenHash: Tokens.sha256(token)) }) else {
            throw Self.bad("invalid_token", "The token is invalid or has expired.")
        }
        let notFound = Self.bad("account_not_found", "Account not found.")
        let found = try await storeCall {
            if let id = claimed.accountId { return try await store.account(id: id) }
            return try await store.account(email: claimed.email)
        }
        guard let account = found, account.email.lowercased() == claimed.email.lowercased() else { throw notFound }
        let (hash, salt) = try Passwords.hash(password)
        guard try await storeCall({ try await store.resetPassword(accountId: account.id, hash: hash, salt: salt) }) else { throw notFound }
        struct Done: Encodable { var result = "success" }
        return try json(Done())
    }

    // MARK: - Admin reset links (dify-sf only)

    /// A one-time link that lets the member set a new password (`/reset-password/set-password?token=...`, relative to the
    /// web app), for servers without mail (Dify's community edition resets passwords from its command line). Owner and
    /// admins only; the owner's password only by the owner. Nobody sees or sets another member's password.
    private func resetPasswordLink(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .privileged)
        guard let id = req.parameters.get("member"), Self.validClientId(id),
              let target = try await storeCall({ try await store.account(id: id) }), let role = target.role else {
            throw ServerError.missing("unknown member")
        }
        if role == Role.owner.rawValue && target.id != p.id {
            throw ServerError.http(status: 403, code: "forbidden", message: "only the owner may reset the owner's password")
        }
        let token = Tokens.random()
        let expires = Date().addingTimeInterval(Double(config.passwordReset.linkHours) * 3600)
        try await storeCall {
            try await store.issuePasswordReset(tokenHash: Tokens.sha256(token), accountId: target.id, email: target.email, codeHash: nil,
                                               phase: "link", createdBy: p.id, expiresAt: expires)
        }
        let q = target.email.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? target.email
        struct Link: Encodable { var url: String; var expires_at: String }
        return try json(Link(url: "/reset-password/set-password?email=\(q)&token=\(token)", expires_at: Self.timestamp(expires)), status: .created)
    }
}
