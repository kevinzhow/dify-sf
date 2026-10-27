import CollabCore
import CollabModels
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

/// What the fake plugin daemon received.
final class DaemonLog: Sendable {
    struct Request: Sendable {
        var path: String
        var apiKey: String?
        var pluginId: String?
        var body: JSONValue
    }
    private let state = Mutex<[Request]>([])
    func add(_ r: Request) { state.withLock { $0.append(r) } }
    var requests: [Request] { state.withLock { $0 } }
}

/// A local stand-in for Dify's plugin daemon (`dispatch/model/schema`, `dispatch/llm/invoke`), answering the daemon's
/// line stream. The model answers `echo: <last user message>` in two chunks plus a usage chunk; a message containing
/// `[[fail]]` gets the daemon's error line for an `InvokeAuthorizationError`.
func withFakeDaemon(_ body: @Sendable @escaping (String, DaemonLog) async throws -> Void) async throws {
    let log = DaemonLog()
    @Sendable func lines(_ items: [JSONValue]) -> Response {
        var h = HTTPFields()
        h[.contentType] = "text/event-stream"
        let text = items.map { "data: " + $0.compactJSON() + "\n\n" }.joined()
        return Response(status: .ok, headers: h, body: .init(string: text))
    }
    @Sendable func record(_ req: Request, _ path: String) async -> JSONValue {
        let data = (try? await req.body.collect(max: .specified(ByteCount(value: 1 << 20)))) ?? Data()
        let body = (try? JSONValue.parse(data)) ?? .null
        log.add(.init(path: path, apiKey: req.headers[HTTPField.Name("X-Api-Key")!], pluginId: req.headers[HTTPField.Name("X-Plugin-ID")!],
                      body: body))
        return body
    }
    try await withApp(configure: { app in
        app.post("plugin", ":tenant", "dispatch", "model", "schema") { req async -> Response in
            let body = await record(req, "/plugin/\(req.parameters.get("tenant") ?? "")/dispatch/model/schema")
            let model = body["data"]?["model"] ?? .null
            return lines([["code": 0, "message": "", "data": ["model_schema": [
                "model": model, "label": ["en_US": model], "model_type": "llm", "features": [], "fetch_from": "customizable-model",
                "model_properties": ["mode": "chat", "context_size": 4096], "parameter_rules": [],
            ]]]])
        }
        app.post("plugin", ":tenant", "dispatch", "llm", "invoke") { req async -> Response in
            let body = await record(req, "/plugin/\(req.parameters.get("tenant") ?? "")/dispatch/llm/invoke")
            let messages = body["data"]?["prompt_messages"]?.array ?? []
            let last = messages.last { $0["role"] == "user" }?["content"]?.string ?? ""
            if last.contains("[[slow]]") { try? await Task.sleep(for: .seconds(5)) }
            if last.contains("[[fail]]") {
                let invoke = JSONValue.object(["error_type": "InvokeAuthorizationError", "message": "Incorrect API key provided"]).compactJSON()
                let outer = JSONValue.object(["error_type": "PluginInvokeError", "message": .string(invoke)]).compactJSON()
                return lines([["code": -500, "message": .string(outer), "data": .null]])
            }
            func chunk(_ text: String, usage: JSONValue = .null, finish: JSONValue = .null) -> JSONValue {
                ["code": 0, "message": "", "data": ["model": "stub-chat", "prompt_messages": [], "system_fingerprint": .null,
                                                    "delta": ["index": 0, "message": ["role": "assistant", "content": .string(text), "name": .null,
                                                                                      "tool_calls": []],
                                                              "usage": usage, "finish_reason": finish]]]
            }
            let usage: JSONValue = ["prompt_tokens": 5, "prompt_unit_price": "0", "prompt_price_unit": "0", "prompt_price": "0",
                                    "completion_tokens": 3, "completion_unit_price": "0", "completion_price_unit": "0",
                                    "completion_price": "0", "total_tokens": 8, "total_price": "0", "currency": "USD", "latency": 0.1]
            return lines([chunk("echo:"), chunk(" " + last), chunk("", usage: usage, finish: "stop")])
        }
    }) { app in
        try await app.testing(.running) { client in
            guard let port = client.port else { Issue.record("the fake daemon has no port"); return }
            try await body("http://127.0.0.1:\(port)", log)
        }
    }
}

