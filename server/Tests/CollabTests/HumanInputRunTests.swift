import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

/// A draft run that reaches a human-input node (protocol 1.16): the pause and its forms are durable before the stream
/// publishes `human_input_required` / `workflow_paused`, and answering the form wakes the run. The resume execution
/// itself is not wired yet, so these tests stop at "the run is paused, answerable, and asked for a resume".
@Suite("Human input pause publication", .enabled(if: testDbHost != nil))
struct HumanInputRunTests {
    static func appYAML() -> String {
        """
        app:
          mode: workflow
          name: hitl-run
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
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables: []
            - id: human
              data:
                title: Approve
                type: human-input
                form_content: 'Please approve {{#$output.reply#}}'
                inputs:
                - {type: paragraph, output_variable_name: reply}
                user_actions:
                - {id: approve, title: Approve it, button_style: primary}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: reply, value_selector: [human, reply]}
        """
    }

    static func frames(_ sse: String) -> [JSONValue] {
        sse.components(separatedBy: "\n\n").compactMap { frame in
            let line = frame.split(separator: "\n").first { $0.hasPrefix("data: ") }
            guard let line else { return nil }
            return try? JSONValue.parse(Data(line.dropFirst(6).utf8))
        }
    }

    @Test func thePauseIsDurableBeforeItIsPublishedAndTheFormWakesTheRun() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let imported = try await api.post("/v1/docs/import", Self.appYAML(), token: owner)
            let app = imported.str("id")
            #expect(!app.isEmpty, "import: \(imported.text)")

            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            #expect(run.status == 200, "\(run.text)")
            let events = Self.frames(run.text).compactMap { $0["event"]?.string }
            // The order the server guarantees: the form first, then the pause that names it.
            #expect(events.contains("human_input_required"), "\(events)")
            #expect(events.contains("workflow_paused"), "\(events)")
            if let required = events.firstIndex(of: "human_input_required"), let paused = events.firstIndex(of: "workflow_paused") {
                #expect(required < paused, "the form is published before the pause: \(events)")
            }
            #expect(!events.contains("workflow_finished"), "a paused run has not finished: \(events)")

            // Durable side: the run is paused with one generation and one form, whose token the stream carried.
            let paused = Self.frames(run.text).first { $0["event"]?.string == "human_input_required" }?["data"]?.object
            let token = paused?["form_token"]?.string ?? ""
            #expect(!token.isEmpty)
            let form = try await store.humanInputForm(token: token)
            #expect(form?.status == .waiting)
            #expect(form?.nodeId == "human")
            #expect(form?.renderedContent.contains("Please approve") == true)
            #expect(try await store.workflowRun(doc: app, id: form?.workflowRunId ?? "")?.status == "paused")
            let pause = try await store.pause(workflowRunId: form?.workflowRunId ?? "", generation: 1)
            #expect(pause?.resumeRequested == false)
            #expect(pause?.executionIds == [form?.executionId ?? ""])

            // Answering it through the API is accepted and asks for a resume.
            let answer = try await api.post("/v1/form/human_input/\(token)",
                                            #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
            #expect(answer.status == 200, "\(answer.text)")
            #expect(try await store.pause(workflowRunId: form?.workflowRunId ?? "", generation: 1)?.resumeRequested == true)
            #expect(try await store.humanInputForm(token: token)?.status == .submitted)

            // The answer resumes the run in the background: the human node completes with the submitted value and the run
            // goes on to its end node.
            let runId = form?.workflowRunId ?? ""
            var status = ""
            for _ in 0..<200 where status != "succeeded" && status != "failed" {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
            }
            #expect(status == "succeeded", "the resumed run should finish, got \(status)")
            let stored = try await store.workflowRun(doc: app, id: runId)
            #expect(stored?.outputs?.contains("ok") == true, "the end node sees the submitted value: \(stored?.outputs ?? "nil")")
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty, "the pause is closed by the resume")
            let executions = try await store.nodeExecutions(doc: app, run: runId)
            #expect(executions.contains { $0.nodeId == "human" && $0.status == "succeeded" })
            #expect(executions.contains { $0.nodeId == "end" }, "the run continued past the human node")
        }
    }
}
