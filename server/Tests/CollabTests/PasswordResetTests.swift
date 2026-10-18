import CollabCore
import CollabStore
import Configuration
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing
@testable import CollabServer

// MARK: - Stub SMTP server

/// One message the stub SMTP server accepted.
struct StubMail: Sendable {
    var from: String
    var to: [String]
    /// The DATA section as sent (headers, then the base64 body).
    var data: String
    /// `AUTH LOGIN` credentials of the session, if it authenticated.
    var auth: (user: String, password: String)?

    var subject: String {
        data.split(separator: "\r\n").first { $0.hasPrefix("Subject: ") }.map { String($0.dropFirst(9)) } ?? ""
    }

    /// The body as text: every run of base64 lines decoded (headers and MIME boundaries are not base64).
    var text: String {
        var out = "", run = ""
        func flush() {
            if !run.isEmpty, let d = Data(base64Encoded: run), let s = String(data: d, encoding: .utf8) { out += s }
            run = ""
        }
        let b64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let body = data.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        for line in body.components(separatedBy: "\r\n") {
            if !line.isEmpty && line.unicodeScalars.allSatisfy(b64.contains) { run += line } else { flush() }
        }
        flush()
        return out
    }

    /// The six-digit code in the body (the template's `<span class="code">`), if any.
    var code: String? {
        guard let r = text.range(of: #"class="code">[0-9]{6}<"#, options: .regularExpression) else { return nil }
        return String(text[r].dropFirst(13).prefix(6))
    }
}

/// What the stub received.
final class StubMailbox: Sendable {
    private let mails = Mutex<[StubMail]>([])

    func add(_ m: StubMail) { mails.withLock { $0.append(m) } }
    var all: [StubMail] { mails.withLock { $0 } }

    /// The messages once there are at least `count` (mail goes out in the background), or what arrived within 5 s.
    func wait(for count: Int) async throws -> [StubMail] {
        for _ in 0..<250 {
            let now = all
            if now.count >= count { return now }
            try await Task.sleep(for: .milliseconds(20))
        }
        return all
    }
}

/// A minimal SMTP server on 127.0.0.1 (no TLS) that accepts every message, for `body(port, mailbox)`. No mail leaves the
/// machine.
func withStubSMTP<T: Sendable>(_ body: @Sendable (Int, StubMailbox) async throws -> T) async throws -> T {
    let box = StubMailbox()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(host: "127.0.0.1", port: 0) { channel in
            channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel) }
        }
    let port = server.channel.localAddress?.port ?? 0
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { connections in
                    for try await connection in inbound {
                        connections.addTask { try? await serveSMTP(connection, box) }
                    }
                }
            }
            return nil
        }
        let result = try await body(port, box)
        group.cancelAll()
        return result
    }!
}

private func serveSMTP(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>, _ box: StubMailbox) async throws {
    try await connection.executeThenClose { inbound, outbound in
        func reply(_ s: String) async throws { try await outbound.write(ByteBuffer(string: s + "\r\n")) }
        func base64(_ s: String) -> String { Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        try await reply("220 stub.local ESMTP")
        var pending: [UInt8] = []
        var inData = false, data: [String] = [], from = "", to: [String] = []
        var authStep = 0, user = "", auth: (user: String, password: String)?
        for try await var buffer in inbound {
            pending += buffer.readBytes(length: buffer.readableBytes) ?? []
            while let i = pending.indices.dropLast().first(where: { pending[$0] == 13 && pending[$0 + 1] == 10 }) {
                let line = String(decoding: pending[..<i], as: UTF8.self)
                pending.removeFirst(i + 2)
                if inData {
                    if line == "." {
                        box.add(StubMail(from: from, to: to, data: data.joined(separator: "\r\n"), auth: auth))
                        inData = false
                        data = []
                        to = []
                        try await reply("250 OK queued")
                    } else {
                        data.append(line.hasPrefix("..") ? String(line.dropFirst()) : line)
                    }
                    continue
                }
                if authStep == 1 {
                    user = base64(line)
                    authStep = 2
                    try await reply("334 UGFzc3dvcmQ6")
                    continue
                }
                if authStep == 2 {
                    auth = (user, base64(line))
                    authStep = 0
                    try await reply("235 2.7.0 Authentication successful")
                    continue
                }
                let upper = line.uppercased()
                if upper.hasPrefix("EHLO") {
                    try await reply("250-stub.local\r\n250-AUTH LOGIN PLAIN\r\n250 8BITMIME")
                } else if upper.hasPrefix("HELO") {
                    try await reply("250 stub.local")
                } else if upper.hasPrefix("AUTH LOGIN") {
                    authStep = 1
                    try await reply("334 VXNlcm5hbWU6")
                } else if upper.hasPrefix("MAIL FROM:") {
                    from = String(line.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
                    try await reply("250 OK")
                } else if upper.hasPrefix("RCPT TO:") {
                    to.append(String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: " <>")))
                    try await reply("250 OK")
                } else if upper == "DATA" {
                    inData = true
                    try await reply("354 End data with <CR><LF>.<CR><LF>")
                } else if upper == "QUIT" {
                    try await reply("221 Bye")
                    return
                } else {
                    try await reply("250 OK")
                }
            }
        }
    }
}

