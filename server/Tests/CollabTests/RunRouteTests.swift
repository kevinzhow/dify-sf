import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

/// Draft runs (protocol 1.14): `POST /v1/apps/{app}/workflows/draft/run` (Dify's SSE events), the stop command, the run
/// history, a run's detail and node executions, last runs from whole runs; no ops.
@Suite("Draft runs (protocol 1.14)", .enabled(if: testDbHost != nil))
struct RunRouteTests {
    /// start(q) -> if-else (q contains "hi") -> llm -> end{answer: llm.text, q}; else -> end2{q}.
    static func appYAML() -> String {
        """
        app:
          mode: workflow
          name: run-test
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables:
          - id: env-1
            name: greeting
            value: hello
            value_type: string
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: branch, targetHandle: target}
            - {id: e2, source: branch, sourceHandle: 'yes', target: llm, targetHandle: target}
            - {id: e3, source: llm, sourceHandle: source, target: end, targetHandle: target}
            - {id: e4, source: branch, sourceHandle: 'false', target: end2, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables:
                - {label: q, required: true, type: text-input, variable: q}
                - {label: n, required: false, type: number, variable: n}
            - id: branch
              data:
                title: Branch
                type: if-else
                cases:
                - case_id: 'yes'
                  logical_operator: and
                  conditions:
                  - {variable_selector: [start, q], comparison_operator: contains, value: hi}
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
                  text: '{{#start.q#}} {{#env.greeting#}}'
                context: {enabled: false, variable_selector: []}
                vision: {enabled: false}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: answer, value_selector: [llm, text]}
                - {variable: q, value_selector: [start, q]}
            - id: end2
              data:
                title: End 2
                type: end
                outputs:
                - {variable: q, value_selector: [start, q]}
        """
    }

    static func events(_ sse: String) -> [JSONValue] {
        sse.components(separatedBy: "\n\n").compactMap { frame in
            guard frame.hasPrefix("data: ") else { return nil }
            return try? JSONValue.parse(String(frame.dropFirst(6)))
        }
    }

