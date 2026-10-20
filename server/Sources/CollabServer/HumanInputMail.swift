import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Logging

/// Dify's human-input email delivery (`tasks/mail_human_input_delivery_task.py`), on the server's own mail sender: every
/// form whose node enables the email method is mailed to that method's recipients, **after** the pause is durable.
///
/// Deviations, both deliberate and recorded here: Dify mints a per-recipient token (one link each) while this server sends
/// the form's own token; and the body is used as text with its `{{#url#}}` placeholder filled in, wrapped in a small
/// `<pre>` rather than run through Dify's markdown pipeline (no markdown/HTML sanitiser in this server).
enum HumanInputMail {
    /// One address and the delivery method it came from (its subject and body are that method's).
    struct Recipient: Sendable, Equatable {
        var email: String
        /// The index of the enabled email method that names this address.
        var method: Int
        /// `member` (a workspace account, `referenceId`) or `external`.
        var type: String
        var referenceId: String?
    }

    /// The recipients of a node's enabled email delivery methods, deduplicated by address and in the order the node lists
    /// them: a `member` item is the workspace member `reference_id` names, an `external` item carries its own address, and
    /// `include_bound_group` (Dify's `whole_workspace`) adds every member of the workspace. [members] maps account id to
    /// email.
    static func recipients(_ deliveryMethods: [JSONObject], members: [String: String]) -> [Recipient] {
        var out: [Recipient] = []
        func add(_ raw: String?, _ method: Int, type: String = "external", referenceId: String? = nil) {
            guard let raw else { return }
            let address = MailMessage.contact(raw)?.address ?? raw
            guard address.contains("@"), !out.contains(where: { $0.email.caseInsensitiveCompare(address) == .orderedSame })
            else { return }
            out.append(Recipient(email: address, method: method, type: type, referenceId: referenceId))
        }
        for (index, method) in deliveryMethods.enumerated()
        where method["type"]?.string == "email" && (method["enabled"]?.bool ?? false) {
            let recipients = method["config"]?["recipients"]?.object ?? [:]
            if (recipients["include_bound_group"]?.bool ?? false) || (recipients["whole_workspace"]?.bool ?? false) {
                for id in members.keys.sorted() { add(members[id], index, type: "member", referenceId: id) }
            }
            for item in recipients["items"]?.array ?? [] {
                switch item["type"]?.string {
                case "member":
                    let id = item["reference_id"]?.string
                    add(id.flatMap { members[$0] }, index, type: "member", referenceId: id)
                case "external": add(item["email"]?.string, index, type: "external")
                default: add(item["email"]?.string, index) // no type: the address it carries, as older nodes wrote them
                }
            }
        }
        return out
    }

    /// `subject` and `body` of the method that named the recipient. The body's `{{#url#}}` is the recipient's link and
    /// its other `{{#node.var#}}` references come from the pause's pool (Dify's `render_body_template`); the subject is
    /// sanitized, not templated (`sanitize_subject`).
    static func message(_ deliveryMethods: [JSONObject], methodIndex: Int, to email: String, link: String,
                        pool: VariablePool? = nil) -> MailMessage? {
        guard deliveryMethods.indices.contains(methodIndex) else { return nil }
        let method = deliveryMethods[methodIndex]
        guard method["type"]?.string == "email", method["enabled"]?.bool ?? false else { return nil }
        let config = method["config"]?.object ?? [:]
        let subject = sanitizeSubject(config["subject"]?.string ?? "")
        guard !subject.isEmpty else { return nil }
        // The template's own markup never reaches the message (Dify's `bleach.clean(body, tags=[], ...)` runs **before**
        // the variables are rendered). Stripping the rendered text instead would also eat a value that legitimately
        // carries `<` — an answer, a URL with a query — so the order matters.
        var escaped = config["body"]?.string ?? ""
        escaped = escaped.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        var body = escaped.replacingOccurrences(of: "{{#url#}}", with: link)
        if let pool { body = VariableTemplate.convert(pool, body).markdown }
        return MailMessage(to: email, subject: subject, html: renderBody(body))
    }

    /// Dify's `sanitize_subject`: no line breaks, no HTML, one line.
    static func sanitizeSubject(_ subject: String) -> String {
        let flat = subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let noTags = flat.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return noTags.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Dify's `render_markdown_body`: HTML in the template is stripped, the result is rendered as markdown, and the HTML is
    /// confined to the tags a mail may carry. This is a **subset** of markdown (paragraphs, emphasis, inline code, http(s)
    /// and mailto links, flat lists); tables and raw HTML are not rendered — recorded as a deviation in the protocol.
    static func renderBody(_ body: String) -> String {
        // The template was cleaned of its markup before the variables were filled in (`message`), so what is rendered here
        // is text plus whatever the values carry.
        let text = body
        var html: [String] = []
        var list: (tag: String, items: [String])?
        func flushList() {
            guard let current = list else { return }
            html.append("<" + current.tag + ">" + current.items.map { "<li>" + inline($0) + "</li>" }.joined() + "</" + current.tag + ">")
            list = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushList(); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if list?.tag != "ul" { flushList(); list = ("ul", []) }
                list?.items.append(String(line.dropFirst(2)))
                continue
            }
            if line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                if list?.tag != "ol" { flushList(); list = ("ol", []) }
                let item = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                list?.items.append(item)
                continue
            }
            flushList()
            html.append("<p>" + inline(line) + "</p>")
        }
        flushList()
        return html.joined(separator: "\n")
    }

    /// Inline markdown: `**strong**`, `*em*`, `` `code` ``, `[text](http…)`. Everything else is escaped text — including
    /// what a rendered value carries (`a<b` becomes `a&lt;b`, a URL's `&` becomes `&amp;`, which a mail client shows as
    /// the original character).
    static func inline(_ line: String) -> String {
        var out = escape(line)
        out = out.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<!\*)\*([^*]+)\*(?!\*)"#, with: "<em>$1</em>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"\[([^\]]+)\]\((https?://[^)\s]+|mailto:[^)\s]+)\)"#,
            with: #"<a href="$2">$1</a>"#, options: .regularExpression)
        return out
    }

    /// The link Dify sends: `APP_WEB_URL.rstrip('/') + "/form/" + token`.
    static func link(base: String, token: String) -> String? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix("/") ? trimmed + "form/" + token : trimmed + "/form/" + token
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
