import CollabCore
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Console run observation filtering") struct ConsoleRunObservationFrameTests {
    @Test func formCapabilitiesNeverReachReadOnlyObservers() {
        let required = RunExecution.sse(["event": "human_input_required", "data": ["form_token": "fixture-form-secret"]])
        #expect(Routes.consoleRunFrame(required) == nil)
        let pause = RunExecution.sse(["event": "workflow_paused", "workflow_run_id": "fixture-run",
            "data": ["reasons": [["form_token": "fixture-form-secret"]]]])
        let visible = Routes.consoleRunFrame(pause) ?? ""
        #expect(visible.contains("workflow_paused"))
        #expect(!visible.contains("fixture-form-secret"))
        let progress = RunExecution.sse(["event": "agent_log", "data": ["label": "progress", "call_index": 65]])
        #expect(Routes.consoleRunFrame(progress) == progress)
    }
}

@Suite("Console run observation authorization", .enabled(if: testDbHost != nil))
struct ConsoleRunObservationRouteTests {
    @Test func appMembersCanObserveOtherCallersButOriginalResumeBoundaryIsUnchanged() async throws {
        try await withHumanInputServer { api, store, _ in
            let owner = try await api.setupOwner()
            let viewer = try await api.member("observer@example.test", role: "normal", inviter: owner).token
            let app = try await api.post("/v1/apps", #"{"name":"Observation fixture","mode":"workflow"}"#, token: owner)
            #expect(app.status == 201)
            let doc = app.str("id"), run = UUID().uuidString.lowercased()
            try await store.insertWorkflowRun(.init(id: run, docId: doc, docSeq: 0, workflowId: doc,
                type: "workflow", triggeredFrom: "app-run", version: "published", graph: "{}", inputs: "{}",
                status: "succeeded", createdBy: "different-fixture-caller", createdAt: Date()))
            let path = "/v1/apps/\(doc)/workflow-runs/\(run)/events?include_state_snapshot=true"
            for token in [owner, viewer] {
                let response = try await api.get(path, token: token)
                #expect(response.status == 200, "\(response.text)")
                #expect(response.text.contains("workflow_finished"))
            }
            #expect(try await api.get(path).status == 401)
            #expect(try await api.get("/v1/workflow/\(run)/events", token: owner).status == 404)
            let other = try await api.post("/v1/apps", #"{"name":"Other fixture","mode":"workflow"}"#, token: owner).str("id")
            #expect(try await api.get("/v1/apps/\(other)/workflow-runs/\(run)/events", token: owner).status == 404)
        }
    }
}
