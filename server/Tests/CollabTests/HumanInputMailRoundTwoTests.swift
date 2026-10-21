import CollabCore
import CollabStore
import Foundation
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

/// The second round's mail regressions (Winnie): what the mail says, what an expired link does, whether a test mail that
/// failed says so, and whether a restart's undelivered mail is ever sent.
@Suite("Human input mail, second round", .enabled(if: testDbHost != nil))
struct HumanInputMailRoundTwoTests {
    /// The email delivery method's id in [yaml] (the panel sends the node's own method id).
    static let emailMethodId = "email"

    /// start → human (approve → end, timeout → end) → end, with one email method.
    /// `body` is the method's body template; `enabled` turns the method on or off.
    static func yaml(body: String, enabled: Bool = true, subject: String = "Approve please") -> String {
        """
        app:
          mode: workflow
          name: hitl-mail
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
            - {id: e2, source: human, sourceHandle: approve, target: end, targetHandle: target}
            - {id: e3, source: human, sourceHandle: timeout, target: end, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables:
                - {label: who, required: false, type: text-input, variable: who}
            - id: human
              data:
                title: Approve
                type: human-input
                form_content: 'Please approve {{#$output.reply#}}'
                inputs:
                - {type: paragraph, output_variable_name: reply}
                user_actions:
                - {id: approve, title: Approve it, button_style: primary}
                delivery_methods:
                - {type: webapp, enabled: true}
                - id: email
                  type: email
                  enabled: \(enabled)
                  config:
                    subject: \(subject)
                    body: \(body)
                    recipients:
                      items:
                      - {type: external, email: one@example.test}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: reply, value_selector: [human, reply]}
        """
    }

