// A 20-node workflow on the engine (Dify's mock nodes for the service-backed ones): wall time per run and the process's
// peak memory. `collab-runtime bench [RUNS]`.

import CollabRuntime
import Foundation

public enum Bench {
    /// start -> if-else -> two parallel chains (LLM, template, code, LLM, aggregator-ready) -> aggregator -> template -> LLM
    /// -> answer-like end: 20 nodes.
    public static func graph() -> JSONValue {
        func node(_ id: String, _ data: JSONObject) -> JSONValue { ["id": .string(id), "data": .object(data)] }
        func edge(_ s: String, _ t: String, _ h: String = "source") -> JSONValue {
            ["id": .string("\(s)-\(t)"), "source": .string(s), "target": .string(t), "sourceHandle": .string(h)]
        }
        let llm: JSONObject = ["type": "llm", "title": "LLM", "model": ["provider": "p", "name": "m", "mode": "chat", "completion_params": [:]],
                               "prompt_template": [["role": "user", "text": "{{#start.q#}}"]], "context": ["enabled": false]]
        var nodes: [JSONValue] = [node("start", ["type": "start", "title": "Start", "variables": [["variable": "q", "type": "text-input", "label": "q"]]])]
        var edges: [JSONValue] = []
        nodes.append(node("if", ["type": "if-else", "title": "If", "cases": [["case_id": "true", "logical_operator": "and", "conditions": [
            ["variable_selector": ["start", "q"], "comparison_operator": "not empty"]]]]]))
        edges.append(edge("start", "if"))
        for side in ["a", "b"] {
            var prev = "if"
            var handle = "true"
            for (i, kind) in ["llm", "template-transform", "code", "llm", "template-transform", "code", "llm"].enumerated() {
                let id = "\(side)\(i)"
                var data: JSONObject
                switch kind {
                case "llm": data = llm
                case "code": data = ["type": "code", "title": .string(id), "code_language": "python3", "code": "def main(): return {}",
                                     "variables": [], "outputs": ["result": ["type": "string"]]]
                default: data = ["type": "template-transform", "title": .string(id), "template": "{{ x }}!",
                                 "variables": [["variable": "x", "value_selector": ["start", "q"]]]]
                }
                nodes.append(node(id, data))
                edges.append(edge(prev, id, handle))
                prev = id
                handle = "source"
            }
            edges.append(edge(prev, "agg"))
        }
        nodes.append(node("agg", ["type": "variable-aggregator", "title": "Agg", "output_type": "string",
                                  "variables": [["a6", "text"], ["b6", "text"]]]))
        nodes.append(node("final", llm))
        edges.append(edge("agg", "final"))
        nodes.append(node("tpl", ["type": "template-transform", "title": "T", "template": "{{ x }}",
                                  "variables": [["variable": "x", "value_selector": ["final", "text"]]]]))
        edges.append(edge("final", "tpl"))
        nodes.append(node("end", ["type": "end", "title": "End", "outputs": [["variable": "out", "value_selector": ["tpl", "output"]],
                                                                             ["variable": "llm", "value_selector": ["final", "text"]]]]))
        edges.append(edge("tpl", "end"))
        return ["nodes": .array(nodes), "edges": .array(edges)]
    }

    /// `VmRSS` / `VmHWM` of this process (KiB) from /proc (Linux); 0 elsewhere.
    static func proc(_ key: String) -> Int {
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") where line.hasPrefix(key + ":") {
            return Int(line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "0") ?? 0
        }
        return 0
    }

    public static func run(runs: Int) async throws -> String {
        let config = try GraphConfig(json: graph())
        var times: [Double] = []
        var nodesRun = 0
        let rssBefore = proc("VmRSS")
        for _ in 0..<max(1, runs) {
            let clock = ContinuousClock.now
            let g = try await RuntimeGraph.build(config, rootId: "start", factory: MockNodeFactory())
            let pool = try WorkflowBootstrap.pool(system: WorkflowBootstrap.systemVariables([("user_id", "u")]), environment: [], conversation: [],
                                                  rootId: "start", inputs: ["q": "hello"])
            var ok = false
            nodesRun = 0
            for await e in GraphEngine(graph: g).run(pool: pool) {
                if case .node(.succeeded) = e { nodesRun += 1 }
                if case .runSucceeded = e { ok = true }
            }
            guard ok else { return "bench: the run did not succeed" }
            let d = ContinuousClock.now - clock
            times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        times.sort()
        let median = times[times.count / 2]
        let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        return String(format: "bench: %d nodes in the graph, %d succeeded per run, %d runs: median %.2f ms, p95 %.2f ms, max %.2f ms; "
                      + "RSS %.1f MiB before the runs, %.1f MiB after, peak %.1f MiB", config.nodes.count, nodesRun, times.count, median, p95,
                      times.last!, Double(rssBefore) / 1024, Double(proc("VmRSS")) / 1024, Double(proc("VmHWM")) / 1024)
    }
}
