import Foundation
import Testing
@testable import CollabRuntime

/// Iteration and loop nodes on the engine (protocol 1.15, graphon 0.7.0's container frames): rounds in child frames,
/// parallel iterations, error handle modes, flattening, item / index variables, nesting, loop variables, break conditions
/// and loop-end, the container events, scopes and metadata, retries, stop and the step limit inside containers, and the
/// iteration / loop single run.
@Suite("Runtime containers")
struct RuntimeContainerTests {
    typealias E = RuntimeEngineTests

    static func node(_ id: String, _ data: JSONObject, in container: String? = nil, loop: Bool = false) -> JSONValue {
        var d = data
        if let container {
            d[loop ? "loop_id" : "iteration_id"] = .string(container)
            d[loop ? "isInLoop" : "isInIteration"] = true
        }
        return ["id": .string(id), "data": .object(d)]
    }

    /// An iteration node `id` over `over` collecting `output`, with its start node `<id>start`.
    static func iteration(_ id: String, over: [String], output: [String], parallel: Int? = nil, mode: String? = nil, flatten: Bool? = nil,
                          extra: JSONObject = [:], in container: String? = nil) -> [JSONValue] {
        var d: JSONObject = ["type": "iteration", "title": .string(id), "start_node_id": .string("\(id)start"),
                             "iterator_selector": .array(over.map(JSONValue.string)), "output_selector": .array(output.map(JSONValue.string))]
        if let parallel { d["is_parallel"] = true; d["parallel_nums"] = .int(parallel) }
        if let mode { d["error_handle_mode"] = .string(mode) }
        if let flatten { d["flatten_output"] = .bool(flatten) }
        for (k, v) in extra { d[k] = v }
        return [node(id, d, in: container), node("\(id)start", ["type": "iteration-start", "title": ""], in: id)]
    }

    static func loop(_ id: String, count: Int, breakWhen: [JSONValue] = [], variables: [JSONValue] = [], in container: String? = nil) -> [JSONValue] {
        let d: JSONObject = ["type": "loop", "title": .string(id), "start_node_id": .string("\(id)start"), "loop_count": .int(count),
                             "break_conditions": .array(breakWhen), "logical_operator": "and", "loop_variables": .array(variables)]
        return [node(id, d, in: container), node("\(id)start", ["type": "loop-start", "title": ""], in: id, loop: true)]
    }

    static func echo(_ id: String, read: [String], _ extra: JSONObject = [:], in container: String, loop: Bool = false) -> JSONValue {
        var d: JSONObject = ["type": "test", "title": .string(id), "behavior": "echo", "read": .array(read.map(JSONValue.string))]
        for (k, v) in extra { d[k] = v }
        return node(id, d, in: container, loop: loop)
    }

    /// `start` -> `code` (a list in `start.list`) is replaced by the start input itself: the iteration reads `start.list`.
    static func run(_ nodes: [JSONValue], _ edges: [JSONValue], list: JSONValue = [1, 2, 3], config: GraphEngineConfig = GraphEngineConfig(),
                    commands: GraphEngineCommands = GraphEngineCommands(), factory: E.TestFactory = E.TestFactory()) async throws -> E.Run {
        try await E.run([E.start] + nodes, edges, inputs: ["list": list], config: config, commands: commands, factory: factory)
    }

    static func containerEvents(_ r: E.Run) -> [String] {
        r.events.compactMap { e in
            guard case .node(let n) = e else { return nil }
            switch n {
            case .containerStarted(_, let id, let k, _, _, _): return "\(k.rawValue)_started:\(id)"
            case .containerNext(_, let id, let k, let i, _): return "\(k.rawValue)_next:\(id):\(i)"
            case .containerCompleted(_, let id, let k, _, _, _, _, let steps, let error):
                return "\(k.rawValue)_completed:\(id):\(steps)" + (error.map { ":\($0)" } ?? "")
            default: return nil
            }
        }
    }

    static func results(_ r: E.Run, _ id: String) -> [NodeRunResult] {
        r.events.compactMap { e in
            guard case .node(let n) = e, n.nodeId == id, let res = n.result else { return nil }
            return res
        }
    }

    // MARK: Iteration