private func json(_ v: JSONValue) -> String { v.compactJSON() }

/// A workflow app with a start node and an LLM node on the OpenAI-compatible provider's model `stub-chat`.
func runtimeAppYAML(prompt: String = "Q: {{#start.q#}}") -> String {
    """
    app:
      mode: workflow
      name: runtime-test
    kind: app
    version: 0.3.1
    workflow:
      conversation_variables: []
      environment_variables: []
      features: {}
      graph:
        edges:
        - id: start-llm
          source: start
          sourceHandle: source
          target: llm
          targetHandle: target
        nodes:
        - id: start
          data:
            title: Start
            type: start
            variables:
            - label: q
              required: true
              type: text-input
              variable: q
        - id: llm
          data:
            title: Ask
            type: llm
            model:
              provider: langgenius/openai_api_compatible/openai_api_compatible
              name: stub-chat
              mode: chat
              completion_params:
                temperature: 0
            prompt_template:
            - role: system
              text: You are terse.
            - role: user
              text: '\(prompt)'
            context:
              enabled: false
              variable_selector: []
            vision:
              enabled: false
    """
}

/// Sets up the owner, a credential for `stub-chat` (endpoint `endpoint`) and the app: (owner token, owner id, app id).
func runtimeFixture(_ api: API, endpoint: String = "http://llmstub:8000/v1", prompt: String = "Q: {{#start.q#}}") async throws
    -> (token: String, ownerId: String, app: String) {
    let owner = try await api.setupOwner()
    let ownerId = try await api.get("/v1/account", token: owner).str("id")
    let creds: JSONValue = ["model": "stub-chat", "model_type": "llm", "credentials": [
        "endpoint_url": .string(endpoint), "api_key": "sk-stub-not-a-real-key", "mode": "chat", "context_size": "4096",
        "max_tokens_to_sample": "4096",
    ]]
    let saved = try await api.post("/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models/credentials",
                                   json(creds), token: owner)
    #expect(saved.status == 201, "\(saved.text)")
    let imported = try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(runtimeAppYAML(prompt: prompt))]),
                                      token: owner)
    let app = imported.str("app_id")
    #expect(!app.isEmpty, "\(imported.text)")
    return (owner, ownerId, app)
}

func runtimeConfig(daemon: String, key: String = "daemon-key", tenant: String = "tenant-1") -> ServerConfig {
    var c = ServerConfig.defaults
    c.modelsValidate = false
    c.pluginDaemonURL = daemon
    c.pluginDaemonKey = key
    c.pluginDaemonTenant = tenant
    return c
}

