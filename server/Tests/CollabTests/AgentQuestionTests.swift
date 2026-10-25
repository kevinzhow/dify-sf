import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent questions use native workflow forms")
struct AgentQuestionTests {
    @Test func nativeFieldsDefaultsLabelsActionsAndEmailMatchTheQuestion() throws {
        let action = String(repeating: "approve_", count: 5)
        let q = try AgentQuestion(["title": "Review", "question": "Approve this?", "markdown": "Details", "urgency": "high",
            "fields": [["type": "paragraph", "name": "note", "label": "Comment", "required": true, "default": "Initial"],
                ["type": "select", "name": "grade", "label": "Grade", "options": [["label": "Accept", "value": "yes"]], "default": "yes"]],
            "actions": [["id": .string(action), "label": "Reject", "style": "destructive"]]], title: "Agent",
            contacts: [["method": "email", "email": "fixture@example.test"], ["method": "web_app", "email": "fixture@example.test"]])
        #expect(q.config.content.contains("**Comment ***\n\n{{#$output.note#}}"))
        #expect(q.config.inputs.first?["default"] == ["type": "constant", "value": "Initial"])
        #expect(q.defaults["grade"] == "yes")
        #expect(q.config.inputs.last?["option_labels"]?["yes"] == "Accept")
        #expect(q.config.actions.first?["button_style"] == "accent")
        let short = try #require(q.config.actions.first?["id"]?.string)
        #expect(short.count == 20 && q.actionIDs[short] == action)
        let mail = try #require(q.config.deliveryMethods.first { $0["type"] == "email" })
        #expect(mail["config"]?["recipients"]?["items"]?.array?.count == 1)
        #expect(mail["config"]?["subject"] == "[Action needed] Review")
    }
    @Test func timeoutResumesTheToolRatherThanTakingANativeTimeoutEdge() async throws {
        let q = try AgentQuestion(["question": "Continue?", "fields": [], "actions": []], title: "Agent", contacts: [])
        let form = StoredHumanInputForm(id: "form", workflowRunId: "run", executionId: "execution", docId: "app", nodeId: "agent", nodeTitle: "Agent",
            token: "token", formContent: q.config.content, inputs: "[]", userActions: "[]", renderedContent: q.config.content,
            actions: "[]", displayInUi: true, status: .timedOut, createdAt: Date(), questionID: "execution:q1")
        let answer = try await q.answer(form, files: nil)
        #expect(answer == ["status": "timeout"])
        #expect(q.config.actions.first?["id"] == "submit")
    }
}
