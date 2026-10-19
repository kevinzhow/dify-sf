import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

/// Iteration and loop nodes in draft runs and their single runs (protocol 1.15): Dify's iteration_* / loop_* SSE events,
/// inner nodes' `iteration_id` / `loop_id`, records and draft variables, the iteration / loop single-run endpoints, the
/// retry history in the node executions.
@Suite("Iteration and loop runs (protocol 1.15)", .enabled(if: testDbHost != nil))
struct ContainerRunRouteTests {
    /// start(payload) -> iteration over payload.items (an LLM per item, 2 at a time) -> loop (n += 1, 3 rounds) -> end.
    static let mainYAML = """
        app:
          mode: workflow
          name: containers
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: it, targetHandle: target}
            - {id: e2, source: itstart, sourceHandle: source, target: llm, targetHandle: target, data: {isInIteration: true, iteration_id: it}}
            - {id: e3, source: it, sourceHandle: source, target: lp, targetHandle: target}
            - {id: e4, source: lpstart, sourceHandle: source, target: inc, targetHandle: target, data: {isInLoop: true, loop_id: lp}}
            - {id: e5, source: lp, sourceHandle: source, target: end, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables:
                - {label: payload, required: true, type: json_object, variable: payload}
            - id: it
              data:
                title: Each
                type: iteration
                start_node_id: itstart
                iterator_selector: [start, payload, items]
                output_selector: [llm, text]
                is_parallel: true
                parallel_nums: 2
                error_handle_mode: terminated
                flatten_output: true
            - id: itstart
              type: custom-iteration-start
              parentId: it
              data: {title: '', type: iteration-start, isInIteration: true}
            - id: llm
              parentId: it
              data:
                title: Ask
                type: llm
                isInIteration: true
                iteration_id: it
                model:
                  provider: langgenius/openai_api_compatible/openai_api_compatible
                  name: stub-chat
                  mode: chat
                  completion_params: {}
                prompt_template:
                - role: user
                  text: 'item {{#it.item#}}'
                context: {enabled: false, variable_selector: []}
                vision: {enabled: false}
            - id: lp
              data:
                title: Count
                type: loop
                start_node_id: lpstart
                loop_count: 3
                break_conditions: []
                logical_operator: and
                loop_variables:
                - {label: n, var_type: number, value_type: constant, value: '0'}
            - id: lpstart
              type: custom-loop-start
              parentId: lp
              data: {title: '', type: loop-start, isInLoop: true}
            - id: inc
              parentId: lp
              data:
                title: Add
                type: assigner
                version: '2'
                isInLoop: true
                loop_id: lp
                items:
                - {input_type: constant, operation: +=, value: 1, variable_selector: [lp, n], write_mode: over-write}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: texts, value_selector: [it, output]}
                - {variable: n, value_selector: [lp, n]}
        """

    /// start(items) -> iteration over start.items (an LLM with 2 retries per item, failures kept: continue-on-error) -> end.
    static let singleYAML = """
        app:
          mode: workflow
          name: container-single
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: it, targetHandle: target}
            - {id: e2, source: itstart, sourceHandle: source, target: llm, targetHandle: target, data: {isInIteration: true, iteration_id: it}}
            - {id: e3, source: it, sourceHandle: source, target: end, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables:
                - {label: items, required: false, type: json_object, variable: items}
            - id: it
              data:
                title: Each
                type: iteration
                start_node_id: itstart
                iterator_selector: [start, items]
                output_selector: [llm, text]
                error_handle_mode: continue-on-error
            - id: itstart
              type: custom-iteration-start
              parentId: it
              data: {title: '', type: iteration-start, isInIteration: true}
            - id: llm
              parentId: it
              data:
                title: Ask
                type: llm
                isInIteration: true
                iteration_id: it
                retry_config: {retry_enabled: true, max_retries: 2, retry_interval: 0}
                model:
                  provider: langgenius/openai_api_compatible/openai_api_compatible
                  name: stub-chat
                  mode: chat
                  completion_params: {}
                prompt_template:
                - role: user
                  text: '{{#it.item#}}'
                context: {enabled: false, variable_selector: []}
                vision: {enabled: false}
            - id: end
              data:
                title: End
                type: end
                outputs:
                - {variable: texts, value_selector: [it, output]}
        """

