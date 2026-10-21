import CollabCore
import CollabStore
import Foundation
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

/// A run that ends **without an engine** (a paused run stopped, a pause whose resume could not be prepared) must also end
/// the connection that is already attached: one `workflow_finished` with the durable status, then the stream closes and
/// the channel is released. From Winnie's M1 review (regressions she ran against ce53e23); kept here so the regression
/// stays in the suite.
@Suite("Human input terminal ends attached subscribers", .enabled(if: testDbHost != nil))
struct HumanInputReviewTests {
    @Test func preparationFailureEndsTheExistingSubscriber() async throws {
        try await checkTerminal(defect: "resumePrepFails", stop: false)
    }

    @Test func stoppingAPausedRunEndsTheExistingSubscriber() async throws {
        try await checkTerminal(defect: nil, stop: true)
    }

    private func checkTerminal(defect: String?, stop: Bool) async throws {
        try await withStore { store, logger in
            var config = humanInputTestConfig()
            if let defect { config.testDefect = defect }
            let routes = try CollabServer.Routes(
                registry: DocumentRegistry(store: store, config: config, logger: logger),
                store: store, config: config, logger: logger)
            try await withApp(configure: { try routes.register(on: $0) }) { application in
                try await application.testing { client in
                    let api = API(client: client)
                    let owner = try await api.setupOwner()
                    let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
                    let response = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                    let frames = HumanInputRunTests.frames(response.text)
                    let token = try #require(frames.first { $0["event"]?.string == "human_input_required" }?["data"]?["form_token"]?.string)
                    let form = try #require(try await store.humanInputForm(token: token))
                    let channel = try #require(await routes.runChannels.existing(form.workflowRunId ?? ""))
                    let live = await channel.subscribe(replay: false)
                    let received = Mutex<[String]>([])
                    let closed = Mutex(false)
                    let listener = Task {
                        for await frame in live { received.withLock { $0.append(frame) } }
                        closed.withLock { $0 = true }
                    }
                    defer { listener.cancel() }
                    if stop {
                        _ = try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(form.workflowRunId ?? "")/stop", "{}", token: owner)
                    } else {
                        _ = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"ok"},"action":"approve"}"#, token: owner)
                    }
                    let expected = stop ? "stopped" : "failed"
                    for _ in 0..<100 {
                        if try await store.workflowRun(doc: app, id: form.workflowRunId ?? "")?.status == expected { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    #expect(try await store.workflowRun(doc: app, id: form.workflowRunId ?? "")?.status == expected)
                    // Give the terminal publisher a bounded chance to complete, without awaiting a stream that can hang.
                    for _ in 0..<50 where !closed.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let terminal = HumanInputRunTests.frames(received.withLock { $0.joined() })
                        .filter { $0["event"]?.string == "workflow_finished" }
                    #expect(terminal.count == 1, "an attached subscriber needs exactly one terminal frame, received \(terminal)")
                    #expect(terminal.first?["data"]?["status"]?.string == expected)
                    #expect(closed.withLock { $0 }, "durable terminal state must close the existing subscription")
                    #expect(await routes.runChannels.existing(form.workflowRunId ?? "") == nil, "a terminal run must release its channel")
                }
            }
        }
    }
}
