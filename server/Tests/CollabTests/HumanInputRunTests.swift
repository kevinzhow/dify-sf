import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Synchronization
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

    /// Frames read off a raw socket: chunked transfer puts `size` lines between them, so this scans `data: ` lines
    /// instead of splitting on blank lines.
    static func wireFrames(_ text: String) -> [JSONValue] {
        var out: [JSONValue] = []
        var search = text.startIndex
        while let r = text.range(of: "data: ", range: search..<text.endIndex) {
            let start = r.upperBound
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            if let value = try? JSONValue.parse(Data(text[start..<end].utf8)) { out.append(value) }
            search = end
        }
        return out
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

/// The SSE contract of a pause, against Dify's own field sets and array types (not just "an event arrived"): a client that
/// parses the official stream must be able to parse ours.
@Suite("Human input SSE contract", .enabled(if: testDbHost != nil))
struct HumanInputSSEContractTests {
    static let requiredKeys: Set<String> = ["form_id", "node_id", "node_title", "form_content", "inputs", "actions",
                                            "display_in_ui", "form_token", "approval_channels", "resolved_default_values",
                                            "expiration_time"]
    static let pausedKeys: Set<String> = ["workflow_run_id", "paused_nodes", "outputs", "reasons", "status", "created_at",
                                          "elapsed_time", "total_tokens", "total_steps"]
    static let reasonKeys: Set<String> = ["TYPE", "form_id", "form_content", "inputs", "actions", "node_id", "node_title",
                                          "resolved_default_values", "form_token", "approval_channels", "expiration_time"]

    @Test func aPausePublishesDifyShapedFramesInOrder() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(run.text)
            let events = frames.compactMap { $0["event"]?.string }
            #expect(events.prefix(1) == ["workflow_started"], "\(events)")
            #expect(Array(events.suffix(2)) == ["human_input_required", "workflow_paused"], "\(events)")
            #expect(events.contains("node_finished"), "\(events)")

            let required = frames.first { $0["event"]?.string == "human_input_required" }?["data"]?.object ?? [:]
            #expect(Set(required.keys) == Self.requiredKeys, "extra/missing: \(Set(required.keys).symmetricDifference(Self.requiredKeys))")
            #expect(required["inputs"]?.array != nil && required["actions"]?.array != nil, "arrays, not objects")
            #expect(required["display_in_ui"]?.bool == true)

            let paused = frames.first { $0["event"]?.string == "workflow_paused" }?["data"]?.object ?? [:]
            #expect(Set(paused.keys) == Self.pausedKeys, "extra/missing: \(Set(paused.keys).symmetricDifference(Self.pausedKeys))")
            // `paused_nodes` is a list of node ids, not objects.
            #expect(paused["paused_nodes"]?.array?.allSatisfy { $0.string != nil } == true)
            #expect(paused["paused_nodes"]?.array?.first?.string == "human")
            #expect(paused["status"]?.string == "paused")
            let reason = paused["reasons"]?.array?.first?.object ?? [:]
            #expect(Set(reason.keys) == Self.reasonKeys, "extra/missing: \(Set(reason.keys).symmetricDifference(Self.reasonKeys))")
            #expect(reason["TYPE"]?.string == "human_input_required")
            #expect(reason["form_token"]?.string == required["form_token"]?.string, "the reason names the same form")

            // The same shape comes back from the record-based reconnect.
            let token = required["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""
            let reconnected = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: owner)
            let rebuilt = HumanInputRunTests.frames(reconnected.text)
            let rebuiltData = rebuilt.first { $0["event"]?.string == "human_input_required" }?["data"]?.object ?? [:]
            #expect(rebuiltData.keys.sorted() == required.keys.sorted(),
                    "the snapshot and the live stream project the same fields")
        }
    }
}

/// One live connection across two pauses (`continue_on_pause=true`): the run's channel outlives a round, so the second
/// pause arrives on the same stream instead of being filtered as a repeat of the first.
@Suite("Human input live follow", .enabled(if: testDbHost != nil))
struct HumanInputLiveFollowTests {
    @Test func oneConnectionFollowsTwoPausesAndTheFinish() async throws {
        try await withRunningServer { api, port, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.twoFormsYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(run.text)
            let runId = frames.first?["workflow_run_id"]?.string ?? ""
            #expect(!runId.isEmpty)
            let tokens = frames.filter { $0["event"]?.string == "human_input_required" }
                .compactMap { $0["data"]?["form_token"]?.string }
            #expect(tokens.count == 2, "one pause with two forms")

            try await withRawConnection(port: port) { conn in
                try await conn.send("""
                    GET /v1/workflow/\(runId)/events?include_state_snapshot=true&continue_on_pause=true HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Authorization: Bearer \(owner)\r
                    Accept: text/event-stream\r
                    \r

                    """)
                // The snapshot describes the pause this run is in.
                #expect(try await conn.wait(upTo: 10) { $0.text.contains("\"event\":\"workflow_paused\"") },
                        "the snapshot should arrive on the live connection")
                #expect(try await conn.wait(upTo: 10) { $0.text.contains("\"event\":\"human_input_required\"") })

                // Answer the first form: the run resumes and pauses again on the second node, on the same connection.
                _ = try await api.post("/v1/form/human_input/\(tokens[0])", #"{"inputs":{"reply":"one"},"action":"approve"}"#,
                                       token: owner)
                let twoPauses = try await conn.wait(upTo: 15) { state in
                    state.text.components(separatedBy: "\"event\":\"workflow_paused\"").count - 1 >= 2
                }
                #expect(twoPauses, "the second pause must reach the same subscriber")

                // Answer the second: the run finishes on this connection too.
                _ = try await api.post("/v1/form/human_input/\(tokens[1])", #"{"inputs":{"reply":"two"},"action":"approve"}"#,
                                       token: owner)
                let finished = try await conn.wait(upTo: 15) { $0.text.contains("\"event\":\"workflow_finished\"") }
                #expect(finished, "the run's end reaches the connection that followed it")
                #expect(conn.text.contains("\"status\":\"succeeded\""), "and it succeeded")
            }
        }
    }
}

