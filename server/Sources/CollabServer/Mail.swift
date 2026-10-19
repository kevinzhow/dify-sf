import Configuration
import Foundation
import Logging
import NIOPosix
import SwiftSMTP

/// Outgoing mail, Dify's `MAIL_TYPE=smtp` (api/extensions/ext_mail.py, libs/smtp.py). Mail is configured when a host and a
/// sender address are set (`COLLAB_MAIL_SMTP_HOST`, `COLLAB_MAIL_FROM`); without them the server sends nothing and says so
/// (`GET /v1/system-features`: `is_email_setup` false, Dify's `MAIL_TYPE` unset).
public struct MailConfig: Sendable {
    /// Dify's `SMTP_USE_TLS` + `SMTP_OPPORTUNISTIC_TLS`: `ssl` = implicit TLS (`use_tls` alone, `SMTP_SSL`), `starttls` = plain
    /// connection upgraded with STARTTLS, which must succeed (`use_tls` + `opportunistic_tls`), `none` = plaintext.
    public enum TLSMode: String, Sendable, CaseIterable {
        case ssl, starttls, none
    }

    /// `SMTP_SERVER`. Empty = no mail.
    public var smtpHost: String
    /// `SMTP_PORT`; 0 = the TLS mode's usual port (465, 587, 25).
    public var smtpPort: Int
    public var tls: TLSMode
    /// `SMTP_USERNAME` / `SMTP_PASSWORD`: the server authenticates only when both are non-blank (as Dify).
    public var username: String
    public var password: String
    /// `MAIL_DEFAULT_SEND_FROM`, e.g. `Dify <no-reply@example.com>` or a bare address.
    public var from: String
    /// Connection timeout (Dify's smtplib `timeout=10`).
    public var timeoutSeconds: Int

    public init(reader: ConfigReader) {
        smtpHost = reader.string(forKey: "collab.mail.smtp.host", default: "").trimmingCharacters(in: .whitespaces)
        smtpPort = reader.int(forKey: "collab.mail.smtp.port", default: 0)
        tls = TLSMode(rawValue: reader.string(forKey: "collab.mail.smtp.tls", default: "ssl").lowercased()) ?? .ssl
        username = reader.string(forKey: "collab.mail.smtp.username", default: "")
        password = reader.string(forKey: "collab.mail.smtp.password", isSecret: true, default: "")
        from = reader.string(forKey: "collab.mail.from", default: "").trimmingCharacters(in: .whitespaces)
        timeoutSeconds = reader.int(forKey: "collab.mail.timeoutSeconds", default: 10)
    }

    /// Dify's `is_email_setup`.
    public var isConfigured: Bool { !smtpHost.isEmpty && MailMessage.contact(from) != nil }

    public var port: Int {
        if smtpPort > 0 { return smtpPort }
        switch tls {
        case .ssl: return 465
        case .starttls: return 587
        case .none: return 25
        }
    }
}

/// One message: Dify's `mail.send(to=, subject=, html=)`.
public struct MailMessage: Sendable, Equatable {
    public var to: String
    public var subject: String
    public var html: String

    /// `Name <address>` or a bare address; nil if there is no address.
    static func contact(_ s: String) -> (name: String?, address: String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let open = t.lastIndex(of: "<"), t.hasSuffix(">") {
            let address = String(t[t.index(after: open)..<t.index(before: t.endIndex)]).trimmingCharacters(in: .whitespaces)
            let name = t[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard address.contains("@") else { return nil }
            return (name.isEmpty ? nil : name, address)
        }
        return t.contains("@") && !t.contains(" ") ? (nil, t) : nil
    }
}

/// Sends mail. Implementations: `SMTPMailSender`.
public protocol MailSender: Sendable {
    func send(_ message: MailMessage) async throws
}

/// SMTP through swift-smtp's `Mailer` (ESMTP, AUTH LOGIN when credentials are set, message bodies base64 so that any
/// language and line length goes through).
public struct SMTPMailSender: MailSender {
    let mailer: Mailer
    let sender: Email.Contact

    public init?(config: MailConfig) {
        guard config.isConfigured, let from = MailMessage.contact(config.from) else { return nil }
        let encryption: SwiftSMTP.Configuration.Server.Encryption = switch config.tls {
        case .ssl: .ssl
        case .starttls: .startTLS(.always)
        case .none: .plain
        }
        let user = config.username.trimmingCharacters(in: .whitespaces), pass = config.password
        let credentials = !user.isEmpty && !pass.trimmingCharacters(in: .whitespaces).isEmpty
            ? SwiftSMTP.Configuration.Credentials(username: user, password: pass) : nil
        let configuration = SwiftSMTP.Configuration(
            server: .init(hostname: config.smtpHost, port: config.port, encryption: encryption),
            connectionTimeOut: .seconds(Int64(max(1, config.timeoutSeconds))),
            credentials: credentials,
            featureFlags: [.useESMTP, .base64EncodeAllMessages, .maximumBase64LineLength76])
        // No connection limit: with one (swift-smtp's default, 2) the Mailer holds a DispatchSemaphore that it signals from a
        // `[weak self]` callback after each send; a Mailer released before that callback runs (a sender is made per request
        // and dropped once the send is handed off) is deallocated with the semaphore below its initial value, and libdispatch
        // kills the process ("Semaphore object deallocated while in use"). Mail volume here is tiny and rate-limited.
        mailer = Mailer(group: MultiThreadedEventLoopGroup.singleton, configuration: configuration, maxConnections: nil)
        sender = Email.Contact(name: from.name.map(Self.headerText), emailAddress: from.address)
    }