    @Test func sequentialIteration() async throws {
        let nodes = Self.iteration("it", over: ["start", "list"], output: ["e", "value"])
            + [Self.echo("e", read: ["it", "item"], in: "it"), E.end([("out", ["it", "output"])])]
        let edges = [E.edge("start", "it"), E.edge("itstart", "e"), E.edge("it", "end")]
        let r = try await Self.run(nodes, edges)
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["out": [1, 2, 3]])
        #expect(Self.containerEvents(r) == ["iteration_started:it", "iteration_next:it:0", "iteration_next:it:1", "iteration_next:it:2",
                                            "iteration_completed:it:3"])
        // The rounds' start node is not collected; the inner node runs once per item, in the iteration's scope.
        #expect(!r.started.contains("itstart") && r.started.filter { $0 == "e" }.count == 3)
        let scopes = r.events.compactMap { e -> NodeScope? in
            if case .node(.started(_, "e", _, _, _, let scope)) = e { return scope }
            return nil
        }
        #expect(scopes == Array(repeating: NodeScope(iterationId: "it"), count: 3))
        #expect(Self.results(r, "e").map { $0.metadata["iteration_index"] } == [0, 1, 2])
        #expect(Self.results(r, "e").allSatisfy { $0.metadata["iteration_id"] == "it" })
        // Steps count the root frame's nodes only (start, iteration, end); the item and index are the round's.
        #expect(s.totalSteps == 3)
        guard let it = Self.results(r, "it").first else { Issue.record("no iteration result"); return }
        #expect(it.inputs == ["iterator_selector": [1, 2, 3]] && it.outputs == ["output": [1, 2, 3]])
        #expect(it.metadata.keys == ["total_tokens", "total_price", "currency", "iteration_duration_map"])
        #expect(it.metadata["iteration_duration_map"]?.object?.keys == ["0", "1", "2"])
    }

    @Test func parallelIterationKeepsOrderAndWidth() async throws {
        let factory = E.TestFactory()
        let list: JSONValue = .array((0..<10).map { .int($0) })
        let nodes = Self.iteration("it", over: ["start", "list"], output: ["e", "value"], parallel: 3)
            + [Self.echo("e", read: ["it", "item"], ["sleep_ms": 60], in: "it"), E.end([("out", ["it", "output"])])]
        let edges = [E.edge("start", "it"), E.edge("itstart", "e"), E.edge("it", "end")]
        let r = try await Self.run(nodes, edges, list: list, factory: factory)
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["out": list])
        // parallel_nums rounds at a time, and they did overlap.
        #expect(factory.attempts.maxConcurrent == 3)
        let nexts = Self.containerEvents(r).filter { $0.hasPrefix("iteration_next") }
        #expect(nexts == (0..<10).map { "iteration_next:it:\($0)" })
    }

    @Test func errorHandleModes() async throws {
        func run(_ mode: String) async throws -> E.Run {
            let nodes = Self.iteration("it", over: ["start", "list"], output: ["e", "value"], mode: mode)
                + [Self.echo("e", read: ["it", "item"], ["fail_on": 2], in: "it"), E.end([("out", ["it", "output"])])]
            return try await Self.run(nodes, [E.edge("start", "it"), E.edge("itstart", "e"), E.edge("it", "end")])
        }
        let terminated = try await run("terminated")
        guard case .runFailed(let error, let s)? = terminated.terminal else { Issue.record("\(String(describing: terminated.terminal))"); return }
        // Both the inner node and the iteration node failed (graphon counts every failed node event).
        #expect(error == "bad 2" && s.exceptionsCount == 2)
        // The failed round stops the iteration (no round after it); the completed event carries the error.
        #expect(terminated.started.filter { $0 == "e" }.count == 2)
        #expect(Self.containerEvents(terminated).last == "iteration_completed:it:3:bad 2")
        #expect(terminated.status("it") == "failed")

        let cont = try await run("continue-on-error")
        guard case .runPartialSucceeded(let c)? = cont.terminal else { Issue.record("\(String(describing: cont.terminal))"); return }
        #expect(c.outputs == ["out": [1, .null, 3]] && c.exceptionsCount == 1)

        let remove = try await run("remove-abnormal-output")
        guard case .runPartialSucceeded(let rm)? = remove.terminal else { Issue.record("\(String(describing: remove.terminal))"); return }
        #expect(rm.outputs == ["out": [1, 3]])
    }

    @Test func flattenAndEmptyAndInvalidIterators() async throws {
        // Each round outputs a list: flattened by default, kept with flatten_output false.
        let pair = Self.node("p", ["type": "test", "title": "p", "behavior": "echo", "read": ["it", "item"]], in: "it")
        for (flatten, expected) in [(true, [1, 2, 3, 4] as JSONValue), (false, [[1, 2], [3, 4]] as JSONValue)] {
            let nodes = Self.iteration("it", over: ["start", "list"], output: ["p", "value"], flatten: flatten) + [pair, E.end([("out", ["it", "output"])])]
            let r = try await Self.run(nodes, [E.edge("start", "it"), E.edge("itstart", "p"), E.edge("it", "end")], list: [[1, 2], [3, 4]])
            guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); continue }
            #expect(s.outputs == ["out": expected], "flatten \(flatten)")
        }
        // An empty list completes at once with an empty list.
        let nodes = Self.iteration("it", over: ["start", "list"], output: ["e", "value"])
            + [Self.echo("e", read: ["it", "item"], in: "it"), E.end([("out", ["it", "output"])])]
        let edges = [E.edge("start", "it"), E.edge("itstart", "e"), E.edge("it", "end")]
        let empty = try await Self.run(nodes, edges, list: [])
        guard case .runSucceeded(let s)? = empty.terminal else { Issue.record("\(String(describing: empty.terminal))"); return }
        #expect(s.outputs == ["out": []] && Self.containerEvents(empty) == ["iteration_started:it", "iteration_completed:it:0"])
        // Not a list: the iteration node fails.
        let bad = try await Self.run(nodes, edges, list: "abc")
        guard case .runFailed(let error, _)? = bad.terminal else { Issue.record("\(String(describing: bad.terminal))"); return }
        #expect(error == "invalid iterator value: value_type=<SegmentType.STRING: 'string'> value='abc', please provide a list.")
    }

    @Test func nestedIterationsAndScopes() async throws {
        // outer over [[1, 2], [3]], inner over the outer item: [[1, 2], [3]] (inner outputs are lists, flattened: [1, 2, 3]).
        let nodes = Self.iteration("outer", over: ["start", "list"], output: ["inner", "output"])
            + Self.iteration("inner", over: ["outer", "item"], output: ["e", "value"], in: "outer")
            + [Self.echo("e", read: ["inner", "item"], in: "inner"), E.end([("out", ["outer", "output"])])]
        let edges = [E.edge("start", "outer"), E.edge("outerstart", "inner"), E.edge("innerstart", "e"), E.edge("outer", "end")]
        let r = try await Self.run(nodes, edges, list: [[1, 2], [3]])
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["out": [1, 2, 3]])
        #expect(Self.results(r, "e").map { $0.metadata["iteration_id"] } == ["inner", "inner", "inner"])
        #expect(Self.results(r, "inner").map { $0.metadata["iteration_id"] } == ["outer", "outer"])
        #expect(Self.containerEvents(r).filter { $0.hasPrefix("iteration_started") } == ["iteration_started:outer", "iteration_started:inner",
                                                                                           "iteration_started:inner"])
    }

    @Test func retriesAndFailBranchInsideAnIteration() async throws {
        let flaky = Self.node("f", ["type": "test", "title": "f", "behavior": "flaky", "fails": 1,
                                    "retry_config": ["retry_enabled": true, "max_retries": 2, "retry_interval": 0]], in: "it")
        let nodes = Self.iteration("it", over: ["start", "list"], output: ["f", "attempt"]) + [flaky, E.end([("out", ["it", "output"])])]
        let r = try await Self.run(nodes, [E.edge("start", "it"), E.edge("itstart", "f"), E.edge("it", "end")], list: [7, 8])
        // The flaky node fails once in all (attempt counts are per node id, not per round): one retry, in round 0.
        let retries = r.events.compactMap { e -> JSONValue? in
            if case .node(.retry(_, "f", _, let res, _, let i)) = e { return [.int(i), res.metadata["iteration_index"] ?? .null] }
            return nil
        }
        #expect(retries == [[1, 0]])
        guard case .runPartialSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["out": [2, 3]])
        // Fail branch inside: the round goes on along the error path.
        let x = Self.echo("x", read: ["it", "item"], ["fail_on": 8, "error_strategy": "fail-branch"], in: "it")
        let onError = Self.node("onError", ["type": "test", "title": "onError", "value": "recovered"], in: "it")
        let ok = Self.node("ok", ["type": "test", "title": "ok", "value": "fine"], in: "it")
        let agg = Self.node("agg", ["type": "variable-aggregator", "title": "agg", "output_type": "string",
                                    "variables": [["ok", "value"], ["onError", "value"]]], in: "it")
        let fb = Self.iteration("it", over: ["start", "list"], output: ["agg", "output"]) + [x, ok, onError, agg, E.end([("out", ["it", "output"])])]
        let fbEdges = [E.edge("start", "it"), E.edge("itstart", "x"), E.edge("x", "ok"), E.edge("x", "onError", "fail-branch"),
                       E.edge("ok", "agg"), E.edge("onError", "agg"), E.edge("it", "end")]
        let r2 = try await Self.run(fb, fbEdges, list: [7, 8])
        guard case .runPartialSucceeded(let s2)? = r2.terminal else { Issue.record("\(String(describing: r2.terminal))"); return }
        #expect(s2.outputs == ["out": ["fine", "recovered"]] && s2.exceptionsCount == 1)
    }

    @Test func stopAndStepLimitInsideAnIteration() async throws {
        let commands = GraphEngineCommands()
        _ = Task {
            try await Task.sleep(for: .milliseconds(150))
            commands.abort(reason: "User requested stop")
        }
        let waiting = Self.iteration("it", over: ["start", "list"], output: ["w", "value"])
            + [Self.node("w", ["type": "test", "title": "w", "behavior": "wait"], in: "it"), E.end([])]
        let r = try await Self.run(waiting, [E.edge("start", "it"), E.edge("itstart", "w"), E.edge("it", "end")], commands: commands)
        guard case .runAborted(let reason, _)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(reason == "Aborted: User requested stop" && r.status("it") == nil)
        // Inner nodes count as steps: 600 rounds pass Dify's 500.
        let many: JSONValue = .array((0..<600).map { .int($0) })
        let nodes = Self.iteration("it", over: ["start", "list"], output: ["e", "value"])
            + [Self.echo("e", read: ["it", "item"], in: "it"), E.end([])]
        let limited = try await Self.run(nodes, [E.edge("start", "it"), E.edge("itstart", "e"), E.edge("it", "end")], list: many,
                                         config: GraphEngineConfig(maxSteps: 500))
        guard case .runAborted(let why, _)? = limited.terminal else { Issue.record("\(String(describing: limited.terminal))"); return }
        #expect(why == "Aborted: Maximum execution steps exceeded: 501 > 500")
    }

    // MARK: Loop

    static let assigner: JSONObject = ["type": "assigner", "title": "inc", "version": "2", "items": [[
        "input_type": "constant", "operation": "+=", "value": 1, "variable_selector": ["lp", "num"], "write_mode": "over-write",
    ]]]

    static let numVariable: JSONValue = ["label": "num", "var_type": "number", "value_type": "constant", "value": "1"]

    static func numAtLeast(_ n: Int) -> JSONValue {
        ["variable_selector": ["lp", "num"], "comparison_operator": "≥", "value": .string(String(n)), "varType": "number"]
    }

    @Test func loopVariablesAndBreakCondition() async throws {
        let nodes = Self.loop("lp", count: 10, breakWhen: [Self.numAtLeast(5)], variables: [Self.numVariable])
            + [Self.node("inc", Self.assigner, in: "lp", loop: true), E.end([("num", ["lp", "num"])])]
        let edges = [E.edge("start", "lp"), E.edge("lpstart", "inc"), E.edge("lp", "end")]
        let r = try await Self.run(nodes, edges)
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["num": 5])
        // No next event before the first round; steps are loop_count also when a break ends it.
        #expect(Self.containerEvents(r) == ["loop_started:lp", "loop_next:lp:1", "loop_next:lp:2", "loop_next:lp:3", "loop_completed:lp:10"])
        guard let res = Self.results(r, "lp").first else { Issue.record("no loop result"); return }
        #expect(res.inputs == ["loop_count": 10, "num": 1] && res.outputs == ["num": 5, "loop_round": 4])
        #expect(res.metadata["loop_variable_map"] == ["0": ["num": 2], "1": ["num": 3], "2": ["num": 4], "3": ["num": 5]])
        let completed = r.events.compactMap { e -> JSONObject? in
            if case .node(.containerCompleted(_, _, _, _, _, _, let m, _, _)) = e { return m }
            return nil
        }
        #expect(completed.first?["completed_reason"] == "loop_break")
        #expect(Self.results(r, "inc").allSatisfy { $0.metadata["loop_id"] == "lp" })
    }

    @Test func loopEndCountAndEarlyBreak() async throws {
        // A loop end behind an if-else ends the loop in its round (num reaches 3).
        let ifElse = Self.node("if", ["type": "if-else", "title": "if", "cases": [[
            "case_id": "done", "logical_operator": "and", "conditions": [Self.numAtLeast(3)]]]], in: "lp", loop: true)
        let nodes = Self.loop("lp", count: 10, variables: [Self.numVariable])
            + [Self.node("inc", Self.assigner, in: "lp", loop: true), ifElse,
               Self.node("stop", ["type": "loop-end", "title": "stop"], in: "lp", loop: true), E.end([("num", ["lp", "num"])])]
        let edges = [E.edge("start", "lp"), E.edge("lpstart", "inc"), E.edge("inc", "if"), E.edge("if", "stop", "done"), E.edge("lp", "end")]
        let r = try await Self.run(nodes, edges)
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["num": 3] && r.started.filter { $0 == "inc" }.count == 2)
        // loop_count rounds without a break.
        let counted = try await Self.run(Self.loop("lp", count: 3, variables: [Self.numVariable])
                                             + [Self.node("inc", Self.assigner, in: "lp", loop: true), E.end([("num", ["lp", "num"])])],
                                         [E.edge("start", "lp"), E.edge("lpstart", "inc"), E.edge("lp", "end")])
        guard case .runSucceeded(let c)? = counted.terminal else { Issue.record("\(String(describing: counted.terminal))"); return }
        #expect(c.outputs == ["num": 4])
        // Break conditions that hold before the first round: no round, steps 0.
        let early = try await Self.run(Self.loop("lp", count: 3, breakWhen: [Self.numAtLeast(1)], variables: [Self.numVariable])
                                           + [Self.node("inc", Self.assigner, in: "lp", loop: true), E.end([("num", ["lp", "num"])])],
                                       [E.edge("start", "lp"), E.edge("lpstart", "inc"), E.edge("lp", "end")])
        #expect(early.started.contains("inc") == false && Self.containerEvents(early) == ["loop_started:lp", "loop_completed:lp:0"])
        guard case .runSucceeded(let e)? = early.terminal else { Issue.record("\(String(describing: early.terminal))"); return }
        #expect(e.outputs == ["num": 1])
    }

    @Test func loopInsideAnIteration() async throws {
        // Per item: a loop adds 1 to num twice; the loop variable starts at the item.
        let start: JSONValue = ["label": "num", "var_type": "number", "value_type": "variable", "value": ["it", "item"]]
        let nodes = Self.iteration("it", over: ["start", "list"], output: ["lp", "num"])
            + Self.loop("lp", count: 2, variables: [start], in: "it")
            + [Self.node("inc", Self.assigner, in: "lp", loop: true), E.end([("out", ["it", "output"])])]
        let edges = [E.edge("start", "it"), E.edge("itstart", "lp"), E.edge("lpstart", "inc"), E.edge("it", "end")]
        let r = try await Self.run(nodes, edges, list: [10, 20])
        guard case .runSucceeded(let s)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(s.outputs == ["out": [12, 22]])
        let scopes = r.events.compactMap { e -> NodeScope? in
            if case .node(.started(_, "inc", _, _, _, let scope)) = e { return scope }
            return nil
        }
        #expect(scopes.count == 4 && scopes.allSatisfy { $0 == NodeScope(iterationId: "it", loopId: "lp") })
        #expect(Self.results(r, "inc").map { $0.metadata["iteration_index"] } == [0, 0, 1, 1])
    }

    @Test func failingRoundFailsTheLoop() async throws {
        let nodes = Self.loop("lp", count: 3, variables: [Self.numVariable])
            + [Self.node("x", ["type": "test", "title": "x", "behavior": "fail"], in: "lp", loop: true), E.end([])]
        let r = try await Self.run(nodes, [E.edge("start", "lp"), E.edge("lpstart", "x"), E.edge("lp", "end")])
        guard case .runFailed(let error, _)? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(error == "boom" && Self.containerEvents(r).last == "loop_completed:lp:3:boom")
        guard let res = Self.results(r, "lp").first else { Issue.record("no loop result"); return }
        #expect(res.status == .failed && res.outputs.isEmpty)
    }

    // MARK: Single runs

    @Test func iterationSingleRun() async throws {
        // The draft: start -> code -> iteration (over the code's result) -> end; the single run gets the list as input.
        let nodes: [JSONValue] = [E.start, E.test("code", "ok", ["value": [5, 6]])]
            + Self.iteration("it", over: ["code", "value"], output: ["e", "value"])
            + [Self.echo("e", read: ["it", "item"], in: "it"), E.end([("out", ["it", "output"])])]
        let edges = [E.edge("start", "code"), E.edge("code", "it"), E.edge("itstart", "e"), E.edge("it", "end")]
        let graph = try GraphConfig(json: ["nodes": .array(nodes), "edges": .array(edges)])
        let run = ContainerSingleRun(graph: graph, environmentVariables: [], factory: E.TestFactory())
        let filtered = try ContainerSingleRun.filteredGraph(graph, nodeId: "it", kind: .iteration)
        #expect(filtered.nodes.map(\.id) == ["it", "itstart", "e"] && filtered.edges.map(\.source) == ["itstart"])
        await #expect(throws: ContainerSingleRun.InvalidInput.self) {
            _ = try await run.prepare(nodeId: "it", kind: .iteration, userInputs: [:], runId: "r")
        }
        let prepared = try await run.prepare(nodeId: "it", kind: .iteration, userInputs: ["it.input_selector": [5, 6, 7]], runId: "r")
        var events: [GraphEngineEvent] = []
        for await e in GraphEngine(graph: prepared.graph).run(pool: prepared.pool) { events.append(e) }
        let r = E.Run(events: events)
        guard case .runSucceeded? = r.terminal else { Issue.record("\(String(describing: r.terminal))"); return }
        #expect(r.started == ["it", "e", "e", "e"] && Self.results(r, "it").first?.outputs == ["output": [5, 6, 7]])
        await #expect(throws: ContainerSingleRun.InvalidInput.self) {
            _ = try await run.prepare(nodeId: "it", kind: .loop, userInputs: [:], runId: "r")
        }
    }

    @Test func nestedSingleRunValidatesDescendantInputsBeforeExecution() async throws {
        let check: JSONObject = ["type": "if-else", "title": "External", "cases": [
            ["case_id": "yes", "logical_operator": "and", "conditions": [
                ["variable_selector": ["start", "topic"], "comparison_operator": "not empty"]]]]]
        let nodes = [E.start] + Self.iteration("outer", over: ["start", "list"], output: ["inner", "output"])
            + Self.iteration("inner", over: ["outer", "item"], output: ["inner", "item"], in: "outer")
            + [Self.node("check", check, in: "inner")]
        let graph = try GraphConfig(json: ["nodes": .array(nodes), "edges": []])
        let run = ContainerSingleRun(graph: graph, environmentVariables: [], factory: E.TestFactory())
        do {
            _ = try await run.prepare(nodeId: "outer", kind: .iteration,
                                      userInputs: ["outer.input_selector": [["x"]]], runId: "r")
            Issue.record("missing nested input was accepted")
        } catch let error as ContainerSingleRun.InvalidInput {
            #expect(error.description == "Variable key inner.check.check.#start.topic# not found in user inputs.")
        }
        let prepared = try await run.prepare(nodeId: "outer", kind: .iteration,
                                              userInputs: ["outer.input_selector": [["x"]], "inner.check.check.#start.topic#": "rivers"], runId: "r")
        #expect(prepared.pool.get(["start", "topic"])?.value == "rivers")
        #expect(prepared.graph.nodes["check"] == nil, "single-run filtering still follows Dify")
    }

}