    static func fixture(_ api: API) async throws -> (owner: String, ownerId: String, app: String) {
        let (owner, ownerId, _) = try await runtimeFixture(api)
        let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(appYAML())])
            .compactJSON(), token: owner)
        let app = imported.str("app_id")
        #expect(!app.isEmpty, "\(imported.text)")
        return (owner, ownerId, app)
    }

    @Test func draftRunStreamsDifyEventsAndRecordsTheRun() async throws {
        try await withFakeDaemon { daemon, log in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, store, _ in
                let (owner, ownerId, app) = try await Self.fixture(api)
                let head = try await store.documentHead(app)
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"q":"hi there"},"files":[]}"#, token: owner)
                #expect(run.status == 200, "\(run.text)")
                let events = Self.events(run.text)
                let names = events.compactMap { $0["event"]?.string }
                #expect(names.first == "workflow_started" && names.last == "workflow_finished", "\(names)")
                #expect(names.filter { $0 == "node_started" }.count == 4 && names.filter { $0 == "node_finished" }.count == 4)
                let runId = events[0]["workflow_run_id"]?.string ?? ""
                #expect(events.allSatisfy { $0["workflow_run_id"]?.string == runId && $0["task_id"]?.string == runId })
                // Dify's frame: event, workflow_run_id, task_id, data.
                #expect(events[0].object?.keys == ["event", "workflow_run_id", "task_id", "data"])
                let started = events[0]["data"]
                #expect(started?["inputs"]?["q"] == "hi there" && started?["inputs"]?["n"] == .null)
                #expect(started?["inputs"]?["sys.user_id"] == .string(ownerId) && started?["inputs"]?["sys.app_id"] == .string(app))
                #expect(started?["workflow_id"] == .string(app) && started?["reason"] == "initial")

                let finished = events.filter { $0["event"] == "node_finished" }.map { $0["data"] ?? .null }
                #expect(finished.map { $0["node_id"]?.string ?? "" } == ["start", "branch", "llm", "end"])
                // A start node's outputs are its inputs (Dify's projection); the LLM saw the environment variable.
                #expect(finished[0]["outputs"] == ["q": "hi there", "n": .null] && finished[0]["title"] == "Start")
                #expect(finished[1]["outputs"] == ["result": true, "selected_case_id": "yes"])
                #expect(finished[2]["outputs"]?["text"] == "echo: hi there hello")
                #expect(finished[2]["execution_metadata"]?["total_tokens"] == 8)
                #expect(finished[0].object?.keys.prefix(6) == ["id", "node_id", "node_type", "title", "index", "predecessor_node_id"])
                // The end node streams its outputs (joined by newlines) as text chunks.
                let text = events.filter { $0["event"] == "text_chunk" }.compactMap { $0["data"]?["text"]?.string }.joined()
                #expect(text == "echo: hi there hello\nhi there")
                let done = events.last?["data"]
                #expect(done?["status"] == "succeeded" && done?["outputs"] == ["answer": "echo: hi there hello", "q": "hi there"])
                #expect(done?["total_tokens"] == 8 && done?["total_steps"] == 4 && done?["exceptions_count"] == 0)
                #expect(done?["created_by"]?["id"] == .string(ownerId))
                #expect(log.requests.contains { $0.path.hasSuffix("/dispatch/llm/invoke") })

                // No ops; the run, its node executions and last runs are stored.
                #expect(try await store.documentHead(app) == head)
                let list = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs", token: owner).text)
                #expect(list["limit"] == 20 && list["has_more"] == false && list["data"]?.array?.count == 1)
                #expect(list["data"]?.array?.first?["id"] == .string(runId) && list["data"]?.array?.first?["status"] == "succeeded")
                let detail = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)", token: owner).text)
                #expect(detail["status"] == "succeeded" && detail["inputs"]?["q"] == "hi there" && detail["graph"]?["nodes"]?.array?.count == 5)
                #expect(detail["outputs"]?["answer"] == "echo: hi there hello" && detail["total_steps"] == 4)
                let execs = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)/node-executions", token: owner).text)
                #expect(execs["data"]?.array?.map { $0["node_id"]?.string ?? "" } == ["start", "branch", "llm", "end"])
                #expect(execs["data"]?.array?.first?["index"] == 1 && execs["data"]?.array?.last?["index"] == 4)
                let last = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/branch/last-run", token: owner).text)
                #expect(last["outputs"]?["selected_case_id"] == "yes" && last["status"] == "succeeded")
                #expect(try await api.get("/v1/apps/\(app)/workflow-runs/\(UUID().uuidString.lowercased())", token: owner).status == 404)
                // The run's outputs are the variable inspect panel's draft variables.
                let vars = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/variables", token: owner).text)
                #expect(vars["items"]?.array?.first { $0["name"] == "text" }?["value"] == "echo: hi there hello", "\(vars)")
                #expect(vars["items"]?.array?.contains { $0["name"] == "finish_reason" } == false)

                // The other branch: no LLM call.
                // (Building the graph fetches every LLM node's model schema, as Dify's node factory does; only invokes count.)
                func invokes() -> Int { log.requests.filter { $0.path.hasSuffix("/dispatch/llm/invoke") }.count }
                let calls = invokes()
                let other = Self.events(try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"q":"bye","n":"3"}}"#,
                                                           token: owner).text)
                #expect(other.last?["data"]?["outputs"] == ["q": "bye"] && invokes() == calls)
                #expect(other.first?["data"]?["inputs"]?["n"] == 3)
                let two = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs?limit=1", token: owner).text)
                #expect(two["has_more"] == true && two["data"]?.array?.count == 1)
                let lastId = two["data"]?.array?.first?["id"]?.string ?? ""
                let page2 = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs?limit=1&last_id=\(lastId)", token: owner).text)
                #expect(page2["data"]?.array?.first?["id"] == .string(runId) && page2["has_more"] == false)
            }
        }
    }

    @Test func badRequestsAndRoles() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let (owner, _, app) = try await Self.fixture(api)
                let missing = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
                #expect(missing.status == 400 && missing.errorCode == "invalid_param" && missing.text.contains("q is required"), "\(missing.text)")
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{}"#, token: owner).errorCode == "invalid_param")
                let notNumber = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"q":"x","n":"abc"}}"#, token: owner)
                #expect(notNumber.errorCode == "invalid_param")
                let normal = try await api.member("n@example.com", role: "normal", inviter: owner)
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"q":"x"}}"#, token: normal.token).status == 403)
                #expect(try await api.get("/v1/apps/\(app)/workflow-runs", token: normal.token).status == 200)
                #expect(try await api.get("/v1/apps/\(app)/workflow-runs?last_id=\(UUID().uuidString)", token: owner).errorCode == "invalid_param")
            }
        }
    }

    @Test func stopEndsARunningRun() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let (owner, _, app) = try await Self.fixture(api)
                let running = Task { try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"q":"hi [[slow]]"}}"#, token: owner) }
                var runId = ""
                for _ in 0..<100 {
                    let list = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs", token: owner).text)
                    if let id = list["data"]?.array?.first?["id"]?.string { runId = id; break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(!runId.isEmpty)
                try await Task.sleep(for: .milliseconds(300))
                let stop = try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(runId)/stop", token: owner)
                let stopped = try JSONValue.parse(stop.text)
                #expect(stop.status == 200 && stopped == ["result": "success"])
                let answer = try await running.value
                let events = Self.events(answer.text)
                let done = events.last?["data"]
                #expect(events.last?["event"] == "workflow_finished" && done?["status"] == "stopped", "\(answer.text)")
                #expect(done?["error"] == "Aborted: User requested stop")
                let detail = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)", token: owner).text)
                #expect(detail["status"] == "stopped")
                // The LLM node was running: Dify records it as failed with the run's error.
                let execs = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)/node-executions", token: owner).text)
                let llm = execs["data"]?.array?.first { $0["node_id"] == "llm" }
                #expect(llm?["status"] == "failed" && llm?["error"] == "Aborted: User requested stop")
                // Unknown tasks: success (as Dify).
                #expect(try await api.post("/v1/apps/\(app)/workflow-runs/tasks/nope/stop", token: owner).status == 200)
            }
        }
    }

    @Test func graphsWithUnportedNodesAreRefused() async throws {
        var config = ServerConfig.defaults
        config.modelsValidate = false
        try await withServer(config: config) { api, _, _ in
            let owner = try await api.setupOwner()
            let yaml = Self.appYAML().replacingOccurrences(of: "type: llm", with: "type: knowledge-retrieval")
            let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(yaml)])
                .compactJSON(), token: owner)
            let app = imported.str("app_id")
            let r = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"q":"hi"}}"#, token: owner)
            #expect(r.status == 400 && r.errorCode == "unsupported_node_type", "\(r.text)")
            // An LLM graph without a model runtime.
            let llmApp = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(Self.appYAML())])
                .compactJSON(), token: owner).str("app_id")
            let r2 = try await api.post("/v1/apps/\(llmApp)/workflows/draft/run", #"{"inputs":{"q":"hi"}}"#, token: owner)
            #expect(r2.status == 400 && r2.errorCode == "model_runtime_not_configured", "\(r2.text)")
        }
    }
}
