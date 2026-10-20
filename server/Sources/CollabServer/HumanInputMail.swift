import CollabCore
import CollabMarkdown
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
        let subject = MailMarkdown.sanitizeSubject(config["subject"]?.string ?? "")
        guard !subject.isEmpty else { return nil }
        // The template's own markup never reaches the message (Dify's `bleach.clean(body, tags=[], ...)` runs **before**
        // the variables are rendered). Stripping the rendered text instead would also eat a value that legitimately
        // carries `<` — an answer, a URL with a query — so the order matters.
        var body = MailMarkdown.cleanTemplate(config["body"]?.string ?? "")
        body = body.replacingOccurrences(of: "{{#url#}}", with: link)
        if let pool { body = VariableTemplate.convert(pool, body).markdown }
        return MailMessage(to: email, subject: subject, html: MailMarkdown.render(body))
    }

    /// Dify's `sanitize_subject`: no line breaks, no HTML, one line (the shared implementation).
    static func sanitizeSubject(_ subject: String) -> String { MailMarkdown.sanitizeSubject(subject) }

    /// Dify's `render_markdown_body`: the template is cleaned of its own markup, the values are escaped, and the result is
    /// rendered by a real CommonMark parser (`MailMarkdown`) into the tags a mail may carry. The old regex renderer is
    /// gone: it produced attributes out of link text and missed every block construct (Winnie's review).
    static func renderBody(_ body: String) -> String { MailMarkdown.render(body) }

    /// The link Dify sends: `APP_WEB_URL.rstrip('/') + "/form/" + token`.
    static func link(base: String, token: String) -> String? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix("/") ? trimmed + "form/" + token : trimmed + "/form/" + token
    }

    static func escape(_ text: String) -> String { MailMarkdown.escape(text) }
}