/// Stopping a paused run closes it: the pause is closed, its waiting forms are expired, and a later submission answers 412
/// instead of waking a run the user stopped.
@Suite("Human input stop while paused", .enabled(if: testDbHost != nil))
struct HumanInputStopPausedTests {
    @Test func stoppingAPausedRunClosesItAndRefusesLaterAnswers() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""
            #expect(!runId.isEmpty)

            let stop = try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(runId)/stop", token: owner)
            #expect(stop.status == 200, "\(stop.text)")
            #expect(try await store.workflowRun(doc: app, id: runId)?.status == "stopped")
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty, "the pause is closed")
            #expect(try await store.humanInputForm(token: token)?.status == .expired, "and the form with it")

            // A late answer cannot wake it.
            let late = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
            #expect(late.status == 412, "\(late.text)")
            #expect(try await store.workflowRun(doc: app, id: runId)?.status == "stopped", "still stopped")
        }
    }
}

/// Dify's `elapsed_time` counts from the **round**, not from the run's creation: a run that waited for a human keeps its
/// original `created_at`, while the finish, the detail and the history report the resumed round's time.
@Suite("Human input elapsed time", .enabled(if: testDbHost != nil))
struct HumanInputElapsedTests {
    @Test func theStreamAndTheRecordsUseTheirOwnClocks() async throws {
        try await withStore { store, logger in
            let config = ServerConfig.defaults
            let routes = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: config, logger: logger),
                                                 store: store, config: config, logger: logger)
            try await withApp(configure: { try routes.register(on: $0) }) { application in
                try await application.testing(.running) { client in
                    guard let port = client.port else { Issue.record("no port"); return }
                    let api = API(client: client)
                    let owner = try await api.setupOwner()
                    let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
                    let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                    let frames = HumanInputRunTests.frames(run.text)
                    let runId = frames.first?["workflow_run_id"]?.string ?? ""
                    let token = frames.first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
                    let createdBefore = try #require(try await store.workflowRun(id: runId)?.createdAt)

                    // A paused run reports no elapsed time yet (Dify's pause write leaves finished_at empty, so the row is 0).
                    let pausedRow = try await store.workflowRun(id: runId)
                    #expect(pausedRow?.status == "paused")
                    #expect((pausedRow?.elapsedTime ?? -1) == 0, "a paused row has no elapsed time")
                    let pause = try #require(try await store.openPauses(workflowRunId: runId).first)
                    #expect(pause.elapsedTime >= 0, "the pause carries the round's elapsed for the SSE")

                    try await withRawConnection(port: port) { conn in
                        try await conn.send("""
                            GET /v1/workflow/\(runId)/events?include_state_snapshot=true&continue_on_pause=true HTTP/1.1\r
                            Host: 127.0.0.1\r
                            Authorization: Bearer \(owner)\r
                            Accept: text/event-stream\r
                            \r

                            """)
                        #expect(try await conn.wait(upTo: 10) { $0.text.contains("\"event\":\"workflow_paused\"") })

                        let waitStart = Date()
                        try await Task.sleep(for: .milliseconds(1500))
                        _ = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
                        #expect(try await conn.wait(upTo: 20) { $0.text.contains("\"event\":\"workflow_finished\"") })
                        let wall = Date().timeIntervalSince(waitStart)

                        let finished = HumanInputRunTests.wireFrames(conn.text).last { $0["event"]?.string == "workflow_finished" }
                        let sseElapsed = finished?["data"]?["elapsed_time"]?.double ?? -1
                        let sseCreated = finished?["data"]?["created_at"]?.int ?? 0
                        #expect(sseElapsed >= 0 && sseElapsed < 1.0, "SSE elapsed \(sseElapsed) excludes the \(wall)s wait")
                        // The round starts after the run was created (the wait happens between), so the stream's
                        // created_at is later than the run row's — they are different clocks on purpose.
                        #expect(Double(sseCreated) - createdBefore.timeIntervalSince1970 >= 0.5,
                                "SSE created_at is the round's start (\(sseCreated))")
                    }

                    let detail = try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)", token: owner)
                    let detailJSON = try JSONValue.parse(Data(detail.text.utf8))
                    let elapsed = detailJSON["elapsed_time"]?.double ?? -1
                    let created = detailJSON["created_at"]?.int ?? 0
                    #expect(elapsed >= 0 && elapsed < 1.0, "detail elapsed \(elapsed) excludes the wait")
                    #expect(abs(Double(created) - createdBefore.timeIntervalSince1970) < 2, "detail created_at stays the run's")

                    let history = try await api.get("/v1/apps/\(app)/workflow-runs?limit=5", token: owner)
                    let historyJSON = try JSONValue.parse(Data(history.text.utf8))
                    let row = historyJSON["data"]?.array?.first { $0["id"]?.string == runId }?.object ?? [:]
                    #expect(abs((row["elapsed_time"]?.double ?? -1) - elapsed) < 0.01, "history matches the detail")
                    #expect(row["created_at"]?.int == created)
                }
            }
        }
    }
}