/// The server's configuration with mail through the stub on `port` (plaintext).
func stubMailConfig(port: Int, _ base: ServerConfig = .defaults, username: String = "", password: String = "") -> ServerConfig {
    var cfg = base
    cfg.mail.smtpHost = "127.0.0.1"
    cfg.mail.smtpPort = port
    cfg.mail.tls = .none
    cfg.mail.from = "Dify <no-reply@example.com>"
    cfg.mail.username = username
    cfg.mail.password = password
    return cfg
}

// MARK: - Without a database

/// Mail configuration, templates, SMTP through the stub, and the forgot-password limits (Dify's rules), without Postgres.
@Suite("Password reset")
struct PasswordResetUnitTests {
    @Test func mailIsConfiguredByHostAndSender() {
        let reader = ConfigReader(provider: InMemoryProvider(values: [
            "collab.mail.smtp.host": "smtp.example.com", "collab.mail.from": "Dify <no-reply@example.com>",
            "collab.mail.smtp.tls": "starttls", "collab.mail.smtp.username": "u", "collab.mail.smtp.password": "p",
        ]))
        let m = MailConfig(reader: reader)
        #expect(m.isConfigured && m.tls == .starttls && m.port == 587 && m.username == "u")
        var none = ServerConfig.defaults.mail
        #expect(!none.isConfigured && none.tls == .ssl && none.port == 465)
        none.smtpHost = "smtp.example.com"
        #expect(!none.isConfigured)  // no sender address
        none.from = "no-reply@example.com"
        #expect(none.isConfigured)
        none.smtpPort = 2525
        #expect(none.port == 2525)
        #expect(MailMessage.contact("Dify <a@b.io>")?.name == "Dify" && MailMessage.contact("Dify <a@b.io>")?.address == "a@b.io")
        #expect(MailMessage.contact("a@b.io")?.name == nil && MailMessage.contact("a@b.io")?.address == "a@b.io")
        #expect(MailMessage.contact("not an address") == nil)
        #expect(SMTPMailSender.headerText("Set Your Dify Password") == "Set Your Dify Password")
        #expect(SMTPMailSender.headerText("设置") == "=?UTF-8?B?6K6+572u?=")
    }

    @Test func templatesAreDifys() {
        let en = MailTemplates.resetPassword(to: "a@b.io", code: "123456", minutes: 5, language: "en-US")
        #expect(en.subject == "Set Your Dify Password" && en.to == "a@b.io")
        #expect(en.html.contains("123456") && en.html.contains("valid for the next 5 minutes"))
        let zh = MailTemplates.resetPassword(to: "a@b.io", code: "654321", minutes: 5, language: "zh-Hans")
        #expect(zh.subject == "设置您的 Dify 密码" && zh.html.contains("654321") && zh.html.contains("5 分钟"))
        let unknown = MailTemplates.resetPasswordUnknownAccount(to: "x@b.io", language: "ja-JP")
        #expect(unknown.subject == "Reset Your Dify Password" && unknown.html.contains("not associated with any account"))
        #expect(!unknown.html.contains(#"class="code""#))
        #expect(MailTemplates.resetPasswordUnknownAccount(to: "x@b.io", language: "zh-Hans").html.contains("未与任何账户关联"))
    }

