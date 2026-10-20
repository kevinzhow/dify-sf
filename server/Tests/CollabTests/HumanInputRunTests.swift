import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
import Vapor
import VaporTesting
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

    /// start -> {approve1, approve2} -> end: both human nodes are ready at once, so one pause carries two forms and the
    /// resume can be asked the question that matters — does it decide only what its claim took?
    static func twoFormsYAML() -> String {
        """
        app:
          mode: workflow
          name: hitl-two
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: approve1, targetHandle: target}
            - {id: e2, source: start, sourceHandle: source, target: approve2, targetHandle: target}
            - {id: e3, source: approve1, sourceHandle: approve, target: end, targetHandle: target}
            - {id: e4, source: approve2, sourceHandle: approve, target: end, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables: []
            - id: approve1
              data:
                title: First
                type: human-input
                form_content: 'First {{#$output.reply#}}'
                inputs:
                - {type: paragraph, output_variable_name: reply}
                user_actions:
                - {id: approve, title: Approve, button_style: primary}
            - id: approve2
              data:
                title: Second
                type: human-input
                form_content: 'Second {{#$output.reply#}}'
                inputs:
                - {type: paragraph, output_variable_name: reply}
                user_actions:
                - {id: approve, title: Approve, button_style: primary}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: reply, value_selector: [approve2, reply]}
        """
    }

    @Test func aResumeDecidesOnlyWhatItsClaimTookAndTheOtherFormPausesAgain() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.twoFormsYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let required = Self.frames(run.text).filter { $0["event"]?.string == "human_input_required" }
            #expect(required.count == 2, "one pause with two forms: \(required.count)")
            let tokens = required.compactMap { $0["data"]?["form_token"]?.string }
            #expect(tokens.count == 2)
            var forms: [StoredHumanInputForm?] = []
            for token in tokens { forms.append(try await store.humanInputForm(token: token)) }
            let first = try #require(forms.first { $0?.nodeId == "approve1" } ?? nil)
            let second = try #require(forms.first { $0?.nodeId == "approve2" } ?? nil)

            // Answer only the first: the resume takes that decision, the second node pauses again with the form it had.
            let answer = try await api.post("/v1/form/human_input/\(first.token)", #"{"inputs":{"reply":"one"},"action":"approve"}"#,
                                            token: owner)
            #expect(answer.status == 200, "\(answer.text)")
            var secondGeneration = 0
            for _ in 0..<200 where secondGeneration == 0 {
                try await Task.sleep(for: .milliseconds(25))
                let open = try await store.openPauses(workflowRunId: first.workflowRunId)
                secondGeneration = open.first?.generation ?? 0
            }
            #expect(secondGeneration == 2, "the second node pauses again as a new generation")
            let adopted = try await store.humanInputForm(token: second.token)
            #expect(adopted?.id == second.id && adopted?.token == second.token, "the waiting form is adopted, not replaced")
            #expect(adopted?.status == .waiting)
            #expect(try await store.workflowRun(doc: app, id: first.workflowRunId)?.status == "paused")

            // Answer the second: now the run ends.
            let last = try await api.post("/v1/form/human_input/\(second.token)", #"{"inputs":{"reply":"two"},"action":"approve"}"#,
                                          token: owner)
            #expect(last.status == 200, "\(last.text)")
            var status = ""
            for _ in 0..<200 where status != "succeeded" && status != "failed" {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(doc: app, id: first.workflowRunId)?.status ?? ""
            }
            #expect(status == "succeeded", "got \(status)")
            #expect(try await store.workflowRun(doc: app, id: first.workflowRunId)?.outputs?.contains("two") == true)
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

/// A pause that cannot be written must end the run and report it — never publish a pause nobody can answer, never keep
/// the run "paused" in the database. Driven through the routes with the server's test defect.
@Suite("Human input pause write failure", .enabled(if: testDbHost != nil))
struct HumanInputPauseWriteFailureTests {
    @Test func aFailedPauseWriteFailsTheRunAndPublishesNoPause() async throws {
        var config = ServerConfig.defaults
        config.testDefect = "pauseWriteFails"
        try await withServer(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(run.text)
            let events = frames.compactMap { $0["event"]?.string }
            #expect(events.contains("workflow_failed"), "\(events)")
            #expect(!events.contains("human_input_required"), "no form is offered when the pause is not durable: \(events)")
            #expect(!events.contains("workflow_paused"), "\(events)")

            let runId = frames.first { $0["event"]?.string == "workflow_failed" }?["data"]?["id"]?.string ?? ""
            #expect(!runId.isEmpty)
            // Durable side: the run is failed, nothing is paused, no form exists to answer.
            #expect(try await store.workflowRun(doc: app, id: runId)?.status == "failed")
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty)
            #expect(try await store.humanInputForms(workflowRunId: runId).isEmpty)
        }
    }
}

/// Dify's reconnect endpoint: a paused run is described from its records (no frame table), a finished one answers a single
/// `workflow_finished`, and someone else's run is not found.
@Suite("Run events reconnect", .enabled(if: testDbHost != nil))
struct RunEventsReconnectTests {
    @Test func aPausedRunIsRebuiltFromItsRecordsAndAFinishedOneAnswersOneFrame() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""
            #expect(!runId.isEmpty)