/// Deleting the app closes the runs it left waiting: the pause is closed, the forms expire, and the token stops working.
@Suite("Human input app deletion", .enabled(if: testDbHost != nil))
struct HumanInputAppDeletionTests {
    @Test func deletingTheAppClosesItsWaitingRun() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""
            #expect(!runId.isEmpty)

            let deleted = try await api.delete("/v1/apps/\(app)", token: owner)
            #expect(deleted.status == 204, "\(deleted.text)")
            #expect(try await store.workflowRun(id: runId)?.status == "stopped", "a deleted app does not leave a waiting run")
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty)
            #expect(try await store.humanInputForm(token: token)?.status == .expired)

            let late = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
            #expect(late.status == 412, "the token of a deleted app does not answer: \(late.text)")
        }
    }
}

/// `_display_in_ui`: the debugger shows every form; a published run follows the node's setting.
@Suite("Human input display rules", .enabled(if: testDbHost != nil))
struct HumanInputDisplayRuleTests {
    @Test func theDisplayDecisionFollowsTheWebappDeliveryNotTheBareBoolean() async throws {
        // `node_runtime._display_in_ui` + `is_human_input_webapp_enabled`, both directions of the conflict.
        #expect(ServerHumanInputRuntime.displayInUi(isDebugger: true, webappDeliveryEnabled: false) == true, "debugger shows it")
        #expect(ServerHumanInputRuntime.displayInUi(isDebugger: true, webappDeliveryEnabled: true) == true)
        #expect(ServerHumanInputRuntime.displayInUi(isDebugger: false, webappDeliveryEnabled: true) == true,
                "bare display_in_ui false, but webapp enabled: shown")
        #expect(ServerHumanInputRuntime.displayInUi(isDebugger: false, webappDeliveryEnabled: false) == false,
                "bare display_in_ui true, but only email / webapp disabled: not shown")

        // The node's delivery methods decide `webappDeliveryEnabled`, not the bare boolean.
        func config(_ delivery: String, displayInUi: Bool = false) throws -> HumanInputFormConfig {
            try HumanInputFormConfig([
                "type": .string("human-input"), "title": .string("Approve"),
                "form_content": .string("c"),
                "inputs": .array([]), "user_actions": .array([]),
                "display_in_ui": .bool(displayInUi),
                "delivery_methods": try JSONValue.parse(Data(delivery.utf8)),
            ])
        }
        #expect(try config(#"[{"type":"webapp","enabled":true}]"#).webappDeliveryEnabled == true)
        #expect(try config(#"[{"type":"webapp","enabled":false}]"#).webappDeliveryEnabled == false)
        #expect(try config(#"[{"type":"email","enabled":true}]"#).webappDeliveryEnabled == false)
        #expect(try config(#"[]"#).webappDeliveryEnabled == false)

        // Through a draft run (the debugger) a node with `display_in_ui: false` and no webapp still stores a shown form.
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let actionsLine = "                - {id: approve, title: Approve it, button_style: primary}"
            let yaml = HumanInputRunTests.appYAML().replacingOccurrences(
                of: actionsLine, with: actionsLine + "\n                display_in_ui: false")
            let app = try await api.post("/v1/docs/import", yaml, token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            #expect(try await store.humanInputForm(token: token)?.displayInUi == true, "the debugger shows it anyway")
        }
    }
}

/// The run ends inside the window between subscribing and reading the persisted state (`testDefect: slowStateRead` widens
/// it): the connection must answer one terminal frame, not a snapshot plus a terminal, and must close.
@Suite("Run events end during the state read", .enabled(if: testDbHost != nil))
struct RunEventsStateReadRaceTests {
    @Test func aRunThatEndsWhileItsStateIsReadStillAnswersOneTerminalFrame() async throws {
        var config = ServerConfig.defaults
        config.testDefect = "slowStateRead"
        try await withRunningServer(config: config) { api, port, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(run.text)
            let runId = frames.first?["workflow_run_id"]?.string ?? ""
            let token = frames.first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            #expect(!runId.isEmpty && !token.isEmpty)

            try await withRawConnection(port: port) { conn in
                try await conn.send("""
                    GET /v1/workflow/\(runId)/events?include_state_snapshot=true&continue_on_pause=false HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Authorization: Bearer \(owner)\r
                    Accept: text/event-stream\r
                    \r

                    """)
                // The endpoint is now subscribed and sleeping before it reads the state: finish the run inside that window.
                try await Task.sleep(for: .milliseconds(120))
                _ = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)

                let closedOrFinished = try await conn.wait(upTo: 20) {
                    $0.text.contains("\"event\":\"workflow_finished\"")
                }
                #expect(closedOrFinished, "the connection answers the run's end")
                try await Task.sleep(for: .milliseconds(300))
                let text = conn.text
                #expect(text.components(separatedBy: "\"event\":\"workflow_finished\"").count - 1 == 1,
                        "exactly one terminal frame")
                #expect(!text.contains("\"event\":\"workflow_started\""),
                        "no snapshot for a run that already ended: \(text.prefix(400))")
            }
        }
    }
}

/// The channel yields each published frame once, whether the subscriber replays from a mark or starts live.
@Suite("Run channel delivery")
struct RunChannelDeliveryTests {
    @Test func aSubscriberSeesEachFrameOnce() async {
        let channel = RunChannel()
        await channel.publish("data: {\"event\":\"workflow_started\"}\n\n")
        let mark = await channel.published
        let stream = await channel.subscribe(replay: true, from: mark)
        await channel.publish("data: {\"event\":\"human_input_form_filled\"}\n\n")

        var seen: [String] = []
        for await frame in stream {
            seen.append(frame)
            if seen.count >= 1 { break }
        }
        #expect(seen.filter { $0.contains("human_input_form_filled") }.count == 1, "\(seen)")
    }
}