    @Test func smtpGoesThroughTheStub() async throws {
        try await withStubSMTP { port, box in
            let cfg = stubMailConfig(port: port, username: "mailer", password: "s3cret")
            let sender = try #require(SMTPMailSender(config: cfg.mail))
            try await sender.send(MailTemplates.resetPassword(to: "someone@example.com", code: "424242", minutes: 5, language: "zh-Hans"))
            let mails = try await box.wait(for: 1)
            #expect(mails.count == 1)
            let m = try #require(mails.first)
            #expect(m.from == "no-reply@example.com" && m.to == ["someone@example.com"])
            #expect(m.auth?.user == "mailer" && m.auth?.password == "s3cret")
            #expect(m.code == "424242" && m.text.contains("设置您的 Dify 账户密码"))
            #expect(m.subject.hasPrefix("=?UTF-8?B?"))
            // No credentials: no AUTH (Dify logs in only with both).
            let anonymous = try #require(SMTPMailSender(config: stubMailConfig(port: port, username: "mailer").mail))
            try await anonymous.send(MailMessage(to: "b@example.com", subject: "Hi", html: "<p>hi</p>"))
            #expect(try await box.wait(for: 2).last?.auth == nil)
        }
    }

    @Test func codesAreSixDigits() {
        let codes = Set((0..<50).map { _ in Routes.resetCode() })
        #expect(codes.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isNumber) } && codes.count > 40)
        #expect(Routes.codeHash(token: "t", code: "123456") != Routes.codeHash(token: "u", code: "123456"))
    }

    @Test func theIPLimitIsDifys() async {
        let l = EmailSendIPLimiter()
        // Dify counts a request only while the count is not above the limit: limit + 1 requests pass in a minute.
        for _ in 0..<3 { #expect(await !l.isLimited("1.2.3.4", perMinute: 2)) }
        #expect(await l.isLimited("1.2.3.4", perMinute: 2))
        #expect(await !l.isLimited("5.6.7.8", perMinute: 2))
        #expect(await l.isLimited("1.2.3.4", perMinute: 2))  // the second excess freezes the IP for an hour
        #expect(await l.isLimited("1.2.3.4", perMinute: 1000))
    }

    @Test func theSendAndVerifyLimitsAreDifys() async throws {
        let send = SendIntervalLimiter()
        #expect(await !send.isLimited("a@x.io", window: .seconds(1)))
        await send.record("a@x.io", window: .seconds(1))
        #expect(await send.isLimited("a@x.io", window: .seconds(1)))
        #expect(await !send.isLimited("b@x.io", window: .seconds(1)))
        let verify = VerifyFailureLimiter()
        for _ in 0..<5 { await verify.recordFailure("a@x.io", lockout: .seconds(1)) }
        #expect(await !verify.isLocked("a@x.io", max: 5))  // locked when MORE than 5
        await verify.recordFailure("a@x.io", lockout: .seconds(1))
        #expect(await verify.isLocked("a@x.io", max: 5))
        await verify.reset("a@x.io")
        #expect(await !verify.isLocked("a@x.io", max: 5))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(await !send.isLimited("a@x.io", window: .seconds(1)))
    }
}

// MARK: - Routes

/// Forgot password and reset links against Postgres, the real routes and the stub SMTP server.
@Suite("Password reset routes", .enabled(if: testDbHost != nil))
struct PasswordResetRouteTests {
    /// A config with mail through the stub and no send interval (tests send several codes in a row).
    static func mailing(_ port: Int, _ change: (inout ServerConfig) -> Void = { _ in }) -> ServerConfig {
        var cfg = stubMailConfig(port: port)
        cfg.passwordReset.sendIntervalSeconds = 0
        change(&cfg)
        return cfg
    }

    @Test func systemFeaturesSayWhetherMailIsSetUp() async throws {
        try await withServer { api, _, _ in
            let f = try await api.get("/v1/system-features")
            #expect(f.status == 200 && f.json["is_email_setup"] == .bool(false) && f.json["enable_email_password_login"] == .bool(true))
            #expect(f.json["enable_email_code_login"] == .bool(false) && f.json["is_allow_register"] == .bool(false))
            _ = try await api.setupOwner()
            let send = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#)
            #expect(send.status == 400 && send.errorCode == "mail_not_configured")
        }
        try await withServer(config: stubMailConfig(port: 1)) { api, _, _ in
            let features = try await api.get("/v1/system-features")
            #expect(features.json["is_email_setup"] == .bool(true))
        }
    }

