import CollabRuntime
import Foundation
import HTTPTypes
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Agent executor profile transport")
struct AgentExecutorProfileTests {
    static var catalog: JSONValue {
        ["protocol": "dify-sf-agent/1", "profiles": [
            ["name": "default", "description": "Default shell", "status": "ok", "timeout_seconds_max": 1800],
            ["name": "rendering", "description": "Prepared rendering tools", "status": "ok", "timeout_seconds_max": 10800,
             "image": "must-not-reach-client", "env": ["INTERNAL": "private"]]
        ]]
    }
    @Test func catalogProjectsOnlySafeFieldsAndRejectsMalformedAnswers() throws {
        let profiles = try AgentExecutorProfile.parse(Self.catalog)
        #expect(profiles.count == 2 && profiles[1].timeoutSecondsMax == 10800)
        #expect(profiles[1].json["image"] == nil && profiles[1].json["env"] == nil)
        for entries in [[], [["name": "default"]], [Self.catalog["profiles"]!.array![1]],
            [Self.catalog["profiles"]!.array![0], Self.catalog["profiles"]!.array![0]]] as [JSONValue] {
            #expect(throws: NodeError.self) { try AgentExecutorProfile.parse(["profiles": entries]) }
        }
        #expect(AgentExecutionPolicy.timeout(node: 10800, profile: 1800, server: 86400) == 1800)
        #expect(AgentExecutionPolicy.timeout(node: 10800, profile: 10800, server: 7200) == 7200)
        #expect(AgentExecutionPolicy.timeout(node: 300, profile: 10800, server: 7200) == 300)
        #expect(AgentExecutionPolicy.timeout(node: 10800, profile: nil, server: 7200) == 7200)
    }

    @Test func concurrentCatalogReadsShareOneAuthenticatedProbeAndFailureIsUnknown() async throws {
        let probes = Mutex(0)
        let validAuth = Mutex(true)
        try await withApp(configure: { app in
            app.routes.get("v1", "profiles") { req in
                probes.withLock { $0 += 1 }
                validAuth.withLock { $0 = $0 && req.headers[.authorization] == "Bearer fixture-only" }
                try await Task.sleep(for: .milliseconds(100))
                return Response(status: .ok, body: .init(string: Self.catalog.compactJSON()))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21418)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21418"; config.key = "fixture-only"; config.shellEnabled = true
                let frozen = config, cache = AgentExecutorProfilesCache()
                await withTaskGroup(of: Int.self) { group in
                    for _ in 0..<10 { group.addTask { await cache.profiles(frozen)?.count ?? -1 } }
                    for await count in group { #expect(count == 2) }
                }
                #expect(probes.withLock { $0 } == 1 && validAuth.withLock { $0 })
                config.url = "http://127.0.0.1:1"
                #expect(await AgentExecutorProfilesCache().profiles(config) == nil)
                config.shellEnabled = false
                #expect(await cache.profiles(config) == nil)
                #expect(probes.withLock { $0 } == 1)
            }
        }
    }

    @Test func unavailableAndUnknownProfilesAreConcreteRejectionsWithoutRetry() async throws {
        let calls = Mutex(0)
        let unavailable = Mutex(true)
        try await withApp(configure: { app in
            app.routes.post("v1", "operations") { _ in
                calls.withLock { $0 += 1 }
                let missingImage = unavailable.withLock { $0 }
                return Response(status: missingImage ? .serviceUnavailable : .init(code: 422),
                    body: .init(string: JSONValue.object(["protocol": "dify-sf-agent/1",
                        "error": missingImage ? "executor_profile_unavailable" : "executor_profile_unknown",
                        "message": "upstream-private-details"]).compactJSON()))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21419)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21419"; config.key = "fixture-only"
                for flag in [true, false] {
                    unavailable.withLock { $0 = flag }
                    do { _ = try await AgentServiceClient(config: config).start(["executor_profile": "rendering"], token: "fixture-only"); Issue.record("Expected rejection") }
                    catch let error as NodeError {
                        #expect(error.errorTypeName == (flag ? "executor_profile_unavailable" : "executor_profile_unknown"))
                        #expect(!error.message.contains("upstream-private-details"))
                    }
                }
                #expect(calls.withLock { $0 } == 2)
            }
        }
    }

    @Test func matchingEchoSucceedsAndMissingOrDifferentEchoCancelsBeforeAcceptingOutput() async throws {
        let echo = Mutex<JSONValue>("rendering")
        let cancellations = Mutex<[Int]>([])
        try await withApp(configure: { app in
            app.routes.get("v1", "runs", "remote", "events") { _ in
                var started: JSONObject = [:]
                if echo.withLock({ $0 }) != .null { started["executor_profile"] = echo.withLock { $0 } }
                let wire = "id: 1\nevent: run_started\ndata: \(JSONValue.object(started).compactJSON())\n\nid: 2\nevent: succeeded\ndata: {}\n\n"
                return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(string: wire))
            }
            app.routes.get("v1", "runs", "remote") { _ in
                Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1","run_id":"remote","operation_id":"operation","status":"succeeded","last_event_id":2,"result":{}}"#))
            }
            app.routes.post("v1", "runs", "remote", "cancel") { req in
                let bytes = try await req.body.collect(max: .specified(ByteCount(value: 1024))) ?? Data()
                let body = try JSONValue.parse(bytes)
                let generation = try #require(body["generation"]?.int)
                cancellations.withLock { $0.append(generation) }
                return Response(status: .accepted, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21420)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21420"; config.key = "fixture-only"
                let client = AgentServiceClient(config: config)
                #expect(try await client.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(5),
                    expectedProfile: "rendering", generation: 7, isAborted: { false })["status"] == "succeeded")
                for value in ["default", .null] as [JSONValue] {
                    echo.withLock { $0 = value }
                    do {
                        _ = try await client.result(run: "remote", operation: "operation", deadline: Date().addingTimeInterval(5),
                            expectedProfile: "rendering", generation: 7, isAborted: { false })
                        Issue.record("Unconfirmed executor profile accepted")
                    } catch let error as NodeError { #expect(error.errorTypeName == "sandbox_unavailable") }
                }
                #expect(cancellations.withLock { $0 } == [7, 7])
            }
        }
    }
    @Test func swiftDeadlineAlsoEndsAStalledEventBody() async throws {
        try await withApp(configure: { app in
            app.routes.get("v1", "runs", "remote", "events") { _ in
                let body = try Response.Body(stream: { writer in
                    try await writer.write(": started\n\n")
                    try await Task.sleep(for: .seconds(3))
                    try await writer.write(": still running\n\n")
                }, count: nil)
                return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: body)
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21421)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21421"; config.key = "fixture-only"
                let started = Date()
                do {
                    _ = try await AgentServiceClient(config: config).result(run: "remote", operation: "operation",
                        deadline: Date().addingTimeInterval(1), isAborted: { false })
                    Issue.record("A stalled event stream exceeded the Swift deadline")
                } catch let error as NodeError { #expect(error.errorTypeName == "AgentTimeout") }
                #expect(Date().timeIntervalSince(started) < 1.8)
                let aborted = Mutex(false)
                let abort = Task { try await Task.sleep(for: .milliseconds(100)); aborted.withLock { $0 = true } }
                defer { abort.cancel() }
                let cancelStarted = Date()
                do {
                    _ = try await AgentServiceClient(config: config).result(run: "remote", operation: "operation",
                        deadline: Date().addingTimeInterval(10), isAborted: { aborted.withLock { $0 } })
                    Issue.record("An aborted execution kept waiting for an event")
                } catch is CancellationError { }
                #expect(Date().timeIntervalSince(cancelStarted) < 1)
            }
        }
    }