/// Pause identity on the channel is the database generation: two resumes can re-pause inside the same second, and the
/// public `created_at` (integer seconds) cannot tell those apart.
@Suite("Run channel pause identity")
struct RunChannelPauseIdentityTests {
    @Test func twoPausesInTheSameSecondKeepDifferentIdentities() async {
        let channel = RunChannel()
        let frame = "data: " + #"{"event":"workflow_paused","data":{"created_at":1780000000}}"# + "\n\n"
        await channel.publish(frame, pauseGeneration: 1)
        await channel.publish(frame, pauseGeneration: 2)
        #expect(await channel.pauseGeneration(at: 0) == 1)
        #expect(await channel.pauseGeneration(at: 1) == 2)
        let snapshot = SnapshotFrames(frames: [], nodeIds: [], formIds: [], pauseGeneration: 1)
        // The first pause is the one the snapshot described; the second, in the same second, is new.
        #expect(CollabServer.Routes.isCovered(frame, snapshot: snapshot, pauseGeneration: await channel.pauseGeneration(at: 0)))
        #expect(!CollabServer.Routes.isCovered(frame, snapshot: snapshot, pauseGeneration: await channel.pauseGeneration(at: 1)))
    }
}

/// Following a paused run through its resume on one live connection: the filled answer is published before the human node's
/// own `node_finished`, and the run's end arrives exactly once.
@Suite("Human input resume stream", .enabled(if: testDbHost != nil))
struct HumanInputResumeStreamTests {
    @Test func filledComesBeforeTheNodeFinishesAndTheEndArrivesOnce() async throws {
        try await withRunningServer { api, port, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(run.text)
            let runId = frames.first?["workflow_run_id"]?.string ?? ""
            let token = frames.first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            #expect(!runId.isEmpty && !token.isEmpty)

            try await withRawConnection(port: port) { conn in
                try await conn.send("""
                    GET /v1/workflow/\(runId)/events?include_state_snapshot=true&continue_on_pause=true HTTP/1.1\r
                    Host: 127.0.0.1\r
                    Authorization: Bearer \(owner)\r
                    Accept: text/event-stream\r
                    \r

                    """)
                #expect(try await conn.wait(upTo: 10) { $0.text.contains("\"event\":\"workflow_paused\"") })

                _ = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
                let finished = try await conn.wait(upTo: 20) { $0.text.contains("\"event\":\"workflow_finished\"") }
                #expect(finished, "the run's end reaches the live subscriber")
                try await Task.sleep(for: .milliseconds(200))  // let any duplicate land before counting

                let text = conn.text
                func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
                #expect(count("\"event\":\"workflow_finished\"") == 1, "one terminal frame, got \(count("\"event\":\"workflow_finished\""))")
                // Exactly one: the same execution's answer is reported once (the earlier duplicate came from the frame
                // being published in both the pre-node block and the switch branch; the strict count is the regression).
                #expect(count("\"event\":\"human_input_form_filled\"") == 1,
                        "the answer is reported once, got \(count("\"event\":\"human_input_form_filled\""))")
                // Order: the filled frame precedes the human node's own node_finished (Dify's boundary publishes it first).
                // Frames are read off the wire with chunk headers around them, so positions come from the parsed frames.
                func positions(_ text: String) -> [(offset: Int, value: JSONValue)] {
                    var out: [(Int, JSONValue)] = []
                    var search = text.startIndex
                    while let r = text.range(of: "data: ", range: search..<text.endIndex) {
                        let start = r.upperBound
                        let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
                        if let value = try? JSONValue.parse(Data(text[start..<end].utf8)) {
                            out.append((text.distance(from: text.startIndex, to: r.lowerBound), value))
                        }
                        search = end
                    }
                    return out
                }
                let parsed = positions(text)
                let filled = parsed.first { $0.value["event"]?.string == "human_input_form_filled" }
                let humanFinished = parsed.first {
                    $0.value["event"]?.string == "node_finished" && $0.value["data"]?["node_id"]?.string == "human"
                }
                #expect(filled != nil && humanFinished != nil, "both frames should be on the wire")
                if let filled, let humanFinished {
                    #expect(filled.offset < humanFinished.offset, "filled before the human node's node_finished")
                }
                #expect(text.contains("\"action_id\":\"approve\""), "the filled payload carries the action")
            }
        }
    }
}

/// The email delivery: a form whose node enables the email method is mailed, after the pause is durable, with the form
/// link. Sent to a local stub SMTP server; nothing leaves the machine.
@Suite("Human input email delivery", .enabled(if: testDbHost != nil))
struct HumanInputEmailTests {
    /// The same workflow as `appYAML`, with the human node's delivery methods written out: a webapp and an email method
    /// (enabled or not) whose recipients are the given addresses.
    static func yaml(recipients: String, enabled: String = "true") -> String {
        let items = recipients.split(separator: ",").map {
            "                      - {type: external, email: " + $0.trimmingCharacters(in: .whitespaces) + "}"
        }.joined(separator: "\n")
        return """
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
                delivery_methods:
                - {type: webapp, enabled: true}
                - type: email
                  enabled: \(enabled)
                  config:
                    subject: A workflow is waiting
                    body: 'Please review it: {{#url#}}'
                    recipients:
                      include_bound_group: false
                      items:
        \(items)
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: reply, value_selector: [human, reply]}
        """
    }