    @Test func aCodeByMailResetsThePasswordAndEndsEverySession() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port) { $0.mail.username = "mailer"; $0.mail.password = "pw" }) { api, _, _ in
                let owner = try await api.setupOwner(email: "Owner@Example.com", password: "owner-pass-1")
                let other = try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#).str("access_token")
                #expect(try await api.post("/v1/forgot-password", #"{"email":"not-an-email"}"#).status == 400)
                let sent = try await api.post("/v1/forgot-password", #"{"email":"OWNER@example.com","language":"en-US"}"#)
                #expect(sent.status == 200 && sent.str("result") == "success")
                let token = sent.str("data")
                let mail = try #require(try await box.wait(for: 1).first)
                #expect(mail.to == ["Owner@Example.com"] && mail.subject == "Set Your Dify Password" && mail.auth?.user == "mailer")
                let code = try #require(mail.code)
                let wrong = code == "000000" ? "111111" : "000000"

                func check(_ email: String, _ code: String, _ token: String) async throws -> API.Answer {
                    try await api.post("/v1/forgot-password/validity", #"{"email":"\#(email)","code":"\#(code)","token":"\#(token)"}"#)
                }
                let bad = try await check("owner@example.com", wrong, token)
                #expect(bad.status == 400 && bad.errorCode == "email_code_error")
                let otherEmail = try await check("someone@example.com", code, token)
                #expect(otherEmail.status == 400 && otherEmail.errorCode == "invalid_email")
                #expect(try await check("owner@example.com", code, "garbage").errorCode == "invalid_token")
                let ok = try await check("owner@EXAMPLE.com", code, token)
                #expect(ok.status == 200 && ok.json["is_valid"] == .bool(true) && ok.str("email") == "owner@example.com")
                let resetToken = ok.str("token")
                #expect(!resetToken.isEmpty && resetToken != token)
                // The code's token is spent; the reset token is not a code token.
                #expect(try await check("owner@example.com", code, token).errorCode == "invalid_token")
                #expect(try await check("owner@example.com", code, resetToken).errorCode == "invalid_token")

                func reset(_ token: String, _ p: String, _ c: String) async throws -> API.Answer {
                    try await api.post("/v1/forgot-password/resets", #"{"token":"\#(token)","new_password":"\#(p)","password_confirm":"\#(c)"}"#)
                }
                #expect(try await reset(resetToken, "short1", "short1").errorCode == "invalid_password")
                #expect(try await reset(resetToken, "new-pass-123", "new-pass-124").errorCode == "password_mismatch")
                #expect(try await reset(token, "new-pass-123", "new-pass-123").errorCode == "invalid_token")
                let done = try await reset(resetToken, "new-pass-123", "new-pass-123")
                #expect(done.status == 200 && done.str("result") == "success")
                #expect(try await reset(resetToken, "new-pass-456", "new-pass-456").errorCode == "invalid_token")
                // Every session of the account is over; the new password signs in, the old one does not.
                #expect(try await api.get("/v1/account", token: owner).status == 401)
                #expect(try await api.get("/v1/account", token: other).status == 401)
                #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#).status == 401)
                #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"new-pass-123"}"#).status == 200)
            }
        }
    }

    @Test func unknownEmailsGetTheSameAnswer() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port) { $0.passwordReset.sendIntervalSeconds = 60 }) { api, _, _ in
                _ = try await api.setupOwner(email: "owner@example.com")
                let known = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#)
                let unknown = try await api.post("/v1/forgot-password", #"{"email":"nobody@example.com","language":"zh-Hans"}"#)
                #expect(known.status == 200 && unknown.status == 200)
                #expect(Set(known.json.keys) == Set(unknown.json.keys) && unknown.str("result") == "success" && !unknown.str("data").isEmpty)
                #expect(known.str("data").count == unknown.str("data").count)
                let mails = try await box.wait(for: 2)
                let notice = try #require(mails.first { $0.to == ["nobody@example.com"] })
                #expect(notice.code == nil && notice.text.contains("未与任何账户关联"))
                // No code was sent, so none matches; the reset never happens.
                let check = try await api.post("/v1/forgot-password/validity",
                                               #"{"email":"nobody@example.com","code":"123456","token":"\#(unknown.str("data"))"}"#)
                #expect(check.status == 400 && check.errorCode == "email_code_error")
                // The send limit holds for both alike.
                let again = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#)
                let againUnknown = try await api.post("/v1/forgot-password", #"{"email":"NOBODY@example.com"}"#)
                #expect(again.status == 429 && again.errorCode == "password_reset_rate_limit_exceeded")
                #expect(againUnknown.status == again.status && againUnknown.text == again.text)
                #expect(again.text.contains("try again in 1 minutes"))
            }
        }
    }

    @Test func oneMailPerAddressPerIntervalAndTheLatestCodeCounts() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port) { $0.passwordReset.sendIntervalSeconds = 1 }) { api, _, _ in
                _ = try await api.setupOwner(email: "owner@example.com")
                let first = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#)
                #expect(first.status == 200)
                #expect(try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#).status == 429)
                try await Task.sleep(for: .milliseconds(1100))
                let second = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#)
                #expect(second.status == 200)
                let mails = try await box.wait(for: 2)
                #expect(mails.count == 2)
                let firstCode = try #require(mails.first?.code)
                // A new code replaces the earlier one (Dify's current token per account).
                let stale = try await api.post("/v1/forgot-password/validity",
                                               #"{"email":"owner@example.com","code":"\#(firstCode)","token":"\#(first.str("data"))"}"#)
                #expect(stale.errorCode == "invalid_token")
                let secondCode = try #require(mails.last?.code)
                let fresh = try await api.post("/v1/forgot-password/validity",
                                               #"{"email":"owner@example.com","code":"\#(secondCode)","token":"\#(second.str("data"))"}"#)
                #expect(fresh.status == 200)
            }
        }
    }

    @Test func tooManyMailsFromOneIPAreRefused() async throws {
        try await withStubSMTP { port, _ in
            try await withServer(config: Self.mailing(port) { $0.passwordReset.emailSendIpLimitPerMinute = 2 }) { api, _, _ in
                _ = try await api.setupOwner()
                for i in 0..<3 {
                    #expect(try await api.post("/v1/forgot-password", #"{"email":"user\#(i)@example.com"}"#).status == 200)
                }
                let refused = try await api.post("/v1/forgot-password", #"{"email":"user9@example.com"}"#)
                #expect(refused.status == 429 && refused.errorCode == "email_send_ip_limit")
            }
        }
    }

    @Test func wrongCodesLockTheEmail() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port) { $0.passwordReset.lockoutSeconds = 2 }) { api, _, _ in
                _ = try await api.setupOwner(email: "owner@example.com")
                let token = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#).str("data")
                let code = try #require(try await box.wait(for: 1).first?.code)
                let wrong = code == "000000" ? "111111" : "000000"
                func check(_ c: String) async throws -> API.Answer {
                    try await api.post("/v1/forgot-password/validity", #"{"email":"owner@example.com","code":"\#(c)","token":"\#(token)"}"#)
                }
                for _ in 0..<6 { #expect(try await check(wrong).errorCode == "email_code_error") }
                // More than 5 failures: locked, even with the right code, until the lockout passes.
                let locked = try await check(code)
                #expect(locked.status == 429 && locked.errorCode == "email_password_reset_limit")
                try await Task.sleep(for: .milliseconds(2200))
                #expect(try await check(code).status == 200)
            }
        }
    }

    @Test func codesExpire() async throws {
        try await withStubSMTP { port, box in
            // 0 minutes: the code is expired as soon as it is sent (Dify's RESET_PASSWORD_TOKEN_EXPIRY_MINUTES, 5 by default).
            try await withServer(config: Self.mailing(port) { $0.passwordReset.tokenMinutes = 0 }) { api, _, _ in
                _ = try await api.setupOwner(email: "owner@example.com")
                let token = try await api.post("/v1/forgot-password", #"{"email":"owner@example.com"}"#).str("data")
                let code = try #require(try await box.wait(for: 1).first?.code)
                try await Task.sleep(for: .milliseconds(50))
                let expired = try await api.post("/v1/forgot-password/validity",
                                                 #"{"email":"owner@example.com","code":"\#(code)","token":"\#(token)"}"#)
                #expect(expired.status == 400 && expired.errorCode == "invalid_token")
            }
        }
    }

    @Test func adminsHandOutResetLinks() async throws {
        // No mail server: the link is the way (and works without mail).
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner(email: "owner@example.com", password: "owner-pass-1")
            let me = try await api.get("/v1/account", token: owner)
            let ownerId = me.str("id")
            let (adminId, admin) = try await api.member("admin@example.com", role: "admin", inviter: owner)
            let (editorId, editor) = try await api.member("editor@example.com", role: "editor", name: "Ed", password: "editor-pass-1", inviter: owner)
            func link(_ member: String, by token: String) async throws -> API.Answer {
                try await api.post("/v1/workspace/members/\(member)/reset-password-link", token: token)
            }
            #expect(try await link(adminId, by: editor).status == 403)
            #expect(try await api.post("/v1/workspace/members/\(editorId)/reset-password-link").status == 401)
            let ownerByAdmin = try await link(ownerId, by: admin)
            #expect(ownerByAdmin.status == 403 && ownerByAdmin.errorCode == "forbidden")
            #expect(try await link("no-such-member", by: admin).status == 404)
            #expect(try await link(ownerId, by: owner).status == 201)  // the owner, for itself
            #expect(try await link(adminId, by: admin).status == 201)  // oneself
            let first = try await link(editorId, by: admin)
            #expect(first.status == 201 && !first.str("expires_at").isEmpty)
            let second = try await link(editorId, by: owner)
            func token(_ a: API.Answer) -> String { a.str("url").components(separatedBy: "token=").last ?? "" }
            #expect(first.str("url").hasPrefix("/reset-password/set-password?email=editor%40example.com&token="))
            func reset(_ t: String, _ p: String) async throws -> API.Answer {
                try await api.post("/v1/forgot-password/resets", #"{"token":"\#(t)","new_password":"\#(p)","password_confirm":"\#(p)"}"#)
            }
            // A newer link replaces the older one; a link works once; it ends the member's sessions.
            #expect(try await reset(token(first), "editor-new-1").errorCode == "invalid_token")
            #expect(try await reset(token(second), "editor-new-1").status == 200)
            #expect(try await reset(token(second), "editor-new-2").errorCode == "invalid_token")
            #expect(try await api.get("/v1/account", token: editor).status == 401)
            #expect(try await api.post("/v1/auth/login", #"{"email":"editor@example.com","password":"editor-new-1"}"#).status == 200)
            #expect(try await api.get("/v1/account", token: admin).status == 200)  // other accounts keep their sessions
        }
    }

    @Test func resetLinksExpireAndActivateInvitedAccounts() async throws {
        var expiring = ServerConfig.defaults
        expiring.passwordReset.linkHours = 0
        try await withServer(config: expiring) { api, _, _ in
            let owner = try await api.setupOwner()
            let (editorId, _) = try await api.member("editor@example.com", role: "editor", inviter: owner)
            let t = try await api.post("/v1/workspace/members/\(editorId)/reset-password-link", token: owner).str("url")
                .components(separatedBy: "token=").last ?? ""
            try await Task.sleep(for: .milliseconds(50))
            let expired = try await api.post("/v1/forgot-password/resets", #"{"token":"\#(t)","new_password":"abc-12345","password_confirm":"abc-12345"}"#)
            #expect(expired.errorCode == "invalid_token")
        }
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let inv = try await api.post("/v1/workspace/members/invite-email", #"{"emails":["new@example.com"],"role":"normal"}"#, token: owner)
            guard case .map(let r)? = inv.list("invitation_results").first, case .string(let url)? = r["url"] else {
                Issue.record("no invitation: \(inv.text)"); return
            }
            let invitation = url.components(separatedBy: "token=").last ?? ""
            let members = try await api.get("/v1/workspace/members", token: owner).list("accounts")
            let pendingId = members.compactMap { m -> String? in
                guard case .map(let a) = m, a["email"] == .string("new@example.com"), case .string(let id)? = a["id"] else { return nil }
                return id
            }.first ?? ""
            let t = try await api.post("/v1/workspace/members/\(pendingId)/reset-password-link", token: owner).str("url")
                .components(separatedBy: "token=").last ?? ""
            #expect(try await api.post("/v1/forgot-password/resets", #"{"token":"\#(t)","new_password":"abc-12345","password_confirm":"abc-12345"}"#).status == 200)
            let login = try await api.post("/v1/auth/login", #"{"email":"new@example.com","password":"abc-12345"}"#)
            #expect(login.status == 200)
            #expect(try await api.get("/v1/account", token: login.str("access_token")).status == 200)
            // The account has a password now: its invitation link is spent.
            #expect(try await api.post("/v1/activate/check", #"{"token":"\#(invitation)"}"#).json["is_valid"] == .bool(false))
        }
    }
}