    /// The template's own markup never reaches the message, but a **value** that carries a `<` does: the body is cleaned
    /// before the variables are rendered (Dify's `bleach.clean` order), not after. A URL with a query string in the body
    /// must survive whole.
    @Test func theTemplateIsSanitizedBeforeTheValuesAreFilledIn() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withHumanInputServer(config: config) { api, store, _ in
                let owner = try await api.setupOwner()
                // The template carries markup; the start input carries `<` in its value and a link with a query string.
                let app = try await api.post("/v1/docs/import", Self.yaml(
                    body: "'<script>alert(1)</script>Who: \"{{#start.who#}}\" Link: https://example.test/a?b=1&c=2 <b>bold</b>'"),
                                             token: owner).str("id")
                _ = try await api.post("/v1/apps/\(app)/workflows/draft/run",
                                       ##"{"inputs":{"who":"a<b"}}"##, token: owner)
                let mails = try await mailbox.wait(for: 1)
                let mail = try #require(mails.first)
                let text = mail.text
                #expect(!text.contains("<script>"), "the template's script tag is not in the mail")
                #expect(!text.contains("<b>bold</b>"), "the template's markup is not in the mail")
                let expected = "Who: \"a&lt;b\""
                #expect(text.contains(expected),
                        "a value that carries < keeps it (HTML-escaped in the markup, read back as typed): \(text)")
                #expect(text.contains("https://example.test/a?b=1&amp;c=2") || text.contains("https://example.test/a?b=1&c=2"),
                        "the link survives whole: \(text)")
            }
        }
    }

    /// A link whose deadline passed does not open the form (412 `human_input_form_expired`), and the answer is refused
    /// the same way — the console's view and the recipient's agree.
    @Test func anExpiredLinkIsRefused() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withHumanInputServerAndRoutes(config: config) { api, store, routes in
                let owner = try await api.setupOwner()
                let app = try await api.post("/v1/docs/import", Self.yaml(body: "'Approve {{#url#}}'"), token: owner).str("id")
                _ = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
                let mails = try await mailbox.wait(for: 1)
                let mail = try #require(mails.first)
                let token = try #require(
                    mail.text.split(separator: "/form/").last.map { String($0.prefix { $0 != "<" && $0 != "\"" && !$0.isWhitespace }) })
                let form = try #require(try await store.formRecipient(token: token)?.form)
                // The token the mail carried is the recipient row's, not the form's (a form may have several recipients).
                let formToken = try #require((try await store.humanInputForm(id: form.id))?.token)
                // Past the deadline: the form was due a minute ago. The product's own scan ends it (as it does every few
                // seconds), and then the link refuses — Dify's `_ensure_not_expired` is the same 412 either way.
                let past = Int(Date().timeIntervalSince1970) - 60
                try await store.setHumanInputFormExpiration(token: formToken, at: past)
                let moved = try await store.humanInputForm(id: form.id)
                #expect(moved?.expirationTime != nil && moved!.expirationTime! < Int(Date().timeIntervalSince1970),
                        "the deadline moved: \(String(describing: moved?.expirationTime))")
                await routes.sweepHumanInputTimeouts(now: Date())
                let read = try await api.get("/v1/form/human_input/\(token)")
                #expect(read.status == 412, "an expired link does not open the form: \(read.text)")
                #expect(read.errorCode == "human_input_form_expired")
                let answer = try await api.post("/v1/form/human_input/\(token)",
                                                ##"{"inputs":{"reply":"late"},"action":"approve"}"##)
                #expect(answer.status == 412, "and it cannot be answered: \(answer.text)")
                #expect(answer.errorCode == "human_input_form_expired", "\(answer.text)")
                // The console surface keeps Dify's own rule: its token needs a session, and with one it still reads the
                // definition (only the submit path checks the deadline there, as Dify's console does).
                // (A recipient token is not a console token: the console surface only serves the console's own, so this
                // token is 404 with a session — the recipient row is what the link is.)
                let asConsole = try await api.get("/v1/form/human_input/\(token)", token: owner)
                #expect(asConsole.status == 404, "a recipient token is not served on the console surface: \(asConsole.text)")
                #expect(form.expirationTime != nil)
            }
        }
    }

    /// A test mail that cannot go out says so (502 `email_send_failed`), rather than a success the panel would trust.
    @Test func aTestMailThatCannotBeSentIsAnError() async throws {
        // No stub mail server on that port: the send fails.
        var config = stubMailConfig(port: 1)
        config.webAppBaseURL = "https://apps.example.test"
        try await withHumanInputServer(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.yaml(body: "'Approve {{#url#}}'"), token: owner).str("id")
            let payload = #"{"delivery_method_id":"\#(Self.emailMethodId)","inputs":{}}"#
            let response = try await api.post("/v1/apps/\(app)/workflows/draft/human-input/nodes/human/delivery-test",
                                              payload, token: owner)
            #expect(response.status == 502, "a failed test mail is not a success: \(response.status) \(response.text)")
            #expect(response.errorCode == "email_send_failed", "\(response.text)")
            // The delivery-test form exists (it was built), but its recipient never counts as mailed.
            let forms = try await store.humanInputFormsAwaitingMailCount()
            #expect(forms >= 1, "the recipient row is still waiting for its mail")
        }
    }

    /// A recipient row whose mail never went out (a pause written while the mail server was down, or a restart in the
    /// middle) is delivered by a later scan: the state is the row, not memory.
    @Test func aWaitingRecipientIsMailedByTheNextScan() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withHumanInputServerAndRoutes(config: config) { api, store, routes in
                let owner = try await api.setupOwner()
                let app = try await api.post("/v1/docs/import", Self.yaml(body: "'Approve {{#url#}}'"), token: owner).str("id")
                _ = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
                let first = try await mailbox.wait(for: 1)
                #expect(first.count == 1, "the pause mailed its recipient")
                let token = try #require(
                    first[0].text.split(separator: "/form/").last.map { String($0.prefix { $0 != "<" && $0 != "\"" && !$0.isWhitespace }) })
                let row = try #require(try await store.formRecipient(token: token))
                // The mail goes out in the background; the row records it once the send returns.
                var mailed = false
                for _ in 0..<250 where !mailed {
                    try await Task.sleep(for: .milliseconds(20))
                    mailed = try await store.formRecipient(token: token)?.recipient.mailedAt != nil
                }
                #expect(mailed, "the pause's mail went out and the row says so")
                // As a crash between "row written" and "mail sent" leaves it: the same row, still waiting.
                try await store.resetFormRecipientMailed(token: row.recipient.token)
                let delivered = await routes.deliverPendingHumanInputMail()
                #expect(delivered >= 1, "the scan delivers what is waiting")
                let after = try await mailbox.wait(for: 2)
                #expect(after.count >= 2, "a second mail went out: \(after.count)")
                #expect(try await store.formRecipient(token: token)?.recipient.mailedAt != nil, "and the row records it")
                // A delivered row is not mailed again.
                let again = await routes.deliverPendingHumanInputMail()
                #expect(again == 0, "nothing waiting any more: \(again)")
            }
        }
    }

    /// Winnie's end-to-end flow: a pause mails a link, the link (no account) opens the **real** definition the server
    /// serves, the same definition renders in the page's form widget with its button, the answer goes through the public
    /// route, and the run finishes with it. Nothing here goes through the console API.
    @Test func theMailedLinkOpensTheRealDefinitionAndItsAnswerFinishesTheRun() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withHumanInputServer(config: config) { api, store, _ in
                let owner = try await api.setupOwner()
                let app = try await api.post("/v1/docs/import", Self.yaml(body: "'Approve please {{#url#}}'"), token: owner).str("id")
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
                let runId = try #require(HumanInputRunTests.frames(run.text).first?["workflow_run_id"]?.string)
                let mails = try await mailbox.wait(for: 1)
                let link = try #require(mails.first?.text.split(separator: "/form/").last.map {
                    String($0.prefix { $0 != "<" && $0 != "\"" && !$0.isWhitespace }) })
                // The recipient's token, anonymously: the console definition shape Dify's web surface serves.
                let anonymous = try await api.get("/v1/form/human_input/\(link)")
                #expect(anonymous.status == 200, "\(anonymous.text)")
                #expect(anonymous.json["user_actions"] != nil, "the console shape carries user_actions: \(anonymous.text)")
                #expect(anonymous.json["actions"] == nil, "and not the panel's actions: \(anonymous.text)")
                #expect(anonymous.str("node_title") == "Approve")
                // The answer goes through the same public route, and the run finishes with it.
                let answer = try await api.post("/v1/form/human_input/\(link)",
                                                ##"{"inputs":{"reply":"from the mail"},"action":"approve"}"##)
                #expect(answer.status == 200, "answer: \(answer.text)")
                var status = ""
                for _ in 0..<300 where status != "succeeded" && status != "failed" {
                    try await Task.sleep(for: .milliseconds(20))
                    status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
                }
                #expect(status == "succeeded", "the mailed answer finishes the run: \(status)")
                let detail = try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)", token: owner)
                let outputs = detail.obj("outputs")
                #expect(outputs["reply"] == .string("from the mail"), "\(detail.text)")
            }
        }
    }

    /// Winnie's independent regression: a run stopped while it waits makes its mailed link refuse too — the recipient
    /// surface runs Dify's `ensure_form_active`, not only the deadline. (The console surface keeps its own rule.)
    @Test func aStoppedRunsMailedLinkIsNoLongerAnswered() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withHumanInputServer(config: config) { api, store, _ in
                let owner = try await api.setupOwner()
                let app = try await api.post("/v1/docs/import", Self.yaml(body: "'Approve {{#url#}}'"), token: owner).str("id")
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
                let runId = try #require(HumanInputRunTests.frames(run.text).first?["workflow_run_id"]?.string)
                let mails = try await mailbox.wait(for: 1)
                let link = try #require(mails.first?.text.split(separator: "/form/").last.map {
                    String($0.prefix { $0 != "<" && $0 != "\"" && !$0.isWhitespace }) })
                let before = try await api.get("/v1/form/human_input/\(link)")
                #expect(before.status == 200, "while the run waits the link opens: \(before.text)")
                // The user stops the waiting run: its forms are closed (`expired`).
                let stop = try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(runId)/stop", "{}", token: owner)
                #expect(stop.status == 200, "\(stop.text)")
                let after = try await api.get("/v1/form/human_input/\(link)")
                #expect(after.status == 412, "a stopped run's link does not open a form: \(after.text)")
                #expect(after.errorCode == "human_input_form_expired", "\(after.text)")
                let answer = try await api.post("/v1/form/human_input/\(link)",
                                                ##"{"inputs":{"reply":"late"},"action":"approve"}"##)
                #expect(answer.status == 412, "and it cannot be answered: \(answer.text)")
                #expect(try await store.workflowRun(doc: app, id: runId)?.status == "stopped")
            }
        }
    }
}