    @Test func anEnabledEmailMethodIsSentOncePerRecipientWithTheFormLink() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withServer(config: config) { api, store, _ in
                let owner = try await api.setupOwner()
                let app = try await api.post("/v1/docs/import", Self.yaml(recipients: "one@example.test,two@example.test"),
                                             token: owner).str("id")
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                let token = HumanInputRunTests.frames(run.text)
                    .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
                #expect(!token.isEmpty)
                let form = try #require(try await store.humanInputForm(token: token))

                let mails = try await mailbox.wait(for: 2)
                #expect(mails.count == 2, "one mail per recipient: \(mails.count)")
                let tos = mails.map { $0.to.joined(separator: ",") }.sorted()
                #expect(tos == ["one@example.test", "two@example.test"])
                for mail in mails {
                    #expect(mail.subject == "A workflow is waiting", "the node's subject, got \(mail.subject)")
                    #expect(mail.text.contains("https://apps.example.test/form/\(form.token)"), "the form link")
                    #expect(!mail.text.contains("{{#url#}}"), "the placeholder is replaced")
                }
            }
        }
    }

    @Test func aDisabledEmailMethodSendsNothing() async throws {
        try await withStubSMTP { port, mailbox in
            var config = stubMailConfig(port: port)
            config.webAppBaseURL = "https://apps.example.test"
            try await withServer(config: config) { api, _, _ in
                let owner = try await api.setupOwner()
                let app = try await api.post("/v1/docs/import", Self.yaml(recipients: "one@example.test", enabled: "false"),
                                             token: owner).str("id")
                _ = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                let mails = try await mailbox.wait(for: 1)
                #expect(mails.isEmpty, "a disabled method sends nothing")
            }
        }
    }
}

/// The same node in two loop rounds is two executions: each round pauses with its own form, and an answer completes only
/// the round it belongs to (decisions are matched by execution, never by node).
@Suite("Human input in a loop", .enabled(if: testDbHost != nil))
struct HumanInputLoopTests {
    static func loopYAML() -> String {
        """
        app:
          mode: workflow
          name: hitl-loop
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: loop, targetHandle: target}
            - {id: e2, source: loop-start, sourceHandle: source, target: human, targetHandle: target}
            - {id: e3, source: human, sourceHandle: approve, target: increment, targetHandle: target}
            - {id: e4, source: loop, sourceHandle: source, target: end, targetHandle: target}
            nodes:
            - id: start
              data: {title: Start, type: start, variables: []}
            - id: loop
              data:
                title: Loop
                type: loop
                start_node_id: loop-start
                loop_count: 2
                break_conditions: []
                logical_operator: and
                loop_variables:
                - {label: n, var_type: number, value_type: constant, value: '0'}
            - id: loop-start
              data: {title: Loop start, type: loop-start}
            - id: human
              data:
                title: Approve
                type: human-input
                loop_id: loop
                isInLoop: true
                form_content: 'Round {{#$output.reply#}}'
                inputs:
                - {type: paragraph, output_variable_name: reply}
                user_actions:
                - {id: approve, title: Approve it, button_style: primary}
            - id: increment
              data:
                title: Increment
                type: assigner
                version: '2'
                loop_id: loop
                isInLoop: true
                items:
                - {input_type: constant, operation: '+=', value: 1, variable_selector: [loop, n], write_mode: over-write}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: n, value_selector: [loop, n]}
        """
    }

    @Test func eachRoundPausesWithItsOwnFormAndAnswer() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.loopYAML(), token: owner).str("id")
            #expect(!app.isEmpty)
            let first = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let firstFrames = HumanInputRunTests.frames(first.text)
            let runId = firstFrames.first?["workflow_run_id"]?.string ?? ""
            let firstToken = firstFrames.first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            #expect(!runId.isEmpty && !firstToken.isEmpty, "round 1 pauses: \(first.text.suffix(300))")
            let firstForm = try #require(try await store.humanInputForm(token: firstToken))

            // Answer round 1: the loop goes on to round 2, which pauses with a different execution and its own form.
            _ = try await api.post("/v1/form/human_input/\(firstToken)", #"{"inputs":{"reply":"one"},"action":"approve"}"#, token: owner)
            var secondToken = ""
            for _ in 0..<200 where secondToken.isEmpty {
                try await Task.sleep(for: .milliseconds(25))
                let forms = try await store.humanInputForms(workflowRunId: runId)
                secondToken = forms.first { $0.status == .waiting && $0.id != firstForm.id }?.token ?? ""
            }
            #expect(!secondToken.isEmpty, "round 2 pauses with a new form")
            let secondForm = try #require(try await store.humanInputForm(token: secondToken))
            #expect(secondForm.id != firstForm.id)
            #expect(secondForm.executionId != firstForm.executionId, "two rounds are two executions of the same node")

            // Answering round 2 only consumes its own execution; the run then finishes with both rounds done.
            _ = try await api.post("/v1/form/human_input/\(secondToken)", #"{"inputs":{"reply":"two"},"action":"approve"}"#, token: owner)
            var status = ""
            for _ in 0..<200 where status != "succeeded" && status != "failed" {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(id: runId)?.status ?? ""
            }
            #expect(status == "succeeded", "got \(status)")
            let store_ = store
            let forms = try await store_.humanInputForms(workflowRunId: runId)
            #expect(forms.allSatisfy { $0.status == .submitted }, "both rounds answered: \(forms.map(\.status))")
            #expect(Set(forms.map(\.executionId)).count == 2, "two executions, not one shared decision")
        }
    }
}

