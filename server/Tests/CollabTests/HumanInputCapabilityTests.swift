import CollabCore
import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

@Suite("Human input rollout gates", .enabled(if: testDbHost != nil))
struct HumanInputCapabilityTests {
    @Test func defaultsHideAndRejectNewHumanInputRuns() async throws {
        try await withFakeDaemon { daemon, _ in
            let config = runtimeConfig(daemon: daemon)
            #expect(!config.humanInputWebEnabled && !config.humanInputEmailEnabled)
            try await withServer(config: config) { api, store, _ in
                let owner = try await api.setupOwner()
                let runtime = try JSONValue.parse(try await api.get("/v1/system-features").text)["workflow_runtime"]
                #expect(runtime?["human_input"] == false)
                #expect(runtime?["human_input_email"] == false)
                #expect(runtime?["draft_run"]?.array?.contains("human-input") == false)
                let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                #expect(run.status == 400)
                #expect(run.errorCode == "runtime_service_not_configured")
                let records = try await store.workflowRuns(doc: app, triggeredFrom: "debugging", status: nil, limit: 20, lastId: nil)
                #expect(records?.runs.isEmpty == true)
                let preview = try await api.post("/v1/apps/\(app)/workflows/draft/human-input/nodes/human/form/preview", "{}", token: owner)
                #expect(preview.status == 501 && preview.errorCode == "human_input_disabled")
            }
        }
    }

    @Test func webOnlyDoesNotSendEmailEvenWhenSMTPIsConfigured() async throws {
        try await withStubSMTP { port, mailbox in
            try await withFakeDaemon { daemon, _ in
                var config = runtimeConfig(daemon: daemon)
                config.mail = stubMailConfig(port: port).mail
                config.webAppBaseURL = "https://forms.example.test"
                config.humanInputWebEnabled = true
                try await withServerAndRoutes(config: config) { api, _, routes in
                    let owner = try await api.setupOwner()
                    let runtime = try JSONValue.parse(try await api.get("/v1/system-features").text)["workflow_runtime"]
                    #expect(runtime?["human_input"] == true)
                    #expect(runtime?["human_input_email"] == false)
                    let app = try await api.post("/v1/docs/import", HumanInputMailRoundTwoTests.yaml(body: "Open {{#url#}}"), token: owner).str("id")
                    let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                    #expect(run.status == 200)
                    #expect(HumanInputRunTests.frames(run.text).contains { $0["event"]?.string == "workflow_paused" })
                    #expect(await routes.deliverPendingHumanInputMail() == 0)
                    #expect(mailbox.all.isEmpty)
                    let test = try await api.post("/v1/apps/\(app)/workflows/draft/human-input/nodes/human/delivery-test", #"{"delivery_method_id":"email"}"#, token: owner)
                    #expect(test.status == 501 && test.errorCode == "human_input_email_disabled")
                }
            }
        }
    }
    @Test func webFormsRunWithoutAConfiguredModelDaemon() async throws {
        var config = ServerConfig.defaults
        config.humanInputWebEnabled = true
        try await withServer(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let runtime = try JSONValue.parse(try await api.get("/v1/system-features").text)["workflow_runtime"]
            #expect(runtime?["human_input"] == true)
            #expect(runtime?["human_input_email"] == false)
            #expect(runtime?["draft_run"]?.array?.contains("llm") == false)
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let required = try #require(HumanInputRunTests.frames(run.text).first { $0["event"]?.string == "human_input_required" })
            let form = try #require(required["data"]?["form_token"]?.string)
            let runId = try #require(required["workflow_run_id"]?.string)
            let answer = try await api.post("/v1/form/human_input/\(form)", #"{"inputs":{"reply":"accepted"},"action":"approve"}"#, token: owner)
            #expect(answer.status == 200)
            for _ in 0..<50 {
                if try await store.workflowRun(id: runId)?.status == "succeeded" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try await store.workflowRun(id: runId)?.status == "succeeded")
        }
    }

}
