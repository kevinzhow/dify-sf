import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Testing
import VaporTesting
@testable import CollabServer

// Dify's console human-input form API (protocol 1.16): GET returns the FormDefinition the recipient was given, POST
// answers it. Shapes from `controllers/console/human_input_form.py`; validation is the engine's own.

@Suite("Human input form routes", .enabled(if: testDbHost != nil))
struct HumanInputRouteTests {
    private static let inputs = #"[{"output_variable_name":"content","type":"paragraph"},{"output_variable_name":"grade","type":"select","option_source":{"type":"constant","value":["ok","bad"]}}]"#
    private static let actions = #"[{"id":"approve","title":"Approve","button_style":"primary"},{"id":"reject","title":"Reject"}]"#

    private func seed(_ store: PostgresStore, recipient: HumanInputRecipient = .console,
                      expiration: Int? = 1_900_000_000) async throws -> (doc: String, run: String) {
        let docId = "f-\(UUID().uuidString.lowercased().prefix(12))"
        _ = try await store.createDocument(id: docId, initial: Document(nodes: [Node(id: "human", type: "llm", config: [:])]))
        let runId = "run-\(UUID().uuidString.lowercased().prefix(12))"
        try await store.insertWorkflowRun(StoredWorkflowRun(
            id: runId, docId: docId, docSeq: 0, workflowId: docId, type: "workflow", triggeredFrom: "debugging",
            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: "u-1", createdAt: Date()))
        let at = Date()
        try await store.createPause(
            workflowRunId: runId, docId: docId, snapshot: "{}",
            forms: [StoredHumanInputForm(
                id: "form-1", workflowRunId: runId, executionId: "exec-1", docId: docId, nodeId: "human",
                nodeTitle: "Approval", token: "tok-1", formContent: #"Content {{#$output.content#}}"#,
                inputs: Self.inputs, userActions: Self.actions, renderedContent: "Please approve",
                defaultValues: #"{"content":""}"#, resolvedDefaultValues: #"{"content":""}"#, actions: Self.actions,
                displayInUi: true, expirationTime: expiration, createdAt: at, recipientType: recipient)], at: at)
        return (docId, runId)
    }

    @Test func returnsDifyFormDefinitionAndUnixSeconds() async throws {
        try await withServer { api, store, _ in
            _ = try await seed(store)
            let owner = try await api.setupOwner()
            let res = try await api.get("/v1/form/human_input/tok-1", token: owner)
            #expect(res.status == 200, "\(res.text)")
            #expect(res.str("form_content") == #"Content {{#$output.content#}}"#)
            #expect(res.str("rendered_content") == "Please approve")
            // `expiration_time` is a JSON number of seconds (Dify: `int(form.expiration_time.timestamp())`).
            #expect(res.json["expiration_time"] == .int(1_900_000_000), "Unix seconds, not a timestamp string")
            #expect(res.list("inputs").count == 2)
            #expect(res.list("user_actions").count == 2)
            #expect(res.obj("default_values")["content"] == .string(""))
            #expect(res.str("node_title") == "Approval")
            #expect(res.json["display_in_ui"] == .bool(true))
        }
    }

    @Test func anUnknownTokenIsNotFoundAndNoTokenIsUnauthorized() async throws {
        try await withServer { api, store, _ in
            _ = try await seed(store)
            let owner = try await api.setupOwner()
            let unknown = try await api.get("/v1/form/human_input/nope", token: owner)
            #expect(unknown.status == 404, "\(unknown.text)")
            let anonymous = try await api.get("/v1/form/human_input/tok-1")
            #expect(anonymous.status == 401, "\(anonymous.text)")
        }
    }

    @Test func answersOnceAndWakesTheRun() async throws {
        try await withServer { api, store, _ in
            let (_, run) = try await seed(store)
            let owner = try await api.setupOwner()
            let ok = try await api.post("/v1/form/human_input/tok-1", #"{"inputs":{"content":"looks good","grade":"ok"},"action":"approve"}"#,
                                        token: owner)
            #expect(ok.status == 200 && ok.text.trimmingCharacters(in: .whitespacesAndNewlines) == "{}", "\(ok.text)")

            let stored = try await store.humanInputForm(token: "tok-1")
            #expect(stored?.status == .submitted && stored?.submittedAction == "approve")
            #expect(stored?.submittedInputs?.contains("looks good") == true)
            // The route went through the store's wake rule: an answer asks for a resume.
            #expect(try await store.pause(workflowRunId: run, generation: 1)?.resumeRequested == true)

            let again = try await api.post("/v1/form/human_input/tok-1", #"{"inputs":{"content":"x","grade":"ok"},"action":"approve"}"#,
                                           token: owner)
            #expect(again.status == 412, "\(again.text)")
            #expect(again.text.contains("human_input_form_submitted"), "\(again.text)")
        }
    }