/// The resume position must match the forms that were persisted: rebuilding from the pause's own snapshot asks exactly for
/// those executions (this checks the existing acceptance item, it does not redefine the set).
@Suite("Human input resume position", .enabled(if: testDbHost != nil))
struct HumanInputResumePositionTests {
    /// Records which executions the engine decides on, and pauses again so the stream ends where it started.
    final class Recorder: HumanInputRuntime, @unchecked Sendable {
        private let asked = Mutex<[(nodeId: String, executionId: String)]>([])
        var askedList: [(nodeId: String, executionId: String)] { asked.withLock { $0 } }
        func decide(form: HumanInputFormConfig, context: HumanInputContext) async throws -> HumanInputDecision {
            asked.withLock { $0.append((context.nodeId, context.executionId ?? "")) }
            return .pause(sessionId: "replay")
        }
    }

    @Test func theSnapshotAsksForExactlyThePersistedForms() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.twoFormsYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(run.text)
            let runId = frames.first?["workflow_run_id"]?.string ?? ""
            let tokens = frames.filter { $0["event"]?.string == "human_input_required" }
                .compactMap { $0["data"]?["form_token"]?.string }
            #expect(tokens.count == 2)

            var stored: [StoredHumanInputForm] = []
            for token in tokens { stored.append(try #require(try await store.humanInputForm(token: token))) }
            let pause = try #require(try await store.pause(workflowRunId: runId, generation: 1))
            let record = try #require(try await store.workflowRun(doc: app, id: runId))

            // Rebuild the run from its own stored graph + snapshot and let a recording runtime answer the decisions.
            let config = try GraphConfig(json: try JSONValue.parse(record.graph))
            let recorder = Recorder()
            let graph = try await RuntimeGraph.build(
                config, rootId: try RuntimeGraph.defaultRootId(config),
                factory: BuiltinNodeFactory(services: RuntimeServices(humanInput: recorder)))
            let engine = GraphEngine(graph: graph)
            let snapshot = try GraphEngineSnapshot(data: Data(pause.snapshot.utf8))
            for await event in try engine.resume(snapshot) {
                if case .runPaused = event { break }
            }

            // Exactly the executions behind the persisted forms — not one more, not one less.
            let asked = Set(recorder.askedList.map(\.executionId))
            let persisted = Set(stored.map(\.executionId))
            #expect(asked == persisted, "snapshot asks \(asked.sorted()), forms are \(persisted.sorted())")
            #expect(recorder.askedList.count == stored.count, "each execution is decided once")
        }
    }
}

/// A resume whose preparation fails must end the run as failed and leave nothing waiting — not a `running` run that no
/// process will ever finish, and not a claim that blocks the next attempt.
@Suite("Human input resume preparation failure", .enabled(if: testDbHost != nil))
struct HumanInputResumePrepFailureTests {
    @Test func aFailedPreparationEndsTheRunAndLeavesNothingWaiting() async throws {
        var config = ServerConfig.defaults
        config.testDefect = "resumePrepFails"
        try await withServer(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let token = HumanInputRunTests.frames(run.text)
                .first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string ?? ""
            let runId = try await store.humanInputForm(token: token)?.workflowRunId ?? ""
            #expect(!runId.isEmpty)

            _ = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
            var status = ""
            for _ in 0..<200 where status != "failed" && status != "succeeded" {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
            }
            #expect(status == "failed", "the failed preparation ends the run, got \(status)")
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty, "the claim closed the pause")
            #expect(try await store.runsAwaitingResume().isEmpty, "and nothing is left to retry blindly")
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
            // Dify's public stream has no `workflow_failed`: the run ends with `workflow_finished` and `status: failed`.
            #expect(events.last == "workflow_finished", "\(events)")
            let finished = frames.first { $0["event"]?.string == "workflow_finished" }
            #expect(finished?["data"]?["status"]?.string == "failed", "\(String(describing: finished))")
            #expect(!events.contains("human_input_required"), "no form is offered when the pause is not durable: \(events)")
            #expect(!events.contains("workflow_paused"), "\(events)")

            let runId = finished?["data"]?["id"]?.string ?? ""
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

/// Stopping the round a resume started: the claim has already taken the pause, so the stop must reach the resumed engine
/// (and not a stale one), end the run `stopped`, and leave nothing waiting for another answer.
@Suite("Human input stop during the resume", .enabled(if: testDbHost != nil))
struct HumanInputStopDuringResumeTests {
    @Test func aStopThatArrivesWithTheResumedRoundEndsItStopped() async throws {
        var config = ServerConfig.defaults
        // TEST ONLY: holds the resumed round 300 ms after it took the run over, so the stop lands inside it.
        config.testDefect = "slowResume"
        try await withServerAndRoutes(config: config) { api, store, routes in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
            let events = HumanInputRunTests.frames(run.text)
            let required = try #require(events.first { $0["event"]?.string == "human_input_required" })
            let token = required["data"]?["form_token"]?.string ?? ""
            let runId = required["workflow_run_id"]?.string ?? ""
            #expect(!token.isEmpty && !runId.isEmpty)

            let answered = try await api.post("/v1/form/human_input/\(token)", ##"{"inputs":{"reply":"ok"},"action":"approve"}"##,
                                             token: owner)
            #expect(answered.status == 200, "answer: \(answered.text)")
            // The resume is its own round now (the answer's detached task registers it, then the defect holds it);
            // stopping it is Dify's stop of a running task.
            for _ in 0..<200 where await routes.runs.get(runId) == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await routes.runs.get(runId) != nil, "the resumed round owns the run before the stop")
            let stop = try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(runId)/stop", token: owner)
            #expect(stop.status == 200, "stop: \(stop.text)")

            var status = ""
            for _ in 0..<200 where !["stopped", "succeeded", "failed"].contains(status) {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
            }
            #expect(status == "stopped", "the stopped round ends \(status)")
            // Nothing is left to wake: the pause is closed and the form consumed.
            #expect(try await store.runsAwaitingResume().isEmpty)
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty)
            let again = try await api.post("/v1/form/human_input/\(token)", ##"{"inputs":{"reply":"ok"},"action":"approve"}"##,
                                          token: owner)
            #expect(again.status == 412, "a stopped run's form is closed: \(again.text)")
        }
    }
}

