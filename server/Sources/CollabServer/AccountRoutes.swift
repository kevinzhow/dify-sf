import CollabCore
import CollabModels
import CollabStore
import Configuration
import Foundation
import HTTPTypes
import Vapor

/// Protocol 1.12 (docs/protocol.md, "Account settings (1.12)"): Dify 1.17.1's account page and Preferences. The profile
/// (`PATCH /account/profile`: name, interface language, time zone) and changing the account's email with codes by mail
/// (`/account/change-email...`: api/controllers/console/workspace/account.py, services/account_change_email_service.py).
public struct ChangeEmailConfig: Sendable {
    /// Dify's `CHANGE_EMAIL_TOKEN_EXPIRY_MINUTES` (5): how long a code and the token after it are valid.
    public var tokenMinutes: Int
    /// Dify's send limit (`change_email_rate_limit`: 1 mail per 60 seconds per address; a constant in Dify).
    public var sendIntervalSeconds: Int
    /// Dify's `CHANGE_EMAIL_MAX_ERROR_LIMITS` (5, a constant): more wrong codes than this lock the address.
    public var verifyMaxFailures: Int
    /// Dify's `CHANGE_EMAIL_LOCKOUT_DURATION` (86400 s), renewed by every wrong code.
    public var lockoutSeconds: Int

    public init(reader: ConfigReader) {
        tokenMinutes = max(1, reader.int(forKey: "collab.auth.changeEmailTokenMinutes", default: 5))
        sendIntervalSeconds = reader.int(forKey: "collab.auth.changeEmailSendIntervalSeconds", default: 60)
        verifyMaxFailures = reader.int(forKey: "collab.auth.changeEmailMaxFailures", default: 5)
        lockoutSeconds = reader.int(forKey: "collab.auth.changeEmailLockoutSeconds", default: 86_400)
    }
}

/// The change-email limits of one server process (Dify keeps them in Redis). The IP limit is shared with forgot password
/// (Dify's one `email_send_ip_limit`).
final class ChangeEmailLimits: Sendable {
    let send = SendIntervalLimiter()
    let verify = VerifyFailureLimiter()
}

extension Routes {
    func registerAccountSettings(on r: any RoutesBuilder) {
        r.patch("v1", "account", "profile") { req in await handle(req) { try await updateProfile(req) } }
        r.post("v1", "account", "change-email") { req in await handle(req) { try await sendChangeEmailCode(req) } }
        r.post("v1", "account", "change-email", "validity") { req in await handle(req) { try await checkChangeEmailCode(req) } }
        r.post("v1", "account", "change-email", "reset") { req in await handle(req) { try await changeEmail(req) } }
        r.post("v1", "account", "change-email", "check-email-unique") { req in await handle(req) { try await checkEmailUnique(req) } }
    }

    // MARK: - Profile (Dify's PATCH /account/profile)

    /// Dify's `languages` (api/constants/languages.py): what `interface_language` accepts.
    static let languages: Set<String> = [
        "en-US", "zh-Hans", "zh-Hant", "pt-BR", "es-ES", "fr-FR", "de-DE", "ja-JP", "ko-KR", "lo-LA", "ru-RU", "it-IT", "uk-UA",
        "vi-VN", "ro-RO", "pl-PL", "hi-IN", "tr-TR", "fa-IR", "sl-SI", "th-TH", "id-ID", "ar-TN", "nl-NL",
    ]

    /// Dify's `timezone()` validator (a name of the IANA time zone database): `UTC`, or an `Area/Location` name the
    /// system's time zone data knows (canonical names and their aliases, such as `Asia/Kolkata` and `Etc/GMT+5`).
    static func validTimezone(_ s: String) -> Bool {
        if s == "UTC" { return true }
        guard s.utf8.count <= 64, s.wholeMatch(of: ianaName) != nil else { return false }
        return knownTimezones.contains(s) || TimeZone(identifier: s) != nil
    }

    private static let knownTimezones = Set(TimeZone.knownTimeZoneIdentifiers)
    nonisolated(unsafe) private static let ianaName = /[A-Z][A-Za-z_]*(\/[A-Z][A-Za-z0-9_+\-]*)+/

