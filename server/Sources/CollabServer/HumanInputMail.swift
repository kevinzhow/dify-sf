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

    /// `subject` and `body` of the method that named the recipient, with `{{#url#}}` replaced
    /// (`EmailDeliveryConfig.replace_url_placeholder`).
    static func message(_ deliveryMethods: [JSONObject], methodIndex: Int, to email: String, link: String) -> MailMessage? {
        guard deliveryMethods.indices.contains(methodIndex) else { return nil }
        let method = deliveryMethods[methodIndex]
        guard method["type"]?.string == "email", method["enabled"]?.bool ?? false else { return nil }
        let config = method["config"]?.object ?? [:]
        let subject = (config["subject"]?.string ?? "").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let body = (config["body"]?.string ?? "").replacingOccurrences(of: "{{#url#}}", with: link)
        guard !subject.isEmpty else { return nil }
        let html = "<div style=\"white-space:pre-wrap\">" + escape(body) + "</div>"
        return MailMessage(to: email, subject: subject, html: html)
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