/// Reconnecting after text has streamed: the snapshot rebuilds a paused run from its **records** — nodes as
/// `node_started` / `node_finished`, no `text_chunk` — and a run that ended answers one terminal frame, so a client never
/// sees the same text twice.
@Suite("Human input reconnect after text", .enabled(if: testDbHost != nil))
struct HumanInputReconnectTextTests {
    /// start(q) -> human -> llm -> end{answer: llm.text, reply: human.reply}.
    static func yaml() -> String {
        """
        app:
          mode: workflow
          name: hitl-text
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
            - {id: e2, source: human, sourceHandle: approve, target: llm, targetHandle: target}
            - {id: e3, source: llm, sourceHandle: source, target: end, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables:
                - {label: q, required: true, type: text-input, variable: q}
            - id: human
              data:
                title: Approve
                type: human-input
                form_content: 'Approve {{#$output.reply#}} after {{#start.q#}}?'
                inputs:
                - {type: paragraph, output_variable_name: reply}
                user_actions:
                - {id: approve, title: Approve it, button_style: primary}
            - id: llm
              data:
                title: Ask
                type: llm
                model:
                  provider: langgenius/openai_api_compatible/openai_api_compatible
                  name: stub-chat
                  mode: chat
                  completion_params: {}
                prompt_template:
                - role: user
                  text: '{{#start.q#}} {{#human.reply#}}'
                context: {enabled: false, variable_selector: []}
                vision: {enabled: false}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: answer, value_selector: [llm, text]}
                - {variable: reply, value_selector: [human, reply]}
        """
    }

    @Test func theSnapshotHasTheRecordsAndNoTextAndAFinishedRunAnswersOneFrame() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, store, _ in
                let owner = try await api.setupOwner()
                // The stub model the LLM node names (`runtimeFixture` saves it the same way).
                let creds: JSONValue = ["model": "stub-chat", "model_type": "llm", "credentials": [
                    "endpoint_url": "http://llmstub:8000/v1", "api_key": "sk-stub-not-a-real-key", "mode": "chat",
                    "context_size": "4096", "max_tokens_to_sample": "4096",
                ]]
                let saved = try await api.post(
                    "/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models/credentials",
                    creds.compactJSON(), token: owner)
                #expect(saved.status == 201, "credentials: \(saved.text)")
                let app = try await api.post("/v1/docs/import", Self.yaml(), token: owner).str("id")
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{"q":"hi"}}"##, token: owner)
                #expect(run.status == 200, "run: \(run.text)")
                let events = HumanInputRunTests.frames(run.text)
                let required = try #require(events.first { $0["event"]?.string == "human_input_required" })
                let runId = required["workflow_run_id"]?.string ?? ""
                let token = required["data"]?["form_token"]?.string ?? ""
                #expect(required["data"]?["form_content"]?.string == "Approve {{#$output.reply#}} after hi?", "\(required)")

                // At the pause: the records, no text. `continue_on_pause=false` (the default): this read wants the
                // snapshot and its end, not a stream that waits for the answer.
                let reconnect = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: owner)
                #expect(reconnect.status == 200, "\(reconnect.text)")
                let paused = HumanInputRunTests.frames(reconnect.text)
                let pausedNames = paused.compactMap { $0["event"]?.string }
                #expect(!pausedNames.contains("text_chunk"), "\(pausedNames)")
                #expect(paused.filter { $0["event"]?.string == "node_finished" }
                    .compactMap { $0["data"]?["node_id"]?.string } == ["start"])
                #expect(pausedNames.filter { $0 == "human_input_required" }.count == 1)
                #expect(pausedNames.last == "workflow_paused")

                // Answer it: the resumed round runs the LLM and the end node, which streams its text.
                let answered = try await api.post("/v1/form/human_input/\(token)", ##"{"inputs":{"reply":"yes"},"action":"approve"}"##,
                                                 token: owner)
                #expect(answered.status == 200, "answer: \(answered.text)")
                var status = ""
                for _ in 0..<200 where status != "succeeded" && status != "failed" {
                    try await Task.sleep(for: .milliseconds(25))
                    status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
                }
                #expect(status == "succeeded", "the resumed run ends \(status)")

                // A finished run answers one terminal frame, whatever was asked: no records, no text.
                let after = try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: owner)
                let afterFrames = HumanInputRunTests.frames(after.text)
                #expect(afterFrames.compactMap { $0["event"]?.string } == ["workflow_finished"], "\(after.text)")
            }
        }
    }
}

/// The timeout scan in the **product** (`HumanInputTimeouts`): a form past its node deadline ends `timedOut` and the run
/// takes the node's `__timeout` branch; a run past the global deadline stops and its attached connection ends. The tests
/// move the scan's clock (`COLLAB_TEST_CLOCK_SKEW_SECONDS`) instead of waiting, and never call the store in the scan's
/// place.
@Suite("Human input timeout scan", .enabled(if: testDbHost != nil))
struct HumanInputTimeoutScanTests {
    /// start → human (1 hour; approve → end, timeout → end) → end.
    static func yaml() -> String {
        """
        app:
          mode: workflow
          name: hitl-timeout
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
            - {id: e3, source: human, sourceHandle: __timeout, target: end, targetHandle: target}
            nodes:
            - id: start
              data: {title: Start, type: start, variables: []}
            - id: human
              data:
                title: Approve
                type: human-input
                form_content: 'Approve {{#$output.reply#}}?'
                inputs: [{type: paragraph, output_variable_name: reply}]
                user_actions: [{id: approve, title: Approve it, button_style: primary}]
                timeout: 1
                timeout_unit: hour
            - id: end
              data:
                title: End
                type: end
                outputs: [{variable: reply, value_selector: [human, reply]}]
        """
    }