    /// Sets the members present: `name` (3-30 characters), `interface_language` (one of Dify's languages), `timezone` (an
    /// IANA name). Like Dify's payload (`extra="forbid"`, nulls refused) any other member, or a null, is `400`; Dify's
    /// `avatar` and `interface_theme` are refused too (dify-sf stores neither: avatars need file storage, the theme is the
    /// app's own setting, as in Dify's preference page).
    private func updateProfile(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let b = try await jsonBody(req)
        var name: String?, language: String?, timezone: String?
        for (key, value) in b {
            if value.isNull { throw Self.bad("bad_request", "Account profile fields cannot be null") }
            switch key {
            case "name": name = try Self.name(value.string, min: 3)
            case "interface_language":
                guard let s = value.string, Self.languages.contains(s) else {
                    throw Self.bad("bad_request", "\(value.string ?? "value") is not a valid language.")
                }
                language = s
            case "timezone":
                guard let s = value.string, Self.validTimezone(s) else {
                    throw Self.bad("bad_request", "\(value.string.map { String($0.prefix(64)) } ?? "value") is not a valid timezone.")
                }
                timezone = s
            case "avatar", "interface_theme": throw Self.bad("bad_request", "\(key) is not supported by this server")
            default: throw Self.bad("bad_request", "unknown member \(String(key.prefix(64)))")
            }
        }
        guard let a = try await storeCall({
            try await store.updateProfile(p.id, name: name, interfaceLanguage: language, timezone: timezone)
        }) else { throw ServerError.missing("unknown account") }
        return try json(Self.accountJSON(a))
    }

    // MARK: - Change email (Dify's /account/change-email...)