    public func send(_ message: MailMessage) async throws {
        try await mailer.send(Email(sender: sender, recipients: [Email.Contact(emailAddress: message.to)],
                                    subject: Self.headerText(message.subject), body: .html(message.html)))
    }

    /// A header value as is when it is ASCII, else an RFC 2047 encoded word (swift-smtp writes headers verbatim).
    static func headerText(_ s: String) -> String {
        s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}

/// Dify's password-reset mails (api/templates/reset_password_mail_template_*.html and
/// reset_password_mail_when_account_not_exist_no_register_template_*.html, libs/email_i18n.py subjects), in Dify's two mail
/// languages: `zh-Hans`, anything else is `en-US`.
enum MailTemplates {
    static let applicationTitle = "Dify"

    static func isChinese(_ language: String) -> Bool { language == "zh-Hans" }

    /// `RESET_PASSWORD`: the code, valid for `minutes`.
    static func resetPassword(to: String, code: String, minutes: Int, language: String) -> MailMessage {
        let zh = isChinese(language)
        let subject = zh ? "设置您的 \(applicationTitle) 密码" : "Set Your \(applicationTitle) Password"
        let title = zh ? "设置您的 \(applicationTitle) 账户密码" : "Set your \(applicationTitle) password"
        let description = zh
            ? "复制并粘贴此验证码，注意验证码仅在接下来的 \(minutes) 分钟内有效。"
            : "Copy and paste this code, this code will only be valid for the next \(minutes) minutes."
        let tips = zh ? "如果您没有请求，请不要担心。您可以安全地忽略此电子邮件。" : "If you didn't request, don't worry. You can safely ignore this email."
        let html = page(body: """
            <p class="title">\(escape(title))</p>
                  <p class="description">\(escape(description))</p>
                  <div class="code-content">
                    <span class="code">\(escape(code))</span>
                  </div>
                  <p class="tips">\(escape(tips))</p>
            """)
        return MailMessage(to: to, subject: subject, html: html)
    }

    /// `RESET_PASSWORD_WHEN_ACCOUNT_NOT_EXIST_NO_REGISTER` (dify-sf has no sign-up, as Dify with registration off).
    static func resetPasswordUnknownAccount(to: String, language: String) -> MailMessage {
        let zh = isChinese(language)
        let subject = zh ? "重置您的 \(applicationTitle) 密码" : "Reset Your \(applicationTitle) Password"
        let lines = zh
            ? ["看起来您正在使用未注册的电子邮件重置密码", "您好，", "我们注意到您尝试重置密码，但此电子邮件未与任何账户关联。",
               "如果您没有请求此操作，您可以安全地忽略此电子邮件。", "请不要直接回复此电子邮件，它是由系统自动发送的。"]
            : ["It looks like you’re resetting a password with an unregistered email", "Hi,",
               "We noticed you tried to reset your password, but this email is not associated with any account.",
               "If you didn’t request this action, you can safely ignore this email.",
               "Please do not reply directly to this email, it is automatically sent by the system."]
        let html = page(body: """
            <p class="title">\(escape(lines[0]))</p>
                  <p class="description">\(escape(lines[1]))</p>
                  <p class="description">\(escape(lines[2]))</p>
                  <p class="description">\(escape(lines[3]))</p>
                  <p class="tips">\(escape(lines[4]))</p>
            """)
        return MailMessage(to: to, subject: subject, html: html)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The templates' page: Dify's styles and logo around `body`.
    static func page(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
          <head>
            <style>
              body { font-family: 'Arial', sans-serif; line-height: 16pt; color: #101828; background-color: #e9ebf0; margin: 0; padding: 0; }
              .container { width: 600px; margin: 40px auto; padding: 36px 48px; background-color: #fcfcfd; border-radius: 16px;
                border: 1px solid #ffffff; box-shadow: 0 2px 4px -2px rgba(9, 9, 11, 0.08); }
              .header { margin-bottom: 24px; }
              .header img { max-width: 100px; height: auto; }
              .title { font-weight: 600; font-size: 24px; line-height: 28.8px; }
              .description { font-size: 13px; line-height: 16px; color: #676f83; margin-top: 12px; }
              .code-content { padding: 16px 32px; text-align: center; border-radius: 16px; background-color: #f2f4f7; margin: 16px auto; }
              .code { line-height: 36px; font-weight: 700; font-size: 30px; }
              .tips { line-height: 16px; color: #676f83; font-size: 13px; }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="header">
                <img src="https://assets.dify.ai/images/logo.png" alt="Dify Logo" />
              </div>
              \(body)
            </div>
          </body>
        </html>
        """
    }
}

/// Sends in the background (Dify queues mail on Celery's `mail` queue): the request does not wait for the SMTP server, and
/// an answer takes as long whether the account exists or not. Failures are logged without the message.
struct MailOutbox: Sendable {
    let sender: (any MailSender)?
    let logger: Logger

    var isEnabled: Bool { sender != nil }

    func post(_ message: MailMessage, kind: String) {
        guard let sender else { return }
        let logger = logger
        Task.detached {
            do {
                try await sender.send(message)
                logger.info("sent \(kind) mail")
            } catch {
                logger.warning("sending \(kind) mail failed: \(error)")
            }
        }
    }
}