    @Test func aFormPastItsNodeDeadlineResumesTheRunThroughTheTimeoutBranch() async throws {
        var config = ServerConfig.defaults
        // The scan's clock is an hour and a minute ahead: the form's own deadline (created_at + 1 hour) has passed.
        config.testClockSkewSeconds = 3_700
        try await withServerAndRoutes(config: config) { api, store, routes in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.yaml(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
            let events = HumanInputRunTests.frames(run.text)
            let required = try #require(events.first { $0["event"]?.string == "human_input_required" })
            let runId = required["workflow_run_id"]?.string ?? ""
            let token = required["data"]?["form_token"]?.string ?? ""
            #expect(try await store.workflowRun(doc: app, id: runId)?.status == "paused")

            // The production scan, once.
            let swept = await routes.sweepHumanInputTimeouts(now: Date())
            #expect(swept.timedOut == 1, "one form past its deadline: \(swept)")

            var status = ""
            for _ in 0..<200 where status != "succeeded" && status != "failed" {
                try await Task.sleep(for: .milliseconds(25))
                status = try await store.workflowRun(doc: app, id: runId)?.status ?? ""
            }
            #expect(status == "succeeded", "the run goes on through the timeout branch, got \(status)")
            // The form is closed (a late answer is 412), the pause resumed, and the run took the timeout edge: the end
            // node saw an empty reply and no action.
            let late = try await api.post("/v1/form/human_input/\(token)", ##"{"inputs":{"reply":"late"},"action":"approve"}"##, token: owner)
            #expect(late.status == 412, "\(late.text)")
            #expect(try await store.openPauses(workflowRunId: runId).isEmpty)
            let executions = try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)/node-executions", token: owner)
            func field(_ v: Value?, _ k: String) -> Value? {
                guard case .map(let m)? = v else { return nil }
                return m[k]
            }
            let human = executions.list("data").first { field($0, "node_id") == .string("human") }
            #expect(field(field(human, "outputs"), "__action_id") == .string(""), "\(String(describing: human))")
            #expect(field(human, "status") == .string("succeeded"))
        }
    }

    @Test func aRunPastTheGlobalDeadlineStopsAndItsAttachedConnectionEnds() async throws {
        var config = ServerConfig.defaults
        config.humanInputGlobalTimeoutSeconds = 60
        // Past the global deadline (60 s), not the node's (1 hour).
        config.testClockSkewSeconds = 120
        try await withServerAndRoutes(config: config) { api, store, routes in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.yaml(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
            let required = try #require(HumanInputRunTests.frames(run.text).first { $0["event"]?.string == "human_input_required" })
            let runId = required["workflow_run_id"]?.string ?? ""
            let channel = try #require(await routes.runChannels.existing(runId))
            let live = await channel.subscribe(replay: false)
            let received = Mutex<[String]>([])
            let closed = Mutex(false)
            let listener = Task {
                for await frame in live { received.withLock { $0.append(frame) } }
                closed.withLock { $0 = true }
            }
            defer { listener.cancel() }

            let swept = await routes.sweepHumanInputTimeouts(now: Date())
            #expect(swept.expired == 1, "one run past the global deadline: \(swept)")
            for _ in 0..<100 where !closed.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            let terminal = HumanInputRunTests.frames(received.withLock { $0.joined() })
                .filter { $0["event"]?.string == "workflow_finished" }
            #expect(terminal.count == 1, "one terminal frame, got \(terminal)")
            #expect(terminal.first?["data"]?["status"]?.string == "stopped")
            #expect(closed.withLock { $0 }, "the global deadline closes the attached connection")
            #expect(await routes.runChannels.existing(runId) == nil)
            #expect(try await store.workflowRun(doc: app, id: runId)?.status == "stopped")
        }
    }
}

/// A run that waits for a person keeps its keep-alives: the ping belongs to the run's channel, not to one round (a round
/// cancels its work when it pauses, and Dify's queue pings every 10 s regardless).
@Suite("Human input pause keep-alive", .enabled(if: testDbHost != nil))
struct HumanInputPauseKeepAliveTests {
    @Test func aPausedRunStillPingsItsSubscribers() async throws {
        var config = ServerConfig.defaults
        config.ssePingSeconds = 1
        try await withServerAndRoutes(config: config) { api, _, routes in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", ##"{"inputs":{}}"##, token: owner)
            let required = try #require(HumanInputRunTests.frames(run.text).first { $0["event"]?.string == "human_input_required" })
            let runId = required["workflow_run_id"]?.string ?? ""
            let channel = try #require(await routes.runChannels.existing(runId))
            let live = await channel.subscribe(replay: false)
            let frames = Mutex<[String]>([])
            let listener = Task { for await f in live { frames.withLock { $0.append(f) } } }
            defer { listener.cancel() }
            // The round that paused is over; the keep-alive must still arrive while the run waits.
            for _ in 0..<40 where !frames.withLock({ $0.contains { $0.contains("event: ping") } }) {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(frames.withLock { $0.contains { $0.contains("event: ping") } }, "a paused run pings: \(frames.withLock { $0 })")
        }
    }
}