            // Reconnect to the paused run: the state comes from the run, node, form and pause records.
            let reconnect = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: owner)
            #expect(reconnect.status == 200, "\(reconnect.text)")
            let events = HumanInputRunTests.frames(reconnect.text).compactMap { $0["event"]?.string }
            #expect(events.first == "workflow_started", "\(events)")
            #expect(events.contains("node_finished"), "\(events)")
            #expect(events.contains("human_input_required"), "\(events)")
            #expect(events.last == "workflow_paused", "close_on_pause ends the stream at the pause: \(events)")
            let rebuiltToken = HumanInputRunTests.frames(reconnect.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string
            #expect(rebuiltToken == token, "the same form, same token")

            // Answer it, let the run finish, then reconnect again: one frame and close.
            _ = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
            var status = ""
            for _ in 0..<200 where status != "succeeded" {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
            }
            #expect(status == "succeeded")
            let finished = try await api.get("/v1/workflow/\(runId)/events", token: owner)
            let finishedEvents = HumanInputRunTests.frames(finished.text)
            #expect(finishedEvents.count == 1, "\(finishedEvents.count) frames for a finished run")
            #expect(finishedEvents.first?["event"]?.string == "workflow_finished")
            #expect(finishedEvents.first?["data"]?["status"]?.string == "succeeded")
        }
    }

    @Test func theSnapshotIsOffByDefaultAndExplicitlyRequested() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""

            // Dify's default: no state snapshot. A paused run with close_on_pause then has nothing to send.
            let silent = try await api.get("/v1/workflow/\(runId)/events", token: owner)
            #expect(silent.status == 200, "\(silent.text)")
            #expect(HumanInputRunTests.frames(silent.text).isEmpty, "no history without include_state_snapshot: \(silent.text)")

            // Asked for explicitly, the state is rebuilt from the records.
            let snapshot = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: owner)
            let events = HumanInputRunTests.frames(snapshot.text).compactMap { $0["event"]?.string }
            #expect(events.first == "workflow_started", "\(events)")
            #expect(events.last == "workflow_paused", "\(events)")
        }
    }

    @Test func onlyTheCreatorMayFollowTheRun() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""

            // A real second member of the same workspace: signed in, but not the run's creator.
            let colleague = try await api.member("colleague@example.com", role: "normal", name: "Colleague", inviter: owner)
            let asColleague = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: colleague.token)
            #expect(asColleague.status == 404, "someone else's run is not found: \(asColleague.text)")

            let asOwner = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: owner)
            #expect(asOwner.status == 200, "\(asOwner.text)")
            #expect(!HumanInputRunTests.frames(asOwner.text).isEmpty)

            let unknown = try await api.get("/v1/workflow/no-such-run/events", token: owner)
            #expect(unknown.status == 404, "\(unknown.text)")
            let anonymous = try await api.get("/v1/workflow/\(runId)/events")
            #expect(anonymous.status == 401, "\(anonymous.text)")
        }
    }
}

/// The registry lease: a resumed round registers its own engine under the run's task id, and a round that finishes late
/// must not remove its successor (which would make `stop` answer for a run that is still going).
@Suite("Run registry lease")
struct RunRegistryLeaseTests {
    @Test func onlyTheOwningRoundRemovesItsEntry() async {
        let registry = WorkflowRunRegistry()
        let commands = GraphEngineCommands()
        await registry.add("run-1", WorkflowRunRegistry.Active(appId: "app", runId: "run-1", commands: commands, lease: "round-1"))
        // Round 2 takes the run over after the resume.
        await registry.add("run-1", WorkflowRunRegistry.Active(appId: "app", runId: "run-1", commands: commands, lease: "round-2"))
        await registry.remove("run-1", lease: "round-1")
        #expect(await registry.get("run-1")?.lease == "round-2", "a late round-1 must not delete round-2")
        await registry.remove("run-1", lease: "round-2")
        #expect(await registry.get("run-1") == nil)
    }
}

/// A real restart: the first server instance pauses a run and answers it while no instance is up to enqueue the resume;
/// a **second instance over the same database** picks it up on startup and finishes it.
@Suite("Human input resume across a real restart", .enabled(if: testDbHost != nil))
struct HumanInputRealRestartTests {
    @Test func theSecondInstanceResumesWhatTheFirstLeftAnswered() async throws {
        try await withStore { store, logger in
            let config = ServerConfig.defaults
            func instance() throws -> CollabServer.Routes {
                try CollabServer.Routes(registry: DocumentRegistry(store: store, config: config, logger: logger), store: store,
                           config: config, logger: logger)
            }

            var app = ""
            var runId = ""
            var token = ""
            // Instance 1: serve the run until it pauses, then stop (the answer arrives with nothing running).
            let first = try instance()
            try await withApp(configure: { try first.register(on: $0) }) { application in
                try await application.testing { client in
                    let api = API(client: client)
                    let owner = try await api.setupOwner()
                    app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
                    let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                    token = HumanInputRunTests.frames(run.text)
                        .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
                }
            }
            runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""
            #expect(!runId.isEmpty)
            // The answer lands with no server to enqueue it: exactly what a stopped process leaves.
            let answered = try await store.submitHumanInputForm(token: token, inputs: #"{"reply":"ok"}"#, action: "approve",
                                                               userId: "u-1")
            guard case .accepted = answered else {
                Issue.record("the answer must be accepted, got \(answered)")
                return
            }
            #expect(try await store.runsAwaitingResume().map(\.runId) == [runId])

            // Instance 2: a fresh server (its own registry, routes and application) over the same database.
            let second = try instance()
            try await withApp(configure: { try second.register(on: $0) }) { _ in
                let resumed = await second.resumeRunsWaitingAfterRestart()
                #expect(resumed == 1)
                var status = ""
                for _ in 0..<200 where status != "succeeded" && status != "failed" {
                    try await Task.sleep(for: .milliseconds(25))
                    status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
                }
                #expect(status == "succeeded", "the second instance should finish the run, got \(status)")
                #expect(try await store.runsAwaitingResume().isEmpty)
            }
        }
    }
}
