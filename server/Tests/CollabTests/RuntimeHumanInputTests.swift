import Foundation
import Testing
@testable import CollabRuntime

@Suite("Runtime human input")
struct RuntimeHumanInputTests {
    actor Forms: HumanInputRuntime {
        var submitted = false
        var submittedNodes = Set<String>()
        var decisions: [String: Int] = [:]
        var attempts: [String: Int] = [:]
        func submit(_ nodeId: String? = nil) {
            if let nodeId { submittedNodes.insert(nodeId) } else { submitted = true }
        }
        func decide(form: HumanInputFormConfig, context: HumanInputContext) async throws -> HumanInputDecision {
            decisions[context.nodeId, default: 0] += 1
            if submitted || submittedNodes.contains(context.nodeId) {
                return .completed(try form.completion(action: "approve", values: ["reply": "yes"],
                                                       renderedContent: form.renderedContent(pool: context.pool)))
            }
            return .pause(sessionId: context.executionId!)
        }
        func attempt(_ id: String) -> Int {
            attempts[id, default: 0] += 1
            return attempts[id]!
        }
    }

    struct Effect: RuntimeNode {
        let id: String
        let base: BaseNodeData
        let forms: Forms
        let delay: Int
        let failOnce: Bool
        var nodeType: String { "effect" }
        var retryEnabled: Bool { failOnce }
        func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
            let count = await forms.attempt(id)
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            if failOnce, count == 1 {
                await emit(.completed(NodeRunResult(status: .failed, error: "try again", errorType: "Transient")))
                return
            }
            await emit(.streamChunk(selector: [id, "text"], chunk: "Saved", isFinal: true))
            await emit(.completed(NodeRunResult(status: .succeeded, outputs: ["text": "Saved"])))
        }
    }

    struct Factory: NodeFactory {
        let forms: Forms
        func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
            if config.type == "effect" {
                return Effect(id: config.id, base: try BaseNodeData(config.data), forms: forms,
                              delay: config.data["delay"]?.int ?? 0, failOnce: config.data["fail_once"]?.bool ?? false)
            }
            return try await BuiltinNodeFactory(services: RuntimeServices(humanInput: forms)).createNode(config, graph: graph)
        }
    }

    static func node(_ id: String, _ data: JSONObject) -> JSONValue { ["id": .string(id), "data": .object(data)] }
    static func edge(_ source: String, _ target: String, _ handle: String = "source") -> JSONValue {
        ["source": .string(source), "target": .string(target), "sourceHandle": .string(handle)]
    }
    static let start = node("start", ["type": "start", "title": "Start", "variables": []])
    static let human = node("human", ["type": "human-input", "title": "Approve", "form_content": "{{#$output.reply#}}",
                                     "inputs": [["type": "paragraph", "output_variable_name": "reply"]],
                                     "user_actions": [["id": "approve", "title": "Approve it"]]])
    static let end = node("end", ["type": "end", "title": "End",
                                 "outputs": [["variable": "reply", "value_selector": ["human", "reply"]]]])

    static func collect(_ stream: AsyncStream<GraphEngineEvent>) async -> [GraphEngineEvent] {
        var events: [GraphEngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    static func paused(_ events: [GraphEngineEvent]) throws -> GraphEngineSnapshot {
        guard case .runPaused(_, let snapshot, _) = events.last else {
            throw GraphEngineSnapshot.Invalid(description: "Expected a paused run")
        }
        return try GraphEngineSnapshot(data: snapshot.encoded())
    }

    static func text(_ events: [GraphEngineEvent]) -> String {
        events.compactMap { event in
            if case .node(.streamChunk(_, _, _, let chunk, _)) = event { return chunk }
            return nil
        }.joined()
    }

    @Test func durableResumeDoesNotRepeatEffectsOrStreamedText() async throws {
        let forms = Forms()
        let config = try GraphConfig(json: ["nodes": .array([
            Self.start, Self.node("once", ["type": "effect"]),
            Self.node("before", ["type": "answer", "answer": "Before "]), Self.human,
            Self.node("after", ["type": "answer", "answer": "{{#once.text#}} {{#human.reply#}}"]),
        ]), "edges": .array([Self.edge("start", "once"), Self.edge("once", "before"), Self.edge("before", "human"),
                             Self.edge("human", "after", "approve")])])
        let graph = try await RuntimeGraph.build(config, rootId: "start", factory: Factory(forms: forms))
        var pool = VariablePool()
        try pool.add(["sys", "workflow_execution_id"], "run")
        let ordered = try JSONValue.parse(#"{"b":1.0,"a":1}"#)
        try pool.add(["env", "ordered"], ordered)
        try pool.add(["env", "secret"], Segment(.secret, "private"))
        try pool.add(["env", "empty"], Segment(.arrayString, []))
        pool.remove(["empty_namespace"])
        let first = await Self.collect(GraphEngine(graph: graph).run(pool: pool))
        let snapshot = try Self.paused(first)
        #expect(Self.text(first) == "Before ")
        #expect(await forms.attempts["once"] == 1)
        let restored = snapshot.state.pools[rootFrameId]!
        #expect(restored.get(["env", "ordered"])?.value == ordered)
        #expect(restored.get(["env", "secret"])?.valueType == .secret)
        #expect(restored.get(["env", "empty"])?.valueType == .arrayString)
        #expect(restored.nodeOrder.prefix(3) == ["sys", "env", "empty_namespace"])
        await forms.submit()
        // Rebuild node instances and engine: no suspended Task or closure carries execution across the boundary.
        let rebuilt = try await RuntimeGraph.build(config, rootId: "start", factory: Factory(forms: forms))
        let second = await Self.collect(try GraphEngine(graph: rebuilt).resume(snapshot))
        if case .runResumed = second.first {} else { Issue.record("Missing resumption start reason") }
        #expect(Self.text(first) + Self.text(second) == "Before Saved yes")
        #expect(await forms.attempts["once"] == 1)
        guard case .runSucceeded(let stats) = second.last else { Issue.record("Resume did not succeed"); return }
        #expect(stats.outputs["answer"] == "Before Saved yes")
        func humanId(_ events: [GraphEngineEvent]) -> String? {
            events.compactMap { if case .node(.started(let id, "human", _, _, _, _)) = $0 { return id }; return nil }.first
        }
        #expect(humanId(first) != nil && humanId(first) == humanId(second))
        var changed = config.json.object!
        changed["extra"] = true
        let other = try await RuntimeGraph.build(GraphConfig(json: .object(changed)), rootId: "start", factory: Factory(forms: forms))
        #expect(throws: GraphEngineSnapshot.Invalid.self) { try GraphEngine(graph: other).resume(snapshot) }
    }

    @Test(arguments: [false, true])
    func pauseDrainsActiveWorkAndRetryTimers(retry: Bool) async throws {
        let forms = Forms()
        let effect: JSONObject = ["type": "effect", "delay": 25, "fail_once": .bool(retry),
                                 "retry_config": ["max_retries": 1, "retry_interval": 30, "retry_enabled": true]]
        let config = try GraphConfig(json: ["nodes": .array([Self.start, Self.human, Self.node("slow", effect),
                                                           Self.node("next", ["type": "effect"]), Self.end]),
                                           "edges": .array([Self.edge("start", "human"), Self.edge("start", "slow"),
                                                            Self.edge("slow", "next"), Self.edge("human", "end", "approve"),
                                                            Self.edge("next", "end")])])
        let graph = try await RuntimeGraph.build(config, rootId: "start", factory: Factory(forms: forms))
        var pool = VariablePool()
        try pool.add(["sys", "workflow_execution_id"], "run")
        let snapshot = try Self.paused(await Self.collect(GraphEngine(graph: graph, config: .init(maxWorkers: 2)).run(pool: pool)))
        #expect(await forms.attempts["slow"] == 1)
        #expect(await forms.attempts["next"] == nil)
        await forms.submit()
        let resumed = await Self.collect(try GraphEngine(graph: graph).resume(snapshot))
        #expect(await forms.attempts["slow"] == (retry ? 2 : 1))
        #expect(await forms.attempts["next"] == 1)
        switch resumed.last {
        case .runSucceeded where !retry, .runPartialSucceeded where retry: break
        default: Issue.record("Resumed run did not complete")
        }
    }

    @Test(arguments: [false, true])
    func containersResumeTheirExistingFrames(loop: Bool) async throws {
        let forms = Forms()
        let kind = loop ? "loop" : "iteration"
        var human = Self.human.object!
        var humanData = human["data"]!.object!
        humanData[loop ? "loop_id" : "iteration_id"] = "container"
        humanData[loop ? "isInLoop" : "isInIteration"] = true
        human["data"] = .object(humanData)
        let effect = Self.node("effect", ["type": "effect", loop ? "loop_id" : "iteration_id": "container",
                                          loop ? "isInLoop" : "isInIteration": true])
        var container: JSONObject = ["type": .string(kind), "title": "Container", "start_node_id": "inner-start"]
        let ending: JSONValue
        var nodes: [JSONValue] = [Self.start, effect, .object(human),
                                  Self.node("inner-start", ["type": .string(kind + "-start")])]
        var edges = [Self.edge("start", "container"), Self.edge("inner-start", "effect"), Self.edge("effect", "human"),
                     Self.edge("container", "end")]
        if loop {
            container["loop_count"] = 2
            container["break_conditions"] = []
            container["logical_operator"] = "and"
            container["loop_variables"] = [["label": "n", "var_type": "number", "value_type": "constant", "value": "0"]]
            nodes.append(Self.node("increment", ["type": "assigner", "version": "2", "loop_id": "container", "isInLoop": true,
                                                  "items": [["input_type": "constant", "operation": "+=", "value": 1,
                                                             "variable_selector": ["container", "n"], "write_mode": "over-write"]]]))
            edges.append(Self.edge("human", "increment", "approve"))
            ending = Self.node("end", ["type": "end", "outputs": [["variable": "result", "value_selector": ["container", "n"]]]])
        } else {
            container["iterator_selector"] = ["start", "items"]
            container["output_selector"] = ["human", "reply"]
            container["is_parallel"] = true
            container["parallel_nums"] = 3
            ending = Self.node("end", ["type": "end", "outputs": [["variable": "result", "value_selector": ["container", "output"]]]])
        }
        nodes.append(contentsOf: [Self.node("container", container), ending])
        let config = try GraphConfig(json: ["nodes": .array(nodes), "edges": .array(edges)])
        let graph = try await RuntimeGraph.build(config, rootId: "start", factory: Factory(forms: forms))
        var pool = VariablePool()
        try pool.add(["sys", "workflow_execution_id"], "run")
        try pool.add(["start", "items"], [1, 2, 3, 4])
        let snapshot = try Self.paused(await Self.collect(GraphEngine(graph: graph).run(pool: pool)))
        #expect(!snapshot.state.containers.isEmpty && snapshot.state.frames.count > 1)
        await forms.submit()
        let rebuilt = try await RuntimeGraph.build(config, rootId: "start", factory: Factory(forms: forms))
        let resumed = await Self.collect(try GraphEngine(graph: rebuilt).resume(snapshot))
        guard case .runSucceeded(let stats) = resumed.last else { Issue.record("Container resume did not succeed"); return }
        #expect(stats.outputs["result"] == (loop ? 2 : ["yes", "yes", "yes", "yes"]))
        #expect(await forms.attempts["effect"] == (loop ? 2 : 4))
    }

    @Test func parallelFormsJoinAfterSeparateDurableResumptions() async throws {
        let forms = Forms()
        var other = Self.human.object!
        other["id"] = "other"
        let end = Self.node("end", ["type": "end", "outputs": [["variable": "a", "value_selector": ["human", "reply"]],
                                                               ["variable": "b", "value_selector": ["other", "reply"]]]])
        let config = try GraphConfig(json: ["nodes": .array([Self.start, Self.human, .object(other), end]),
                                           "edges": .array([Self.edge("start", "human"), Self.edge("start", "other"),
                                                            Self.edge("human", "end", "approve"), Self.edge("other", "end", "approve")])])
        func engine() async throws -> GraphEngine {
            GraphEngine(graph: try await RuntimeGraph.build(config, rootId: "start", factory: Factory(forms: forms)))
        }
        var pool = VariablePool()
        try pool.add(["sys", "workflow_execution_id"], "run")
        let initial = try Self.paused(await Self.collect(try await engine().run(pool: pool)))
        await forms.submit("human")
        let first = await Self.collect(try await engine().resume(initial))
        let next = try Self.paused(first)
        #expect(next.state.pools[rootFrameId]?.get(["human", "reply"])?.value == "yes")
        #expect(!first.contains { if case .node(.started(_, "end", _, _, _, _)) = $0 { return true }; return false })
        await forms.submit("other")
        let final = await Self.collect(try await engine().resume(next))
        guard case .runSucceeded(let stats) = final.last else { Issue.record("Join did not finish"); return }
        #expect(stats.outputs == ["a": "yes", "b": "yes"])
        #expect(await forms.decisions["human"] == 2)
        #expect(await forms.decisions["other"] == 3)
    }

    /// Recorded by e2e/traces/record_human_input_forms.py inside the pinned Dify 1.17.1 image, using its own
    /// validation and callback, not a second implementation of the Swift form logic.
    @Test func formsMatchDify() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/human-input/forms.json")
        let cases = try JSONValue.parse(Data(contentsOf: path)).array!
        var pool = VariablePool()
        try pool.add(["start", "name"], "World")
        for item in cases {
            let config = try HumanInputFormConfig(item["data"]!.object!)
            #expect(config.renderedContent(pool: pool) == item["rendered"]?.string, "\(item["id"]!)")
            #expect(config.resolvedDefaults(pool: pool) == item["defaults"]?.object, "\(item["id"]!)")
            let mapping = JSONObject(config.variableMapping(nodeId: "hi").map { ($0.key, .array($0.selector.map(JSONValue.string))) })
            #expect(mapping == item["mapping"]?.object, "\(item["id"]!)")
            do {
                let result = try config.completion(action: item["action"]!.string!, values: item["values"]!.object!,
                                                   renderedContent: config.renderedContent(pool: pool))
                #expect(item["error"] == nil, "\(item["id"]!)")
                #expect(result.inputs == item["expected_inputs"]?.object, "\(item["id"]!)")
                #expect(result.outputs == item["expected_outputs"]?.object, "\(item["id"]!)")
                #expect(result.edgeSourceHandle == item["action"]?.string)
            } catch let error as HumanInputFormConfig.InvalidSubmission {
                #expect(error.description == item["error"]?.string, "\(item["id"]!)")
            }
        }
    }

    @Test func duplicateFieldsAndActionsAreRefused() throws {
        let input: JSONValue = ["type": "paragraph", "output_variable_name": "reply"]
        #expect(throws: NodeDataError.self) {
            try HumanInputFormConfig(["inputs": .array([input, input])])
        }
        let action: JSONValue = ["id": "approve", "title": "Approve"]
        #expect(throws: NodeDataError.self) {
            try HumanInputFormConfig(["user_actions": .array([action, action])])
        }
        #expect(throws: NodeDataError.self) {
            try HumanInputFormConfig(["user_actions": [["id": "bad-action", "title": "Approve"]]])
        }
    }

    @Test func timeoutUsesSeparateHandleAndPreservesUnsubmittedContent() throws {
        let config = try HumanInputFormConfig(["timeout": 2, "timeout_unit": "day"])
        let start = Date(timeIntervalSince1970: 100)
        #expect(config.expirationTime(from: start).timeIntervalSince1970 == 172900)
        let result = config.timeoutResult(renderedContent: "Hello {{#$output.reply#}}")
        #expect(result.edgeSourceHandle == "__timeout")
        #expect(result.inputs.isEmpty)
        #expect(result.outputs == ["__action_id": "", "__action_value": "", "__rendered_content": "Hello {{#$output.reply#}}"])
    }

    @Test func filesRequireStorageRatherThanAcceptingUnverifiedReferences() throws {
        let config = try HumanInputFormConfig(["inputs": [["type": "file", "output_variable_name": "upload"]],
                                              "user_actions": [["id": "approve", "title": "Approve"]]])
        #expect(config.requiresFileStorage)
        #expect(throws: HumanInputFormConfig.InvalidSubmission.self) {
            try config.validateSubmission(action: "approve", values: ["upload": ["id": "someone-elses-upload"]])
        }
    }
}
