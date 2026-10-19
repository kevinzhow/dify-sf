import Foundation
import Synchronization
import Testing
@testable import CollabDSL
@testable import CollabRuntime
@testable import CollabRuntimeReplay

/// The graph engine (protocol 1.14): Dify's golden traces replayed (graphon 0.7.0 with Dify's mock nodes, compared as
/// e2e/lib/runtrace.py does), and the engine's rules one by one: branches and skips, joins, parallel branches, error
/// strategies, retries, stop, execution limits, response streaming order.
@Suite("Runtime engine")
struct RuntimeEngineTests {
    static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let traces = here.appendingPathComponent("Fixtures/graphon-traces")
    static let fixtures = here.appendingPathComponent("Fixtures/dify")

    // MARK: Golden traces

    @Test(arguments: [1, 4])
    func goldenTracesReplay(workers: Int) async throws {
        let results = try await Replay.replayAll(tracesDir: Self.traces, fixturesDir: Self.fixtures, maxWorkers: workers)
        #expect(results.count == 31)
        // With several workers, two answers that become ready together finish in either order, and `outputs.answer`
        // concatenates them in finishing order (graphon's `merge_response_outputs`; the goldens ran with one worker).
        let concurrentAnswers: Set<String> = workers > 1 ? ["test_complex_branch.hello"] : []
        // Every case, the iteration and loop ones too (phase P3).
        for r in results {
            let diffs = r.differences.filter { !(concurrentAnswers.contains(r.name) && $0.path == "run.outputs.answer") }
            #expect(r.outcome != .error && r.outcome != .skip && diffs.isEmpty,
                    "\(r.name): \(r.outcome) \(r.note)\n\(diffs.prefix(8).map(\.description).joined(separator: "\n"))")
        }
    }

    /// The editor's path: a sample imported into a document and exported again runs exactly as the file itself.
    @Test func goldenTracesReplayThroughTheDocument() async throws {
        for file in try FileManager.default.contentsOfDirectory(atPath: Self.traces.path).sorted() where file.hasSuffix(".json") {
            var golden = try JSONValue.parse(Data(contentsOf: Self.traces.appendingPathComponent(file)))
            guard let fixture = golden["meta"]?["fixture"]?.string else { continue }
            let yaml = try String(contentsOf: Self.fixtures.appendingPathComponent(fixture), encoding: .utf8)
            let imported = try DifyDSL.importYAML(yaml)
            let exported = try DifyDSL.exportYAML(imported.document, metadata: imported.metadata, secrets: imported.secrets)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-roundtrip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try exported.write(to: dir.appendingPathComponent(fixture), atomically: true, encoding: .utf8)
            if case .object(var g) = golden { g["case"] = .string((g["case"]?.string ?? "") + " (via document)"); golden = .object(g) }
            let r = await Replay.replay(golden: golden, fixturesDir: dir)
            // The document does not keep the editor's selection (`selected`), which the assigner v2 echoes in its inputs.
            let diffs = r.differences.filter { !$0.path.hasSuffix(".inputs.selected") }
            #expect(r.outcome != .error && diffs.isEmpty, "\(r.name): \(r.outcome) \(r.note)\n\(diffs.prefix(8).map(\.description).joined(separator: "\n"))")
        }
    }

    // MARK: Engine rules over test nodes

    /// A test node: `behavior` = `ok` (outputs `{value}`), `fail` (error `boom`), `flaky` (fails `fails` times, then ok),
    /// `wait` (until aborted), `stream` (streams `text` word by word).
    struct TestNode: RuntimeNode {
        let id: String
        let base: BaseNodeData
        let behavior: String
        let data: JSONObject
        let attempts: Attempts
        var nodeType: String { "test" }
        var retryEnabled: Bool { base.retryConfig.retryEnabled }

        final class Attempts: Sendable {
            let counts = Mutex<[String: Int]>([:])
            func next(_ id: String) -> Int { counts.withLock { $0[id, default: 0] += 1; return $0[id]! } }
            /// Nodes running at once (`echo` nodes): now and at most.
            let gauge = Mutex<(now: Int, max: Int)>((0, 0))
            func enter() { gauge.withLock { $0.now += 1; $0.max = max($0.max, $0.now) } }
            func leave() { gauge.withLock { $0.now -= 1 } }
            var maxConcurrent: Int { gauge.withLock { $0.max } }
        }

        func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
            let value = data["value"] ?? .string(id)
            switch behavior {
            case "fail":
                await emit(.completed(NodeRunResult(status: .failed, inputs: ["in": value], error: "boom", errorType: "TestError")))
            case "flaky":
                let n = attempts.next(id)
                if n <= (data["fails"]?.int ?? 1) {
                    await emit(.completed(NodeRunResult(status: .failed, error: "flake \(n)", errorType: "TestError")))
                } else {
                    await emit(.completed(NodeRunResult(status: .succeeded, outputs: ["value": value, "attempt": .int(n)])))
                }
            case "echo":
                // Outputs the value at `read` (an iteration's item); fails when it equals `fail_on`.
                let selector = (data["read"]?.array ?? []).compactMap(\.string)
                let v = context.pool.get(selector)?.value ?? .null
                attempts.enter()
                if let ms = data["sleep_ms"]?.int { try? await Task.sleep(for: .milliseconds(ms)) }
                attempts.leave()
                if let bad = data["fail_on"], bad == v {
                    await emit(.completed(NodeRunResult(status: .failed, inputs: ["v": v], error: "bad \(PythonText.str(v))", errorType: "TestError")))
                    return
                }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: ["v": v], outputs: ["value": v])))
            case "wait":
                while !context.isAborted() { try await Task.sleep(for: .milliseconds(5)) }
                throw CancellationError()
            case "stream":
                let text = data["text"]?.string ?? ""
                for (i, w) in text.split(separator: " ").enumerated() {
                    await emit(.streamChunk(selector: [id, "text"], chunk: (i > 0 ? " " : "") + w, isFinal: false))
                }
                await emit(.streamChunk(selector: [id, "text"], chunk: "", isFinal: true))
                await emit(.completed(NodeRunResult(status: .succeeded, outputs: ["text": .string(text)])))
            default:
                if let ms = data["sleep_ms"]?.int { try await Task.sleep(for: .milliseconds(ms)) }
                await emit(.completed(NodeRunResult(status: .succeeded, outputs: ["value": value])))
            }
        }
    }

    struct TestFactory: NodeFactory {
        let attempts = TestNode.Attempts()
        func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
            if config.type == "test" {
                return TestNode(id: config.id, base: try BaseNodeData(config.data), behavior: config.data["behavior"]?.string ?? "ok",
                                data: config.data, attempts: attempts)
            }
            return try await BuiltinNodeFactory(services: RuntimeServices()).createNode(config, graph: graph)
        }
    }

    static func node(_ id: String, _ data: JSONObject) -> JSONValue { ["id": .string(id), "data": .object(data)] }
    static func edge(_ s: String, _ t: String, _ handle: String = "source") -> JSONValue {
        ["id": .string("\(s)-\(t)"), "source": .string(s), "target": .string(t), "sourceHandle": .string(handle)]
    }
    static let start = node("start", ["type": "start", "title": "Start", "variables": []])
    static func end(_ outputs: [(String, [String])]) -> JSONValue {
        node("end", ["type": "end", "title": "End",
                     "outputs": .array(outputs.map { ["variable": .string($0.0), "value_selector": .array($0.1.map(JSONValue.string))] })])
    }
    static func test(_ id: String, _ behavior: String = "ok", _ extra: JSONObject = [:]) -> JSONValue {
        var d: JSONObject = ["type": "test", "title": .string(id), "behavior": .string(behavior)]
        for (k, v) in extra { d[k] = v }
        return node(id, d)
    }

    struct Run {
        var events: [GraphEngineEvent]
        var terminal: GraphEngineEvent? { events.last }
        var finishedNodes: [(String, String)] {
            events.compactMap { e in
                guard case .node(let n) = e else { return nil }
                switch n {
                case .succeeded(_, let id, _, _, _): return (id, "succeeded")
                case .failed(_, let id, _, _, _, _): return (id, "failed")
                case .exception(_, let id, _, _, _, _): return (id, "exception")
                default: return nil
                }
            }
        }
        func status(_ id: String) -> String? { finishedNodes.last { $0.0 == id }?.1 }
        var started: [String] { events.compactMap { if case .node(.started(_, let id, _, _, _, _)) = $0 { return id }; return nil } }
        var text: String {
            events.compactMap { if case .node(.streamChunk(_, _, _, let c, _)) = $0 { return c }; return nil }.joined()
        }
        var stats: GraphRunStats? {
            switch terminal {
            case .runSucceeded(let s)?, .runPartialSucceeded(let s)?, .runFailed(_, let s)?, .runAborted(_, let s)?: return s
            default: return nil
            }
        }
    }

    static func run(_ nodes: [JSONValue], _ edges: [JSONValue], inputs: JSONObject = [:], config: GraphEngineConfig = GraphEngineConfig(),
                    commands: GraphEngineCommands = GraphEngineCommands(), factory: TestFactory = TestFactory()) async throws -> Run {
        let graphConfig = try GraphConfig(json: ["nodes": .array(nodes), "edges": .array(edges)])
        let graph = try await RuntimeGraph.build(graphConfig, rootId: "start", factory: factory)
        let pool = try WorkflowBootstrap.pool(system: WorkflowBootstrap.systemVariables([("user_id", "u")]), environment: [], conversation: [],
                                              rootId: "start", inputs: inputs)
        var events: [GraphEngineEvent] = []
        for await e in GraphEngine(graph: graph, config: config, commands: commands).run(pool: pool) { events.append(e) }
        return Run(events: events)
    }

    @Test func linearRunOutputsAndSteps() async throws {
        let r = try await Self.run([Self.start, Self.test("a", "ok", ["value": "A"]), Self.end([("out", ["a", "value"])])],
                                   [Self.edge("start", "a"), Self.edge("a", "end")])
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["out": "A"])
        #expect(s.totalSteps == 3 && r.started == ["start", "a", "end"])
        // The end node streams its outputs as text.
        #expect(r.text == "A")
    }

    @Test func branchSkipsTheOtherSideAndJoins() async throws {
        let ifElse = Self.node("if", ["type": "if-else", "title": "If", "cases": [[
            "case_id": "yes", "logical_operator": "and",
            "conditions": [["variable_selector": ["start", "q"], "comparison_operator": "is", "value": "go"]],
        ]]])
        let nodes = [Self.start, ifElse, Self.test("yes"), Self.test("no"), Self.test("after"), Self.test("onlyNo"),
                     Self.end([("v", ["after", "value"])])]
        let edges = [Self.edge("start", "if"), Self.edge("if", "yes", "yes"), Self.edge("if", "no", "false"), Self.edge("yes", "after"),
                     Self.edge("no", "after"), Self.edge("no", "onlyNo"), Self.edge("after", "end")]
        let r = try await Self.run(nodes, edges, inputs: ["q": "go"])
        #expect(r.status("yes") == "succeeded" && r.status("no") == nil && r.status("onlyNo") == nil)
        // the join runs once, after its taken input
        #expect(r.started.filter { $0 == "after" }.count == 1)
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("not succeeded"); return }
        #expect(s.outputs == ["v": "after"])
        let other = try await Self.run(nodes, edges, inputs: ["q": "stop"])
        #expect(other.status("no") == "succeeded" && other.status("onlyNo") == "succeeded" && other.status("yes") == nil)
    }

    @Test func parallelBranchesRunTogetherAndJoin() async throws {
        let nodes = [Self.start, Self.test("a", "ok", ["sleep_ms": 400]), Self.test("b", "ok", ["sleep_ms": 400]),
                     Self.test("c", "ok", ["sleep_ms": 400]), Self.test("join"), Self.end([("j", ["join", "value"])])]
        let edges = [Self.edge("start", "a"), Self.edge("start", "b"), Self.edge("start", "c"), Self.edge("a", "join"), Self.edge("b", "join"),
                     Self.edge("c", "join"), Self.edge("join", "end")]
        let r = try await Self.run(nodes, edges)
        #expect(r.started.filter { $0 == "join" }.count == 1 && r.status("join") == "succeeded")
        // The three branches overlap: all three started before the first of them finished.
        func position(_ match: (GraphEngineEvent) -> Bool) -> Int { r.events.firstIndex(where: match) ?? -1 }
        let lastStart = ["a", "b", "c"].map { id in position { if case .node(.started(_, let n, _, _, _, _)) = $0 { return n == id }; return false } }.max()!
        let firstEnd = ["a", "b", "c"].map { id in position { if case .node(.succeeded(_, let n, _, _, _)) = $0 { return n == id }; return false } }.min()!
        #expect(lastStart < firstEnd, "branches ran one after another")
        // One worker: one after another, same result.
        let serial = try await Self.run(nodes, edges, config: GraphEngineConfig(maxWorkers: 1))
        #expect(serial.status("join") == "succeeded")
        let serialFirstEnd = serial.events.firstIndex { if case .node(.succeeded(_, "a", _, _, _)) = $0 { return true }; return false } ?? -1
        let serialStartB = serial.events.firstIndex { if case .node(.started(_, "b", _, _, _, _)) = $0 { return true }; return false } ?? -1
        #expect(serialFirstEnd < serialStartB)
    }

    @Test func failureWithoutStrategyFailsTheRun() async throws {
        let r = try await Self.run([Self.start, Self.test("x", "fail"), Self.test("after"), Self.end([])],
                                   [Self.edge("start", "x"), Self.edge("x", "after"), Self.edge("after", "end")])
        guard case .runFailed(let error, let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(error == "boom" && s.exceptionsCount == 1)
        #expect(r.status("x") == "failed" && r.status("after") == nil)
    }

    @Test func failBranchTakesTheErrorPath() async throws {
        let nodes = [Self.start, Self.test("x", "fail", ["error_strategy": "fail-branch"]), Self.test("ok"), Self.test("onError"),
                     Self.end([("m", ["x", "error_message"]), ("t", ["x", "error_type"])])]
        let edges = [Self.edge("start", "x"), Self.edge("x", "ok"), Self.edge("x", "onError", "fail-branch"), Self.edge("ok", "end"),
                     Self.edge("onError", "end")]
        let r = try await Self.run(nodes, edges)
        #expect(r.status("x") == "exception" && r.status("onError") == "succeeded" && r.status("ok") == nil)
        guard case .runPartialSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["m": "boom", "t": "TestError"] && s.exceptionsCount == 1)
        // A node that succeeds takes its normal edge.
        let fine = try await Self.run([Self.start, Self.test("x", "ok", ["error_strategy": "fail-branch"]), Self.test("ok"), Self.test("onError"),
                                       Self.end([])], edges)
        #expect(fine.status("ok") == "succeeded" && fine.status("onError") == nil)
    }

    @Test func defaultValueContinues() async throws {
        let x = Self.test("x", "fail", ["error_strategy": "default-value",
                                        "default_value": [["key": "value", "type": "string", "value": "fallback"]]])
        let r = try await Self.run([Self.start, x, Self.end([("v", ["x", "value"]), ("e", ["x", "error_message"])])],
                                   [Self.edge("start", "x"), Self.edge("x", "end")])
        guard case .runPartialSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["v": "fallback", "e": "boom"])
        guard case .node(.exception(_, _, _, _, let result, _))? = r.events.first(where: {
            if case .node(.exception) = $0 { return true }; return false
        }) else { Issue.record("no exception event"); return }
        #expect(result.outputs.keys == ["value", "error_message", "error_type"])
        #expect(result.metadata["error_strategy"] == "default-value")
    }

    @Test func retriesThenSucceeds() async throws {
        let x = Self.test("x", "flaky", ["fails": 2, "retry_config": ["retry_enabled": true, "max_retries": 3, "retry_interval": 10]])
        let r = try await Self.run([Self.start, x, Self.end([("a", ["x", "attempt"])])], [Self.edge("start", "x"), Self.edge("x", "end")])
        let retries = r.events.compactMap { if case .node(.retry(_, _, _, _, let e, let i)) = $0 { return "\(i):\(e)" }; return nil }
        #expect(retries == ["1:flake 1", "2:flake 2"])
        // the started event is sent once; every attempt counts as a step; every failed attempt is an exception (graphon)
        #expect(r.started.filter { $0 == "x" }.count == 1)
        guard case .runPartialSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["a": 3] && s.totalSteps == 5 && s.exceptionsCount == 2)
        // retries exhausted: the run fails
        let y = Self.test("x", "flaky", ["fails": 5, "retry_config": ["retry_enabled": true, "max_retries": 1, "retry_interval": 0]])
        let failed = try await Self.run([Self.start, y, Self.end([])], [Self.edge("start", "x"), Self.edge("x", "end")])
        guard case .runFailed(let error, _)? = failed.terminal else { Issue.record("\(String(describing: failed.terminal))"); return }
        #expect(error == "flake 2")
    }

    @Test func stopAbortsTheRun() async throws {
        let commands = GraphEngineCommands()
        _ = Task {
            try await Task.sleep(for: .milliseconds(100))
            commands.abort(reason: "User requested stop")
        }
        let r = try await Self.run([Self.start, Self.test("w", "wait"), Self.test("after"), Self.end([])],
                                   [Self.edge("start", "w"), Self.edge("w", "after"), Self.edge("after", "end")], commands: commands)
        guard case .runAborted(let reason, _)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(reason == "Aborted: User requested stop")
        #expect(r.status("after") == nil)
    }

    @Test func stepLimitAborts() async throws {
        var nodes = [Self.start]
        var edges: [JSONValue] = []
        var prev = "start"
        for i in 0..<8 {
            nodes.append(Self.test("n\(i)"))
            edges.append(Self.edge(prev, "n\(i)"))
            prev = "n\(i)"
        }
        let r = try await Self.run(nodes, edges, config: GraphEngineConfig(maxSteps: 5))
        guard case .runAborted(let reason, _)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(reason == "Aborted: Maximum execution steps exceeded: 6 > 5")
    }

    @Test func answersStreamInOrder() async throws {
        // Two answers in a row: the second waits for the first; an LLM-like stream is buffered until its turn.
        let a1 = Self.node("a1", ["type": "answer", "title": "A1", "answer": "first {{#s.text#}}|"])
        let a2 = Self.node("a2", ["type": "answer", "title": "A2", "answer": "second {{#t.text#}}."])
        let nodes = [Self.start, Self.test("s", "stream", ["text": "one two"]), Self.test("t", "stream", ["text": "three four"]), a1, a2]
        let edges = [Self.edge("start", "s"), Self.edge("start", "t"), Self.edge("s", "a1"), Self.edge("t", "a1"), Self.edge("a1", "a2")]
        for workers in [1, 4] {
            let r = try await Self.run(nodes, edges, config: GraphEngineConfig(maxWorkers: workers))
            #expect(r.text == "first one two|second three four.", "workers \(workers)")
            guard case .runSucceeded(let s)? = r.terminal else { Issue.record("not succeeded"); continue }
            #expect(s.outputs["answer"] == "first one two|second three four.")
        }
    }

    @Test func inactiveStartBranchesAreSkipped() async throws {
        let other = Self.node("trigger", ["type": "start", "title": "Other start", "variables": []])
        let r = try await Self.run([Self.start, other, Self.test("a"), Self.test("b"), Self.end([])],
                                   [Self.edge("start", "a"), Self.edge("trigger", "b"), Self.edge("a", "end"), Self.edge("b", "end")])
        #expect(r.status("a") == "succeeded" && r.status("b") == nil && r.status("end") == "succeeded")
    }

    @Test func userInputsFollowDify() throws {
        let vars = try [
            ["variable": "n", "type": "number", "required": true],
            ["variable": "s", "type": "select", "options": ["x", "y"]],
            ["variable": "t", "type": "text-input", "max_length": 3, "default": "d"],
            ["variable": "c", "type": "checkbox"],
        ].map { try VariableEntity(JSONValue.object($0).object!) }
        let ok = try WorkflowBootstrap.prepareUserInputs(["n": "1.5", "s": "y", "c": "yes", "extra": "dropped"], variables: vars)
        #expect(ok == ["n": 1.5, "s": "y", "t": "d", "c": true])
        #expect(ok.keys == ["n", "s", "t", "c"])
        #expect(try WorkflowBootstrap.prepareUserInputs(["n": "7"], variables: vars)["n"] == 7)
        #expect(throws: WorkflowBootstrap.InvalidInput.self) { try WorkflowBootstrap.prepareUserInputs([:], variables: vars) }
        #expect(throws: WorkflowBootstrap.InvalidInput.self) { try WorkflowBootstrap.prepareUserInputs(["n": 1, "s": "z"], variables: vars) }
        #expect(throws: WorkflowBootstrap.InvalidInput.self) { try WorkflowBootstrap.prepareUserInputs(["n": 1, "t": "long"], variables: vars) }
    }

    @Test func conditionsFollowPython() throws {
        #expect(try ConditionProcessor.evaluate("contains", value: "hello world", expected: "hello"))
        #expect(try ConditionProcessor.evaluate("=", value: 3, expected: "3"))
        #expect(try ConditionProcessor.evaluate(">", value: 2.5, expected: "2"))
        #expect(try !ConditionProcessor.evaluate("≤", value: 3, expected: "2.5"))
        #expect(try ConditionProcessor.evaluate("in", value: "b", expected: ["a", "b"]))
        #expect(try ConditionProcessor.evaluate("all of", value: ["a", "b", "c"], expected: ["a", "c"]))
        #expect(try ConditionProcessor.evaluate("empty", value: "", expected: .null))
        #expect(try ConditionProcessor.evaluate("not null", value: 0, expected: .null))
        #expect(try ConditionProcessor.evaluate("=", value: true, expected: "1"))
        #expect(throws: ConditionProcessor.EvaluationError.self) { try ConditionProcessor.evaluate(">", value: "x", expected: "1") }
        #expect(throws: ConditionProcessor.EvaluationError.self) { try ConditionProcessor.evaluate("start with", value: "x", expected: ["a"]) }
    }

    @Test func decimalSumsKeepPythonDigits() {
        #expect((DecimalText("0.0000015") + DecimalText("0.000003")).text == "0.0000045")
        #expect((DecimalText("0") + DecimalText("0.0")).text == "0.0")
        #expect((DecimalText("1.20") + DecimalText("-2.5")).text == "-1.30")
    }
}
