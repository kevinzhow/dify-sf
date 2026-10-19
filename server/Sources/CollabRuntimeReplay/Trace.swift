// The normalized run traces of e2e/lib/runtrace.py ("dify-sf-trace/1") in Swift: the builder over the engine's
// events, the normalization and the comparison by per-branch partial order. Keep in step with runtrace.py.

import CollabRuntime
import Foundation

public enum RunTrace {
    public static let schema = "dify-sf-trace/1"
    static let volatileSys: Set<String> = ["sys.workflow_run_id", "sys.user_id", "sys.app_id", "sys.workflow_id", "sys.conversation_id",
                                           "sys.timestamp", "sys.message_id", "sys.workflow_execution_id"]
    static let volatileUsage: Set<String> = ["latency", "time_to_first_token", "time_to_generate", "created_at", "elapsed_time"]

    static func isUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isHexDigit } }
    }

    /// `norm_value`.
    public static func norm(_ v: JSONValue, key: String? = nil) -> JSONValue {
        switch v {
        case .null, .bool, .int: return v
        case .double(let d):
            if d.isNaN || d.isInfinite { return .string(d.isNaN ? "nan" : (d < 0 ? "-inf" : "inf")) }
            if d == d.rounded(), abs(d) < 9.2e18 { return .int(Int(d)) }
            return .double(Double(String(format: "%.12g", d)) ?? d)
        case .string(let s): return isUUID(s) ? .string("<uuid>") : v
        case .object(let o):
            var out = JSONObject()
            for (k, x) in o {
                if volatileSys.contains(k) { out[k] = .string("<volatile>") }
                else if key == "usage", volatileUsage.contains(k) { continue }
                else { out[k] = norm(x, key: k) }
            }
            return .object(out)
        case .array(let a): return .array(a.map { norm($0, key: key) })
        }
    }

    static func cleanProcessData(_ pd: JSONObject) -> JSONObject {
        var pd = pd
        if case .object(let u)? = pd["usage"] {
            pd["usage"] = .object(JSONObject(u.filter { !volatileUsage.contains($0.key) }.map { ($0.key, $0.value) }))
        }
        return pd
    }

    /// `Builder` over the engine's events (as record_graphon.py's `normalize`).
    public struct Builder {
        public var trace: JSONObject
        var events: [JSONValue] = []
        var starts: [String: Int] = [:]
        var labels: [String: String] = [:]
        var lastLabel: [String: String] = [:]
        let graph: RuntimeGraph

        public init(case name: String, source: String, graph: RuntimeGraph) {
            self.graph = graph
            let edges: [JSONValue] = (graph.config.json["edges"]?.array ?? []).compactMap { e in
                guard let s = e["source"]?.string, let t = e["target"]?.string else { return nil }
                return .array([.string(s), .string(t)])
            }
            trace = ["schema": .string(RunTrace.schema), "case": .string(name), "source": .string(source), "edges": .array(edges)]
        }

        mutating func labelStart(_ nodeId: String, _ raw: String) -> String {
            let n = (starts[nodeId] ?? 0) + 1
            starts[nodeId] = n
            let label = "\(nodeId)#\(n)"
            labels[raw] = label
            lastLabel[nodeId] = label
            return label
        }

        func labelOf(_ nodeId: String, _ raw: String) -> String { labels[raw] ?? lastLabel[nodeId] ?? "\(nodeId)#?" }

        mutating func add(_ ev: JSONObject) {
            if ev["event"] == "text_chunk" {
                if (ev["text"]?.string ?? "").isEmpty { return }
                if case .object(var last)? = events.last, last["event"] == "text_chunk", last["selector"] == ev["selector"] {
                    last["text"] = .string((last["text"]?.string ?? "") + (ev["text"]?.string ?? ""))
                    events[events.count - 1] = .object(last)
                    return
                }
            }
            events.append(.object(ev))
        }

        func nodeType(_ id: String) -> String { graph.nodes[id]?.nodeType ?? "" }

        mutating func nodeFinished(_ x: String, _ nodeId: String, _ status: String, _ r: NodeRunResult, error: String?) {
            var ev: JSONObject = [
            "event": "node_finished", "exec": .string(labelOf(nodeId, x)), "node_id": .string(nodeId), "node_type": .string(nodeType(nodeId)),
            "status": .string(status), "inputs": norm(.object(r.inputs)), "process_data": norm(.object(cleanProcessData(r.processData))),
            "outputs": norm(.object(r.outputs)), "error": error.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null,
        ]
        if let c = NodeScope(metadata: r.metadata).containerId { ev["in"] = .string(c) }
        add(ev)
        }

        public mutating func add(_ event: GraphEngineEvent) {
            switch event {
            case .runStarted: add(["event": "workflow_started"])
            case .node(let e):
                switch e {
                case .started(let x, let nodeId, let type, _, _, let scope):
                    var ev: JSONObject = ["event": "node_started", "exec": .string(labelStart(nodeId, x)), "node_id": .string(nodeId),
                                          "node_type": .string(type)]
                    if let c = scope.containerId { ev["in"] = .string(c) }
                    add(ev)
                case .streamChunk(_, _, let selector, let chunk, _):
                    add(["event": "text_chunk", "selector": .array(selector.map(JSONValue.string)), "text": .string(chunk)])
                case .retry(_, let nodeId, _, _, let error, let index):
                    add(["event": "node_retry", "node_id": .string(nodeId), "retry_index": .int(index), "error": .string(error)])
                case .succeeded(let x, let nodeId, _, _, let r): nodeFinished(x, nodeId, "succeeded", r, error: r.error)
                case .failed(let x, let nodeId, _, _, let r, let error): nodeFinished(x, nodeId, "failed", r, error: error.isEmpty ? r.error : error)
                case .exception(let x, let nodeId, _, _, let r, let error): nodeFinished(x, nodeId, "exception", r, error: error.isEmpty ? r.error : error)
                case .containerStarted(_, let nodeId, let kind, _, let inputs, _):
                    add(["event": .string("\(kind.rawValue)_started"), "node_id": .string(nodeId), "inputs": norm(.object(inputs))])
                case .containerNext(_, let nodeId, let kind, let index, _):
                    add(["event": .string("\(kind.rawValue)_next"), "node_id": .string(nodeId), "index": .int(index)])
                case .containerCompleted(_, let nodeId, let kind, _, _, let outputs, _, let steps, let error):
                    add(["event": .string("\(kind.rawValue)_completed"), "node_id": .string(nodeId), "status": .string(error == nil ? "succeeded" : "failed"),
                         "outputs": norm(.object(outputs)), "error": error.map(JSONValue.string) ?? .null, "steps": .int(steps)])
                case .variableUpdated(_, let nodeId, let selector, let value):
                    add(["event": "variable_updated", "node_id": .string(nodeId), "selector": .array(selector.map(JSONValue.string)),
                         "value": norm(value.value)])
                case .reasoningChunk, .retrieverResource: break
                }
            case .edgeTaken, .edgeSkipped: break
            case .runSucceeded(let s):
                add(["event": "workflow_finished", "status": "succeeded", "outputs": norm(.object(s.outputs)), "error": .null, "exceptions_count": 0])
            case .runPartialSucceeded(let s):
                add(["event": "workflow_finished", "status": "partial-succeeded", "outputs": norm(.object(s.outputs)), "error": .null,
                     "exceptions_count": .int(s.exceptionsCount)])
            case .runFailed(let error, let s):
                add(["event": "workflow_finished", "status": "failed", "outputs": [:], "error": .string(error),
                     "exceptions_count": .int(s.exceptionsCount)])
            case .runAborted(let reason, let s):
                add(["event": "workflow_finished", "status": "stopped", "outputs": norm(.object(s.outputs)), "error": .string(reason),
                     "exceptions_count": 0])
            }
        }

        public var result: JSONValue {
            var t = trace
            t["events"] = .array(events)
            return .object(t)
        }
    }

    // MARK: - Comparison (runtrace.compare)

    public struct Difference: CustomStringConvertible, Sendable {
        public var path: String
        public var a: JSONValue
        public var b: JSONValue
        public var description: String { "\(path):\n    a: \(a.compactJSON().prefix(300))\n    b: \(b.compactJSON().prefix(300))" }
    }

    static func deepDiff(_ a: JSONValue?, _ b: JSONValue?, _ path: String, _ out: inout [Difference]) {
        switch (a, b) {
        case (.object(let x)?, .object(let y)?):
            for k in Set(x.keys).union(y.keys).sorted() {
                let p = "\(path).\(k)"
                if x[k] == nil { out.append(Difference(path: p, a: "<absent>", b: y[k]!)) }
                else if y[k] == nil { out.append(Difference(path: p, a: x[k]!, b: "<absent>")) }
                else { deepDiff(x[k], y[k], p, &out) }
            }
        case (.array(let x)?, .array(let y)?) where x.count == y.count:
            for i in x.indices { deepDiff(x[i], y[i], "\(path)[\(i)]", &out) }
        default:
            if a != b { out.append(Difference(path: path, a: a ?? .null, b: b ?? .null)) }
        }
    }

    struct Execution {
        var nodeId: String
        var fields: JSONObject = [:]
        var start: Int?
        var end: Int?
        /// The container it ran in (`in` of its started event).
        var container: String?
    }

    static func executions(_ trace: JSONValue) -> ([String: Execution], [String]) {
        var ex: [String: Execution] = [:], order: [String] = []
        for (i, ev) in (trace["events"]?.array ?? []).enumerated() {
            guard let label = ev["exec"]?.string, let node = ev["node_id"]?.string else { continue }
            if ev["event"] == "node_started" {
                var e = ex[label] ?? Execution(nodeId: node)
                e.fields["node_type"] = ev["node_type"] ?? .null
                e.start = i
                if let c = ev["in"]?.string { e.container = c }
                ex[label] = e
                order.append(label)
            } else if ev["event"] == "node_finished" {
                var e = ex[label] ?? Execution(nodeId: node)
                if e.fields["node_type"] == nil { e.fields["node_type"] = ev["node_type"] ?? .null }
                e.end = i
                for k in ["status", "inputs", "process_data", "outputs", "error"] { e.fields[k] = ev[k] ?? .null }
                ex[label] = e
            }
        }
        return (ex, order)
    }

    static func streams(_ trace: JSONValue) -> (JSONObject, String) {
        var per = JSONObject(), total = ""
        for ev in trace["events"]?.array ?? [] where ev["event"] == "text_chunk" {
            let sel = (ev["selector"]?.array ?? []).compactMap(\.string).joined(separator: "/")
            let key = sel.isEmpty ? "-" : sel
            let text = ev["text"]?.string ?? ""
            per[key] = .string((per[key]?.string ?? "") + text)
            total += text
        }
        return (per, total)
    }

    static func final(_ trace: JSONValue) -> JSONValue {
        for ev in (trace["events"]?.array ?? []).reversed() where ev["event"] == "workflow_finished" || ev["event"] == "workflow_paused" {
            var o = JSONObject()
            for k in ["event", "status", "outputs", "error", "exceptions_count"] { o[k] = ev[k] ?? .null }
            return .object(o)
        }
        return .null
    }

    static let containerEvents: Set<String> = ["iteration_started", "iteration_next", "iteration_completed", "loop_started", "loop_next",
                                               "loop_completed"]

    /// `_containers`: per container node, its iteration / loop events in order (without `node_id`).
    static func containers(_ trace: JSONValue) -> JSONObject {
        var out = JSONObject()
        for ev in trace["events"]?.array ?? [] {
            guard let name = ev["event"]?.string, containerEvents.contains(name), case .object(let o) = ev else { continue }
            let node = o["node_id"]?.string ?? "null"
            var item = JSONObject()
            for (k, v) in o where k != "node_id" { item[k] = v }
            out[node] = .array((out[node]?.array ?? []) + [.object(item)])
        }
        return out
    }

    /// `_unordered`: the executions inside `containers` as sorted lists per node.
    static func unordered(_ ex: [String: Execution], _ containers: Set<String>) -> JSONObject {
        var out: [String: [JSONValue]] = [:]
        for e in ex.values where e.container.map(containers.contains) == true {
            var f = JSONObject()
            for k in ["node_type", "status", "inputs", "process_data", "outputs", "error"] { f[k] = e.fields[k] ?? .null }
            out[e.nodeId, default: []].append(.object(f))
        }
        return JSONObject(out.keys.sorted().map { k in (k, .array(out[k]!.sorted { $0.compactJSON() < $1.compactJSON() })) })
    }

    /// `compare(a, b, unordered=...)`: empty = equivalent.
    public static func compare(_ a: JSONValue, _ b: JSONValue, unordered containerIds: Set<String> = []) -> [Difference] {
        var diffs: [Difference] = []
        deepDiff(final(a), final(b), "run", &diffs)
        var (ea, oa) = executions(a), (eb, _) = executions(b)
        if !containerIds.isEmpty {
            deepDiff(.object(unordered(ea, containerIds)), .object(unordered(eb, containerIds)), "unordered", &diffs)
            ea = ea.filter { $0.value.container.map(containerIds.contains) != true }
            eb = eb.filter { $0.value.container.map(containerIds.contains) != true }
            oa = oa.filter { ea[$0] != nil }
        }
        deepDiff(.object(containers(a)), .object(containers(b)), "container", &diffs)
        for label in Set(ea.keys).union(eb.keys).sorted() {
            guard let x = ea[label] else { diffs.append(Difference(path: "exec[\(label)]", a: "<not executed>", b: eb[label]!.fields["status"] ?? .null)); continue }
            guard let y = eb[label] else { diffs.append(Difference(path: "exec[\(label)]", a: x.fields["status"] ?? .null, b: "<not executed>")); continue }
            for k in ["node_type", "status", "inputs", "process_data", "outputs", "error"] {
                deepDiff(x.fields[k] ?? .null, y.fields[k] ?? .null, "exec[\(label)].\(k)", &diffs)
            }
        }
        let (sa, ta) = streams(a), (sb, tb) = streams(b)
        deepDiff(.object(sa), .object(sb), "stream", &diffs)
        if ta != tb { diffs.append(Difference(path: "stream.*", a: .string(ta), b: .string(tb))) }
        // order: for X, Y with X's node a graph ancestor of Y's, "X finished before Y started" must agree.
        var succ: [String: Set<String>] = [:]
        for e in (a["edges"]?.array ?? b["edges"]?.array ?? []) {
            if let s = e.array?.first?.string, let t = e.array?.last?.string { succ[s, default: []].insert(t) }
        }
        var reach: [String: Set<String>] = [:]
        for n in succ.keys {
            var seen = Set<String>(), stack = Array(succ[n] ?? [])
            while let x = stack.popLast() {
                if seen.insert(x).inserted { stack += succ[x] ?? [] }
            }
            reach[n] = seen
        }
        let common = oa.filter { eb[$0] != nil }
        for x in common {
            for y in common where x != y {
                guard let nx = ea[x]?.nodeId, let ny = ea[y]?.nodeId, reach[nx]?.contains(ny) == true else { continue }
                let beforeA = (ea[x]?.end ?? Int.max) < (ea[y]?.start ?? -1)
                let beforeB = (eb[x]?.end ?? Int.max) < (eb[y]?.start ?? -1)
                if beforeA != beforeB { diffs.append(Difference(path: "order[\(x) -> \(y)]", a: .bool(beforeA), b: .bool(beforeB))) }
            }
        }
        return diffs
    }
}