    @Test func consoleAndBackstageTokensAreServedAndAWebappTokenIsNot() async throws {
        // `human_input_policy.py`: the console surface allows console and backstage; only web apps are narrowed away.
        for recipient in [HumanInputRecipient.console, .backstage] {
            try await withServer { api, store, _ in
                _ = try await seed(store, recipient: recipient)
                let owner = try await api.setupOwner()
                let get = try await api.get("/v1/form/human_input/tok-1", token: owner)
                #expect(get.status == 200, "\(recipient): \(get.text)")
                let post = try await api.post("/v1/form/human_input/tok-1",
                                              #"{"inputs":{"content":"x","grade":"ok"},"action":"approve"}"#, token: owner)
                #expect(post.status == 200, "\(recipient): \(post.text)")
            }
        }
        try await withServer { api, store, _ in
            _ = try await seed(store, recipient: .webapp)
            let owner = try await api.setupOwner()
            // Dify's `_ensure_console_recipient_type`: a webapp/backstage token answers 404 here, like a foreign one,
            // even though the caller is signed in and the token exists.
            let get = try await api.get("/v1/form/human_input/tok-1", token: owner)
            #expect(get.status == 404, "\(get.text)")
            let post = try await api.post("/v1/form/human_input/tok-1", #"{"inputs":{"content":"x","grade":"ok"},"action":"approve"}"#,
                                          token: owner)
            #expect(post.status == 404, "\(post.text)")
            #expect(try await store.humanInputForm(token: "tok-1")?.status == .waiting)
        }
    }

    @Test func aSubmissionPastTheNodeDeadlineAnswersExpired() async throws {
        try await withServer { api, store, _ in
            let past = Int(Date().timeIntervalSince1970) - 60
            _ = try await seed(store, expiration: past)
            let owner = try await api.setupOwner()
            let res = try await api.post("/v1/form/human_input/tok-1", #"{"inputs":{"content":"x","grade":"ok"},"action":"approve"}"#,
                                         token: owner)
            #expect(res.status == 412, "\(res.text)")
            #expect(res.text.contains("human_input_form_expired"), "\(res.text)")
            #expect(try await store.humanInputForm(token: "tok-1")?.status == .waiting, "the scanner marks the timeout")
        }
    }

    @Test func theActiveCheckRunsBeforeFieldValidation() async throws {
        try await withServer { api, store, _ in
            _ = try await seed(store)
            let owner = try await api.setupOwner()
            let first = try await api.post("/v1/form/human_input/tok-1", #"{"inputs":{"content":"x","grade":"ok"},"action":"approve"}"#,
                                           token: owner)
            #expect(first.status == 200, "\(first.text)")

            // 1. GET after the answer: `get_form_definition_by_token_for_console` → `_ensure_not_submitted`.
            let get = try await api.get("/v1/form/human_input/tok-1", token: owner)
            #expect(get.status == 412, "\(get.text)")
            #expect(get.text.contains("human_input_form_submitted"), "\(get.text)")

            // 2. A repeated submission with an unknown action: 412, because `ensure_form_active` runs before validation.
            let unknownAction = try await api.post("/v1/form/human_input/tok-1",
                                                   #"{"inputs":{"content":"x","grade":"ok"},"action":"no-such-action"}"#, token: owner)
            #expect(unknownAction.status == 412, "\(unknownAction.text)")
            #expect(unknownAction.text.contains("human_input_form_submitted"), "\(unknownAction.text)")
        }
    }

    @Test func anExpiredFormAnswersExpiredBeforeAnInvalidValueIsChecked() async throws {
        try await withServer { api, store, _ in
            let past = Int(Date().timeIntervalSince1970) - 60
            _ = try await seed(store, expiration: past)
            let owner = try await api.setupOwner()
            // An invalid select value on an expired form: Dify's `ensure_form_active` comes first, so 412 not 400.
            let res = try await api.post("/v1/form/human_input/tok-1",
                                         #"{"inputs":{"content":"x","grade":"not-an-option"},"action":"approve"}"#, token: owner)
            #expect(res.status == 412, "\(res.text)")
            #expect(res.text.contains("human_input_form_expired"), "\(res.text)")
            #expect(try await store.humanInputForm(token: "tok-1")?.status == .waiting)
        }
    }

    @Test func invalidAnswersAreRejectedAndLeaveTheFormWaiting() async throws {
        try await withServer { api, store, _ in
            _ = try await seed(store)
            let owner = try await api.setupOwner()

            // A missing field, an unknown action and a select value outside its options: Dify's 400 invalid_form_data.
            for body in [#"{"inputs":{"grade":"ok"},"action":"approve"}"#,
                         #"{"inputs":{"content":"x","grade":"ok"},"action":"nope"}"#,
                         #"{"inputs":{"content":"x","grade":"meh"},"action":"approve"}"#,
                         #"{"inputs":"nope","action":"approve"}"#] {
                let res = try await api.post("/v1/form/human_input/tok-1", body, token: owner)
                #expect(res.status == 400, "\(body): \(res.text)")
                #expect(res.text.contains("invalid_form_data"), "\(res.text)")
            }
            #expect(try await store.humanInputForm(token: "tok-1")?.status == .waiting, "nothing was written")
        }
    }
}