    static func importApp(_ api: API, _ yaml: String, token: String) async throws -> String {
        let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(yaml)]).compactJSON(),
                                          token: token)
        let app = imported.str("app_id")
        #expect(!app.isEmpty, "\(imported.text)")
        return app
    }

    static func data(_ events: [JSONValue], _ name: String) -> [JSONValue] {
        events.filter { $0["event"]?.string == name }.map { $0["data"] ?? .null }
    }

    @Test func draftRunWithAnIterationAndALoop() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, store, _ in
                let (owner, _, _) = try await runtimeFixture(api)
                let features = try JSONValue.parse(try await api.get("/v1/system-features").text)["workflow_runtime"]
                #expect(features?["protocol_version"] == "1.15")
                for t in ["iteration", "iteration-start", "loop", "loop-start", "loop-end"] {
                    #expect(features?["draft_run"]?.array?.contains(.string(t)) == true, "\(t)")
                }
                #expect(features?["single_node_run"]?.array?.contains("iteration") == true
                        && features?["single_node_run"]?.array?.contains("loop-start") == false)
                let app = try await Self.importApp(api, Self.mainYAML, token: owner)
                let head = try await store.documentHead(app)
                let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{"payload":{"items":["a","b","c"]}}}"#, token: owner)
                #expect(run.status == 200, "\(run.text)")
                let events = RunRouteTests.events(run.text)
                let names = events.compactMap { $0["event"]?.string }
                // No node_started / node_finished for the containers themselves: their own events stand for them.
                let startedNodes = Self.data(events, "node_started").compactMap { $0["node_id"]?.string }
                #expect(!startedNodes.contains("it") && !startedNodes.contains("lp") && !startedNodes.contains("itstart"), "\(startedNodes)")
                #expect(startedNodes.filter { $0 == "llm" }.count == 3 && startedNodes.filter { $0 == "inc" }.count == 3)
                #expect(names.filter { $0 == "iteration_next" }.count == 3 && names.filter { $0 == "loop_next" }.count == 2, "\(names)")
                let itStarted = try #require(Self.data(events, "iteration_started").first)
                #expect(itStarted.object?.keys == ["id", "node_id", "node_type", "title", "created_at", "extras", "metadata", "inputs", "inputs_truncated"])
                #expect(itStarted["id"] == "it" && itStarted["title"] == "Each" && itStarted["inputs"] == ["iterator_selector": ["a", "b", "c"]])
                #expect(itStarted["metadata"] == ["iteration_length": 3])
                #expect(Self.data(events, "iteration_next").map { $0["index"] } == [0, 1, 2])
                let itDone = try #require(Self.data(events, "iteration_completed").first)
                #expect(itDone["status"] == "succeeded" && itDone["steps"] == 3 && itDone["total_tokens"] == 24 && itDone["error"] == .null)
                #expect(itDone["outputs"] == ["output": ["echo: item a", "echo: item b", "echo: item c"]])
                #expect(itDone["execution_metadata"]?.object?.keys == ["total_tokens", "total_price", "currency", "iteration_duration_map"])
                let llmStarted = Self.data(events, "node_started").filter { $0["node_id"] == "llm" }
                #expect(llmStarted.allSatisfy { $0["iteration_id"] == "it" && $0["loop_id"] == .null })
                let llmDone = Self.data(events, "node_finished").filter { $0["node_id"] == "llm" }
                #expect(Set(llmDone.compactMap { $0["execution_metadata"]?["iteration_index"]?.int }) == [0, 1, 2])
                #expect(llmDone.allSatisfy { $0["iteration_id"] == "it" && $0["execution_metadata"]?["iteration_id"] == "it" })
                let loopStarted = try #require(Self.data(events, "loop_started").first)
                #expect(loopStarted["inputs"] == ["loop_count": 3, "n": 0] && loopStarted["metadata"] == ["loop_length": 3])
                #expect(Self.data(events, "loop_next").first?.object?.keys == ["id", "node_id", "node_type", "title", "index", "created_at",
                                                                               "pre_loop_output", "extras"])
                let loopDone = try #require(Self.data(events, "loop_completed").first)
                #expect(loopDone["outputs"] == ["n": 3, "loop_round": 3] && loopDone["steps"] == 3)
                #expect(loopDone["execution_metadata"]?["completed_reason"] == "loop_completed")
                #expect(loopDone["execution_metadata"]?["loop_variable_map"] == ["0": ["n": 1], "1": ["n": 2], "2": ["n": 3]])
                #expect(Self.data(events, "node_started").filter { $0["node_id"] == "inc" }.allSatisfy { $0["loop_id"] == "lp" })
                let done = try #require(events.last?["data"])
                #expect(done["status"] == "succeeded" && done["outputs"] == ["texts": ["echo: item a", "echo: item b", "echo: item c"], "n": 3])
                // Steps count the root frame (start, iteration, loop, end); tokens include the iteration's LLM calls.
                #expect(done["total_steps"] == 4 && done["total_tokens"] == 24)

                // Records: the containers and every round's nodes; no draft variables of nodes inside a container.
                #expect(try await store.documentHead(app) == head)
                let runId = events[0]["workflow_run_id"]?.string ?? ""
                let execs = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)/node-executions", token: owner).text)
                let rows = execs["data"]?.array ?? []
                #expect(rows.count == 10, "\(rows.map { $0["node_id"] ?? .null })")
                let itRow = rows.first { $0["node_id"] == "it" }
                #expect(itRow?["status"] == "succeeded" && itRow?["outputs"]?["output"]?.array?.count == 3)
                #expect(itRow?["execution_metadata"]?["iteration_duration_map"]?.object?.count == 3)
                #expect(rows.filter { $0["node_id"] == "llm" }.allSatisfy { $0["execution_metadata"]?["iteration_id"] == "it" })
                let llmVars = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/variables", token: owner).text)
                #expect(llmVars["items"]?.array?.isEmpty == true, "\(llmVars)")
                let itVars = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/it/variables", token: owner).text)
                #expect(itVars["items"]?.array?.first { $0["name"] == "output" }?["value"] == ["echo: item a", "echo: item b", "echo: item c"])
                let lpVars = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/lp/variables", token: owner).text)
                // Dify keeps a loop's `loop_round` out of the draft variables.
                #expect(lpVars["items"]?.array?.compactMap { $0["name"]?.string } == ["n"])
                // The plain single-node endpoint refuses containers (Dify: engine-backed debug endpoints only).
                let plain = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/it/run", #"{"inputs":{}}"#, token: owner)
                #expect(plain.status == 400 && plain.errorCode == "invalid_param" && plain.text.contains("engine-backed"), "\(plain.text)")
            }
        }
    }

    @Test func iterationAndLoopSingleRunsAndRetryHistory() async throws {
        try await withFakeDaemon { daemon, _ in
            try await withServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let (owner, _, _) = try await runtimeFixture(api)
                let app = try await Self.importApp(api, Self.singleYAML, token: owner)
                let path = "/v1/apps/\(app)/workflows/draft/iteration/nodes/it/run"
                #expect(try await api.post(path, #"{}"#, token: owner).errorCode == "invalid_param")
                let missing = try await api.post(path, #"{"inputs":{}}"#, token: owner)
                #expect(missing.errorCode == "invalid_param" && missing.text.contains("it.input_selector"), "\(missing.text)")
                let wrongKind = try await api.post("/v1/apps/\(app)/workflows/draft/loop/nodes/it/run", #"{"inputs":{}}"#, token: owner)
                #expect(wrongKind.errorCode == "invalid_param", "\(wrongKind.text)")

                let run = try await api.post(path, #"{"inputs":{"it.input_selector":["x","[[fail]]","z"]}}"#, token: owner)
                #expect(run.status == 200, "\(run.text)")
                let events = RunRouteTests.events(run.text)
                let names = events.compactMap { $0["event"]?.string }
                #expect(names.first == "workflow_started" && names.last == "workflow_finished")
                // Only the iteration and its nodes run (no start, no end); the failing item is retried twice, then kept as null.
                let started = Self.data(events, "node_started").compactMap { $0["node_id"]?.string }
                #expect(Set(started) == ["llm"], "\(started)")
                #expect(Self.data(events, "node_retry").map { $0["retry_index"] } == [1, 2])
                #expect(Self.data(events, "node_retry").allSatisfy { $0["iteration_id"] == "it" })
                let done = try #require(events.last?["data"])
                #expect(done["status"] == "partial-succeeded" && done["exceptions_count"] == 3, "\(done)")
                let itDone = try #require(Self.data(events, "iteration_completed").first)
                #expect(itDone["outputs"] == ["output": ["echo: x", .null, "echo: z"]])
                // Recorded as a debugging run; the failed node's attempts come before it in the node executions.
                let runId = events[0]["workflow_run_id"]?.string ?? ""
                let list = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs", token: owner).text)
                #expect(list["data"]?.array?.first?["id"] == .string(runId))
                let execs = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)/node-executions", token: owner).text)
                let rows = execs["data"]?.array ?? []
                let failed = try #require(rows.first { $0["node_id"] == "llm" && $0["status"] == "failed" })
                let failedId = failed["id"]?.string ?? ""
                let retries = rows.filter { $0["status"] == "retry" }
                #expect(retries.map { $0["id"]?.string ?? "" } == ["\(failedId):retry:1", "\(failedId):retry:2"])
                #expect(retries.map { $0["retry_index"] } == [1, 2] && failed["retry_index"] == nil)
                #expect(failed["process_data"]?["__dify_retry_history"] == nil)
                let failedIndex = rows.firstIndex { $0["id"]?.string == failedId } ?? 0
                #expect(rows.firstIndex { $0["id"]?.string == "\(failedId):retry:1" } == failedIndex - 2)

                // A loop single run (no inputs needed: constant loop variables).
                let loopApp = try await Self.importApp(api, Self.mainYAML, token: owner)
                let loop = try await api.post("/v1/apps/\(loopApp)/workflows/draft/loop/nodes/lp/run", #"{"inputs":{}}"#, token: owner)
                let loopEvents = RunRouteTests.events(loop.text)
                #expect(loopEvents.last?["data"]?["status"] == "succeeded", "\(loop.text)")
                #expect(Self.data(loopEvents, "loop_completed").first?["outputs"] == ["n": 3, "loop_round": 3])
                #expect(Self.data(loopEvents, "node_started").compactMap { $0["node_id"]?.string } == ["inc", "inc", "inc"])
            }
        }
    }
}