    @Test func startingAnOperationCannotWaitPastTheNodeDeadlineForItsResponseBody() async throws {
        let calls = Mutex(0)
        try await withApp(configure: { app in
            app.routes.post("v1", "executions", "execution", "lease") { _ in
                Response(status: .ok, body: .init(string: #"{"protocol":"dify-sf-agent/1"}"#))
            }
            app.routes.post("v1", "operations") { _ in
                calls.withLock { $0 += 1 }
                let body = try Response.Body(stream: { writer in
                    try await writer.write("{")
                    try await Task.sleep(for: .seconds(3))
                    try await writer.write("}")
                }, count: nil)
                return Response(status: .accepted, body: body)
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21423)) { _ in
                var config = ServerConfig.defaults.agentService
                config.url = "http://127.0.0.1:21423"; config.key = "fixture-only"
                let started = Date()
                do {
                    _ = try await AgentServiceClient(config: config).begin([:], token: "fixture-only", execution: "execution",
                        generation: 1, deadline: Date().addingTimeInterval(1), isAborted: { false })
                    Issue.record("A start response body exceeded the node deadline")
                } catch let error as NodeError { #expect(error.errorTypeName == "AgentTimeout") }
                #expect(Date().timeIntervalSince(started) < 1.8)
                #expect(calls.withLock { $0 } == 1)
            }
        }
    }

    @Test(.enabled(if: testDbHost != nil))
    func executorCatalogRequiresWorkspaceReadAccessAndProjectsOnlyPublicFields() async throws {
        try await withApp(configure: { app in
            app.routes.get("v1", "profiles") { _ in
                Response(status: .ok, body: .init(string: Self.catalog.compactJSON()))
            }
        }) { app in
            try await app.testing(.running, options: .live(port: 21422)) { _ in
                var config = ServerConfig.defaults
                config.agentService.url = "http://127.0.0.1:21422"; config.agentService.key = "fixture-only"
                config.agentService.shellEnabled = true
                try await withServer(config: config) { api, store, _ in
                    let (token, _, id) = try await AgentComposerTests.seed(api, store)
                    let path = "/v1/apps/\(id)/agent-executor-profiles"
                    #expect(try await api.get(path).status == 401)
                    let response = try await api.get(path, token: token)
                    #expect(response.status == 200)
                    #expect(!response.text.contains("must-not-reach-client") && !response.text.contains("private"))
                    let body = try JSONValue.parse(response.text)
                    #expect(body["shell_enabled"] == true && body["profiles"]?.array?.count == 2)
                }
            }
        }
    }

}