@Suite("Runtime routes (protocol 1.13)", .enabled(if: testDbHost != nil))
struct RuntimeRouteTests {
    @Test func singleNodeRunThroughThePluginDaemon() async throws {
        try await withFakeDaemon { daemon, log in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, store, _ in
                let features = try await api.get("/v1/system-features")
                let runtime = try JSONValue.parse(features.text)["workflow_runtime"]
                #expect(runtime?["protocol_version"] == "1.21" && runtime?["chatflow"] == true && runtime?["single_node_run"]?.array?.contains("llm") == true)
                #expect(runtime?["draft_run"]?.array?.contains("start") == true)
                let (owner, ownerId, app) = try await runtimeFixture(api)
                let head = try await store.documentHead(app)
                let configurationCalls = log.requests.count

                let run = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"ping"}}"##, token: owner)
                #expect(run.status == 200, "\(run.text)")
                let r = try JSONValue.parse(run.text)
                #expect(r["status"] == "succeeded" && r["node_id"] == "llm" && r["node_type"] == "llm" && r["title"] == "Ask")
                #expect(r["outputs"]?["text"] == "echo: Q: ping" && r["outputs"]?["finish_reason"] == "stop")
                #expect(r["outputs"]?["usage"]?["total_tokens"] == 8 && r["execution_metadata"]?["total_tokens"] == 8)
                #expect(r["process_data"]?["prompts"] == [["role": "system", "text": "You are terse.", "files": []],
                                                         ["role": "user", "text": "Q: ping", "files": []]])
                #expect(r["created_by_account"]?["id"] == .string(ownerId) && r["created_by_role"] == "account" && r["error"] == .null)
                // Dify's member order (the client and Dify's web app read them by name; the order is checked for parity).
                #expect(r.object?.keys.prefix(4) == ["id", "index", "predecessor_node_id", "node_id"])

                // What the daemon got: Dify's dispatch calls for our tenant, with the decrypted credentials.
                let calls = Array(log.requests.dropFirst(configurationCalls))
                #expect(calls.map(\.path) == ["/plugin/tenant-1/dispatch/model/schema", "/plugin/tenant-1/dispatch/llm/invoke"])
                #expect(calls.allSatisfy { $0.apiKey == "daemon-key" && $0.pluginId == "langgenius/openai_api_compatible" })
                let invoke = calls[1].body
                #expect(invoke["user_id"] == .string(ownerId) && invoke["app_id"] == .string(app))
                #expect(invoke["data"]?["provider"] == "openai_api_compatible" && invoke["data"]?["model"] == "stub-chat")
                #expect(invoke["data"]?["credentials"]?["api_key"] == "sk-stub-not-a-real-key")
                #expect(invoke["data"]?["model_parameters"] == ["temperature": 0] && invoke["data"]?["stream"] == true)
                #expect(invoke["data"]?["prompt_messages"] == [["role": "system", "content": "You are terse.", "name": .null],
                                                              ["role": "user", "content": "Q: ping", "name": .null]])

                // A run is not an edit: no ops. The last run is stored beside the document.
                #expect(try await store.documentHead(app) == head)
                let last = try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/last-run", token: owner)
                let lastJSON = try JSONValue.parse(last.text)
                #expect(last.status == 200 && lastJSON["id"] == r["id"])
                #expect(lastJSON["outputs"] == r["outputs"])
                #expect(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/start/last-run", token: owner).status == 404)

                // The model refuses: the run answers 200 with a failed execution, which becomes the last run.
                let failed = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"[[fail]]"}}"##, token: owner)
                let f = try JSONValue.parse(failed.text)
                #expect(failed.status == 200 && f["status"] == "failed" && f["error"] == "Incorrect API key provided" && f["outputs"] == .null)
                let lastFailed = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/last-run", token: owner).text)
                #expect(lastFailed["id"] == f["id"])

                // Requests the runtime refuses.
                let missing = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", #"{"inputs":{}}"#, token: owner)
                #expect(missing.status == 400 && missing.errorCode == "invalid_param", "\(missing.text)")
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", #"{}"#, token: owner).errorCode == "invalid_param")
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/nodes/nope/run", #"{"inputs":{}}"#, token: owner).status == 404)
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/nodes/start/run", #"{"inputs":{}}"#, token: owner).errorCode
                        == "unsupported_node_type")

                // Roles: running needs edit (Dify's edit_permission_required), the last run any member.
                let normal = try await api.member("n@example.com", role: "normal", inviter: owner)
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"x"}}"##,
                                           token: normal.token).status == 403)
                #expect(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/last-run", token: normal.token).status == 200)
                #expect(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/last-run").status == 401)
            }
        }
    }

    @Test func runsReadTheDocumentAtItsCurrentSeq() async throws {
        try await withFakeDaemon { daemon, log in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let (owner, _, app) = try await runtimeFixture(api, prompt: "first {{#start.q#}}")
                // Replace the document's prompt with an ordinary edit (a Dify file over `POST /replace` is a set of ops).
                let client = try await api.post("/v1/docs/\(app)/clients", token: owner).str("client")
                let replaced = try await api.post("/v1/docs/\(app)/replace?client=\(client)&cseq=1", runtimeAppYAML(prompt: "second {{#start.q#}}"),
                                                  token: owner)
                #expect(replaced.status == 200, "\(replaced.text)")
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"x"}}"##, token: owner)
                let ran = try JSONValue.parse(run.text)
                #expect(ran["outputs"]?["text"] == "echo: second x", "\(run.text)")
                #expect(log.requests.last?.body["data"]?["prompt_messages"]?.array?.last?["content"] == "second x")
            }
        }
    }

    @Test func withoutAModelRuntimeNothingIsOffered() async throws {
        var config = ServerConfig.defaults
        config.modelsValidate = false
        try await withServer(config: config) { api, _, _ in
            #expect(try await api.get("/v1/system-features").json["workflow_runtime"] == nil)
            let (owner, _, app) = try await runtimeFixture(api)
            let r = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"x"}}"##, token: owner)
            #expect(r.status == 400 && r.errorCode == "model_runtime_not_configured")
        }
    }

    @Test func modelsWithoutCredentialsAreRefusedLikeDify() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let owner = try await api.setupOwner()
                let imported = try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(runtimeAppYAML())]),
                                                  token: owner)
                let app = imported.str("app_id")
                let r = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"x"}}"##, token: owner)
                #expect(r.status == 400 && r.errorCode == "invalid_param" && r.text.contains("Model stub-chat not exist."), "\(r.text)")
            }
        }
    }
}