    /// Dify's `send_code`: a code to the account's own address (`phase` absent or `old_email`; `email` must be it), or, with
    /// the token of a right code for the old address, to the new address (`phase: new_email`). Answers the token for
    /// `validity`. Every new token replaces the account's earlier ones.
    private func sendChangeEmailCode(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        struct Body: Decodable { var email: String?; var language: String?; var phase: String?; var token: String? }
        let b = try await decode(req, Body.self, #"{"email","language"?,"phase"?,"token"?}"#)
        let requested = try Self.email(b.email)
        let language = b.language == "zh-Hans" ? "zh-Hans" : "en-US"
        let outbox = outbox
        guard outbox.isEnabled else { throw Self.bad("mail_not_configured", "Mail is not configured on this server.") }
        if await passwordResetLimits.ip.isLimited(req.peerAddress?.host ?? "unknown", perMinute: config.passwordReset.emailSendIpLimitPerMinute) {
            throw ServerError.http(status: 429, code: "email_send_ip_limit",
                                   message: "Too many emails have been sent from this IP address recently. Please try again later.")
        }
        let account = p.account
        let invalidToken = Self.bad("invalid_token", "The token is invalid or has expired.")
        let invalidEmail = Self.bad("invalid_email", "The email address is not valid.")
        let phase: String, destination: String, oldEmail: String
        if b.phase == "new_email" {
            guard let t = b.token, !t.isEmpty, t.utf8.count <= 512,
                  let prior = try await storeCall({ try await store.emailChange(tokenHash: Tokens.sha256(t)) }),
                  prior.phase == "old_email_verified", prior.accountId == account.id else { throw invalidToken }
            guard prior.email.lowercased() == account.email.lowercased() else { throw invalidEmail }
            phase = "new_email"
            destination = requested.lowercased()
            oldEmail = prior.email
        } else {
            guard requested.lowercased() == account.email.lowercased() else { throw invalidEmail }
            phase = "old_email"
            destination = account.email
            oldEmail = account.email
        }
        let cfg = config.changeEmail
        let window = Duration.seconds(cfg.sendIntervalSeconds)
        if await changeEmailLimits.send.isLimited(destination.lowercased(), window: window) {
            let minutes = max(1, (cfg.sendIntervalSeconds + 59) / 60)
            throw ServerError.http(status: 429, code: "email_change_rate_limit_exceeded",
                                   message: "Too many email change emails have been sent. Please try again in \(minutes) minutes.")
        }
        let code = Self.resetCode(), token = Tokens.random()
        try await storeCall {
            try await store.issueEmailChange(tokenHash: Tokens.sha256(token), accountId: account.id, email: destination, oldEmail: oldEmail,
                                             codeHash: Self.codeHash(token: token, code: code), phase: phase,
                                             expiresAt: Date().addingTimeInterval(Double(cfg.tokenMinutes) * 60))
        }
        outbox.post(MailTemplates.changeEmail(to: destination, code: code, minutes: cfg.tokenMinutes, newAddress: phase == "new_email",
                                              language: language), kind: "change email")
        await changeEmailLimits.send.record(destination.lowercased(), window: window)
        struct Sent: Encodable { var result = "success"; var data: String }
        return try json(Sent(data: token))
    }

    /// Dify's `verify_code`: a right code spends the token and answers the token of the next step (`old_email_verified`:
    /// send a code to the new address; `new_email_verified`: change).
    private func checkChangeEmailCode(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        struct Body: Decodable { var email: String?; var code: String?; var token: String? }
        let b = try await decode(req, Body.self, #"{"email","code","token"}"#)
        let email = try Self.email(b.email)
        let key = email.lowercased()
        let cfg = config.changeEmail
        if await changeEmailLimits.verify.isLocked(key, max: cfg.verifyMaxFailures) {
            throw ServerError.http(status: 429, code: "email_change_limit", message: "Too many failed email change attempts. Please try again in 24 hours.")
        }
        let invalidToken = Self.bad("invalid_token", "The token is invalid or has expired.")
        guard let token = b.token, !token.isEmpty, token.utf8.count <= 512,
              let stored = try await storeCall({ try await store.emailChange(tokenHash: Tokens.sha256(token)) }),
              stored.accountId == p.id else { throw invalidToken }
        guard stored.email.lowercased() == key else { throw Self.bad("invalid_email", "The email address is not valid.") }
        guard stored.phase == "old_email" || stored.phase == "new_email" else { throw invalidToken }
        guard let expected = stored.codeHash,
              Passwords.constantTimeEqual(Array(Self.codeHash(token: token, code: b.code ?? "").utf8), Array(expected.utf8)) else {
            await changeEmailLimits.verify.recordFailure(key, lockout: .seconds(cfg.lockoutSeconds))
            throw Self.bad("email_code_error", "Email code is invalid or expired.")
        }
        let next = Tokens.random()
        guard try await storeCall({
            try await store.promoteEmailChange(oldHash: Tokens.sha256(token), phase: stored.phase, newHash: Tokens.sha256(next),
                                               expiresAt: Date().addingTimeInterval(Double(cfg.tokenMinutes) * 60))
        }) else { throw invalidToken }
        await changeEmailLimits.verify.reset(key)
        struct Valid: Encodable { var is_valid = true; var email: String; var token: String }
        return try json(Valid(email: key, token: next))
    }

    /// Dify's `reset`: with the token of a right code for the new address, changes the account's email (stored lower-cased,
    /// as Dify) and mails the new address that it changed. Answers the account. Sessions stay (Dify's page signs out).
    private func changeEmail(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        struct Body: Decodable { var new_email: String?; var token: String? }
        let b = try await decode(req, Body.self, #"{"new_email","token"}"#)
        let newEmail = try Self.email(b.new_email).lowercased()
        let invalidToken = Self.bad("invalid_token", "The token is invalid or has expired.")
        guard let token = b.token, !token.isEmpty, token.utf8.count <= 512 else { throw invalidToken }
        let outcome = try await storeCall { try await store.changeEmail(tokenHash: Tokens.sha256(token), accountId: p.id, newEmail: newEmail) }
        switch outcome {
        case nil: throw invalidToken
        case .emailInUse: throw Self.bad("email_already_in_use", "A user with this email already exists.")
        case .notFound: throw Self.bad("account_not_found", "Account not found.")
        case .changed(let a):
            outbox.post(MailTemplates.changeEmailCompleted(to: newEmail, language: "en-US"), kind: "change email completed")
            return try json(Self.accountJSON(a))
        }
    }

    /// Dify's `check-email-unique`: `200 {"result":"success"}` if no account has the address, else `400
    /// email_already_in_use`. Needs a signed-in member (Dify's needs none; dify-sf does not tell strangers which addresses
    /// have accounts).
    private func checkEmailUnique(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        struct Body: Decodable { var email: String? }
        let email = try Self.email(try await decode(req, Body.self, #"{"email"}"#).email)
        if try await storeCall({ try await store.emailExists(email) }) {
            throw Self.bad("email_already_in_use", "A user with this email already exists.")
        }
        struct Done: Encodable { var result = "success" }
        return try json(Done())
    }
}
