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
    /// The recipients of a node's enabled email delivery methods, deduplicated, in the order the node lists them.
    static func recipients(_ deliveryMethods: [JSONObject]) -> [String] {
        var out: [String] = []
        for method in deliveryMethods where method["type"]?.string == "email" && (method["enabled"]?.bool ?? false) {
            let items = method["config"]?["recipients"]?["items"]?.array ?? []
            for item in items {
                guard let email = item["email"]?.string else { continue }
                let address = MailMessage.contact(email)?.address ?? email
                if !address.contains("@") || out.contains(address) { continue }
                out.append(address)
            }
        }
        return out
    }

    /// `subject` and `body` as the node wrote them, with `{{#url#}}` replaced (`EmailDeliveryConfig.replace_url_placeholder`).
    static func message(_ deliveryMethods: [JSONObject], to recipient: String, link: String) -> MailMessage? {
        for method in deliveryMethods where method["type"]?.string == "email" && (method["enabled"]?.bool ?? false) {
            let config = method["config"]?.object ?? [:]
            let subject = (config["subject"]?.string ?? "").replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let body = (config["body"]?.string ?? "").replacingOccurrences(of: "{{#url#}}", with: link)
            guard !subject.isEmpty else { continue }
            let html = "<div style=\"white-space:pre-wrap\">" + escape(body) + "</div>"
            return MailMessage(to: recipient, subject: subject, html: html)
        }
        return nil
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