/// Against a real plugin daemon (Dify's 0.6.10 image, `openai_api_compatible` installed for the tenant) and the e2e
/// stub LLM (e2e/llmstub). Runs only when `TEST_PLUGIN_DAEMON_URL` is set (server/run-runtime-e2e.sh).
let realDaemonURL = ProcessInfo.processInfo.environment["TEST_PLUGIN_DAEMON_URL"]

@Suite("Runtime against the real plugin daemon", .enabled(if: testDbHost != nil && realDaemonURL != nil))
struct RuntimeDaemonIntegrationTests {
    @Test func llmNodeSingleRunEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = runtimeConfig(daemon: realDaemonURL!, key: env["TEST_PLUGIN_DAEMON_KEY"] ?? "dify-sf-local-plugin-daemon-key",
                                   tenant: env["TEST_PLUGIN_DAEMON_TENANT"] ?? ServerConfig.defaultPluginDaemonTenant)
        try await withServer(config: config) { api, _, _ in
            let (owner, _, app) = try await runtimeFixture(api, endpoint: env["TEST_LLMSTUB_ENDPOINT"] ?? "http://llmstub:8000/v1")
            // The stub's scripted rule: a fixed answer.
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run", ##"{"inputs":{"#start.q#":"[[stub:fixed]]"}}"##, token: owner)
            #expect(run.status == 200, "\(run.text)")
            let r = try JSONValue.parse(run.text)
            #expect(r["status"] == "succeeded", "\(run.text)")
            #expect(r["outputs"]?["text"] == "This is the fixed stub answer.", "\(run.text)")
            #expect(r["outputs"]?["finish_reason"] == "stop")
            #expect((r["outputs"]?["usage"]?["total_tokens"]?.int ?? 0) > 0)
            // The deterministic default answer: `stub <h8>: <the last user message>`.
            let echo = try JSONValue.parse(try await api.post("/v1/apps/\(app)/workflows/draft/nodes/llm/run",
                                                              ##"{"inputs":{"#start.q#":"hello daemon"}}"##, token: owner).text)
            #expect(echo["outputs"]?["text"]?.string?.hasSuffix(": Q: hello daemon") == true, "\(echo)")
            print("runtime e2e:", r.compactJSON())
            print("runtime e2e:", echo.compactJSON())
        }
    }
}
