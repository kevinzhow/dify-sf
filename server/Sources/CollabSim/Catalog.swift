import CollabCore
import CollabInvariants
import Foundation

/// The conflict catalog (CATALOG.md, tier A) run against dify-sf in the deterministic simulator.
///
/// The cases are read from `bench/catalog/A-cases.json`, exported from the Dify simulator's generator, so both columns
/// of the scorecard run literally the same cases. Each case is mapped onto the same starting workflow
/// (`fixture()`, the catalog's code-node-basic graph) and the same operations expressed as dify-sf ops; timing T1 means
/// both users commit before either sees the other, T2 means B edits from a panel opened before A's commit.
///
/// Metrics per run, as in the catalog: M1 acknowledged edit lost (I1), M2 stale write silently overwrote a newer one
/// (I2), M3 replicas diverge (I3), M4 dangling reference (I4, plus output-level references, see `danglingOutputs`),
/// M5 an edit without any outcome (I5 / no terminal). A rejection with a reason is not a loss: the user is told.
public enum Catalog {
    public struct File: Decodable { public var cases: [Case] }
    public struct Case: Decodable {
        public var id: String
        public var title: String
        public var steps: [Step]
        public var expect: Expect
        public var `repeat`: Int
    }
    public struct Expect: Decodable { public var final: [Contains]? }
    public struct Contains: Decodable { public var node: String; public var path: String; public var contains: [String] }
    public struct Step: Decodable {
        public var at: Int
        public var user: String
        public var op: String
        public var node: String?
        public var path: String?
        public var value: JSON?
        public var from: String?
        public var to: String?
        public var open_at: Int?
    }

    /// Just enough JSON to read step values (strings, numbers, [a, b] selectors, {x, y} / {kind, x, y} objects).
    public indirect enum JSON: Decodable {
        case string(String), number(Double), array([JSON]), object([String: JSON]), null
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else if let a = try? c.decode([JSON].self) { self = .array(a) }
            else { self = .object(try c.decode([String: JSON].self)) }
        }
        var text: String? { if case .string(let s) = self { return s }; if case .number(let d) = self { return String(d) }; return nil }
        var double: Double? { if case .number(let d) = self { return d }; return nil }
        subscript(_ k: String) -> JSON? { if case .object(let o) = self { return o[k] }; return nil }
        subscript(_ i: Int) -> JSON? { if case .array(let a) = self, a.indices.contains(i) { return a[i] }; return nil }
    }

    // MARK: - The starting workflow (catalog fixture code-node-basic)

    static func items(_ xs: [(String, Value)]) -> Value { .items(xs.map { Item(id: $0.0, value: $0.1) }) }
    static func ref(_ n: String, _ o: String) -> Value { .ref(OutputRef(node: n, output: o)) }
    static func edge(_ a: String, _ b: String) -> Edge { Edge(id: "\(a)->\(b)", source: a, target: b) }

    public static func fixture() -> Document {
        let output = Value.map(["type": .string("string")])
        let nodes = [
            Node(id: "start", type: "start", title: "Start", x: 80, y: 200,
                 config: ["desc": .string(""), "variables": items([("q", .string("text-input"))])]),
            Node(id: "code1", type: "code", title: "Code 1", x: 400, y: 360,
                 config: ["desc": .string(""), "code": .string("def main(a: str) -> dict:\n    return {'result': a}\n"),
                          "variables": items([("a", ref("start", "q")), ("b", ref("start", "q"))]),
                          "outputs": items([("result", output), ("extra", output)])]),
            Node(id: "llm1", type: "llm", title: "LLM 1", x: 720, y: 200,
                 config: ["desc": .string("ask"),
                          "model": .map(["provider": .string("openai"), "name": .string("gpt-4o"),
                                         "completion_params": .map(["temperature": .string("0.7")])]),
                          "prompt": items([("p0", .string("You are helpful.")), ("p1", .string("{{#code1.result#}}"))])]),
            Node(id: "ifelse1", type: "if-else", title: "Branch", x: 1040, y: 200,
                 config: ["desc": .string(""), "cond": .string("yes"), "cond_var": ref("llm1", "text")]),
            Node(id: "code2", type: "code", title: "Code 2", x: 1360, y: 120,
                 config: ["desc": .string(""), "variables": items([("a", ref("llm1", "text"))]), "outputs": items([("result", output)])]),
            Node(id: "code3", type: "code", title: "Code 3", x: 1360, y: 320,
                 config: ["desc": .string(""), "variables": items([("a", ref("llm1", "text"))]), "outputs": items([("result", output)])]),
            Node(id: "end", type: "end", title: "End", x: 1680, y: 200,
                 config: ["desc": .string(""), "outputs": items([("out", ref("code2", "result"))])]),
        ]
        let edges = [edge("start", "code1"), edge("code1", "llm1"), edge("llm1", "ifelse1"),
                     edge("ifelse1", "code2"), edge("ifelse1", "code3"), edge("code2", "end")]
        return Document(nodes: nodes, edges: edges)
    }

    // MARK: - Catalog operations as dify-sf ops

    struct Unsupported: Error, CustomStringConvertible { var description: String }

    /// The ops one catalog step sends. A model change replaces the whole `model` object (provider, name, fresh
    /// parameters), so it overlaps `model.completion_params.temperature` - the catalog's R3 "overlapping paths".
    static func ops(_ s: Step) throws -> [Op] {
        let n = s.node ?? ""
        func str() throws -> String { guard let v = s.value?.text else { throw Unsupported(description: "\(s.op): no value") }; return v }
        switch s.op {
        case "setTitle": return [.setField(n, .title, .string(try str()))]
        case "setField":
            switch s.path {
            case "temp": return [.setField(n, .config(["model", "completion_params", "temperature"]), .string(try str()))]
            case "model": return [.setField(n, .config(["model"]), .map(["provider": .string("openai"), "name": .string(try str()), "completion_params": .map([:])]))]
            case "prompt0": return [.updateItem(n, path: ["prompt"], id: "p0", value: .string(try str()))]
            case "code", "desc", "cond": return [.setField(n, .config([s.path!]), .string(try str()))]
            default: throw Unsupported(description: "setField path \(s.path ?? "nil")")
            }
        case "moveNode":
            guard let x = s.value?["x"]?.double, let y = s.value?["y"]?.double else { throw Unsupported(description: "moveNode value") }
            return [.moveNode(n, x: Int(x), y: Int(y))]
        case "setRef":
            guard let a = s.value?[0]?.text, let b = s.value?[1]?.text else { throw Unsupported(description: "setRef value") }
            return [.updateItem(n, path: ["variables"], id: "a", value: ref(a, b))]
        case "listInsert":
            let id = try str()
            let v: Value = switch s.path {
            case "outputs": .map(["type": .string("string")])
            case "variables": ref("start", "q")
            default: .string(id)
            }
            return [.insertItem(n, path: [s.path!], item: Item(id: id, value: v), after: nil)]
        case "listRemove": return [.removeItem(n, path: [s.path!], id: try str())]
        case "addNode":
            let kind = s.value?["kind"]?.text ?? "code"
            let x = Int(s.value?["x"]?.double ?? 0), y = Int(s.value?["y"]?.double ?? 0)
            let node = kind == "code"
                ? Node(id: n, type: "code", title: "New Code", x: x, y: y,
                       config: ["code": .string("def main() -> dict:\n    return {}\n"), "variables": items([]), "outputs": items([("result", .map(["type": .string("string")]))])])
                : Node(id: n, type: "template-transform", title: "New Template", x: x, y: y, config: ["template": .string(""), "variables": items([])])
            return [.addNode(node)] + (s.from.map { [.addEdge(edge($0, n))] } ?? [])
        case "removeNode": return [.removeNode(n)]
        case "addEdge": return [.addEdge(edge(s.from!, s.to!))]
        case "removeEdge": return [.removeEdge("\(s.from!)->\(s.to!)")]
        default: throw Unsupported(description: "op \(s.op)")
        }
    }

    // MARK: - Running

    public struct RunOutcome: Sendable {
        public var metrics: [String: Bool]          // M1...M5
        public var expectOK: Bool
        public var outcomes: [String]               // per user op: committed / rejected(reason)
        public var violations: [String]
    }

    /// References to an output that no longer exists on a live node (the catalog's M4 counts these too; dify-sf's
    /// integrity check only covers whole nodes).
    public static func danglingOutputs(_ d: Document) -> [String] {
        var out: [String] = []
        for (id, node) in d.nodes.sorted(by: { $0.key < $1.key }) {
            for (key, v) in node.config.sorted(by: { $0.key < $1.key }) {
                for r in v.liveRefs {
                    guard let target = d.nodes[r.node] else { continue }  // node-level dangling is I4
                    if case .items(let outs)? = target.config["outputs"], target.type == "code", !outs.contains(where: { $0.id == r.output }) {
                        out.append("\(id).\(key) -> \(r.node).\(r.output) (output removed)")
                    }
                }
            }
        }
        return out
    }

    /// Runs one case once. `seed` varies the network's delays and reordering.
    public static func run(_ c: Case, seed: UInt64) throws -> RunOutcome {
        var cfg = SimConfig()
        cfg.clientCount = 2
        cfg.volatileFraction = 0
        cfg.maxDelay = 3
        cfg.dropRate = 0
        var w = World(seed: seed, cfg: cfg, initial: fixture())
        w.drain()
        let users = Array(Set(c.steps.map(\.user))).sorted()
        func slot(_ u: String) -> Int { users.firstIndex(of: u)! }
        var issued: [(user: String, cseq: Int)] = []
        var localRefused: [String] = []
        var silentRefusal = false
        var lastAt: Int?
        // the version each user's panel shows when it was opened (T2: B opened before A's commit)
        var openedBase: [String: Int] = [:]
        for s in c.steps where s.open_at != nil { openedBase[s.user] = w.slots[slot(s.user)].client!.lastSeq }
        for s in c.steps.sorted(by: { $0.at < $1.at }) {
            if let l = lastAt, s.at - l >= 200 { w.drain() }  // far enough apart: the first edit reached everyone
            lastAt = s.at
            let i = slot(s.user)
            for op in try ops(s) {
                let before = w.rec.localRefusals.count
                if let cseq = w.userEdit(i, op, base: openedBase[s.user]) { issued.append((s.user, cseq)) }
                else if w.rec.localRefusals.count > before { localRefused.append("\(s.user):refusedLocally(\(w.rec.localRefusals.last!.1))") }
                else { localRefused.append("\(s.user):refusedLocally(?)"); silentRefusal = true }
            }
        }
        let settled = w.settle()
        var violations = Fuzz.check(w)
        if !settled { violations.insert("CONVERGENCE: did not settle", at: 0) }
        let doc = w.evidence()?.serverDoc ?? Document()
        let outputRefs = danglingOutputs(doc)
        func has(_ p: String) -> Bool { violations.contains { $0.hasPrefix(p) } }
        var outcomes: [String] = []
        var noTerminal = false
        for (u, cseq) in issued {
            let t = w.terminals(w.slots[slot(u)].id, cseq)
            switch t.first {
            case .committed?: outcomes.append("\(u):committed")
            case .rejected(let r)?: outcomes.append("\(u):rejected(\(r.name))")
            case .lost?: outcomes.append("\(u):lost")
            case nil: outcomes.append("\(u):none"); noTerminal = true
            }
        }
        outcomes += localRefused
        if silentRefusal { noTerminal = true }
        var expectOK = true
        for e in c.expect.final ?? [] {
            guard case .items(let xs)? = doc.nodes[e.node]?.config[e.path] else { expectOK = false; continue }
            if !e.contains.allSatisfy({ id in xs.contains { $0.id == id } }) { expectOK = false }
        }
        let metrics = ["M1": has("I1"), "M2": has("I2"), "M3": has("I3") || has("CONVERGENCE"),
                       "M4": has("I4") || !outputRefs.isEmpty, "M5": has("I5") || noTerminal]
        return RunOutcome(metrics: metrics, expectOK: expectOK, outcomes: outcomes, violations: violations + outputRefs.map { "M4-output: \($0)" })
    }

    public struct CaseResult: Sendable {
        public var id: String
        public var title: String
        public var runs: Int
        public var counts: [String: Int]
        public var expectFailures: Int
        public var outcomes: [String: Int]  // distinct outcome patterns -> count
        public var sample: [String]
    }

    public static func runAll(_ cases: [Case], runs: Int) -> [CaseResult] {
        cases.map { c in
            var r = CaseResult(id: c.id, title: c.title, runs: 0, counts: ["M1": 0, "M2": 0, "M3": 0, "M4": 0, "M5": 0], expectFailures: 0, outcomes: [:], sample: [])
            for s in 1...max(1, runs) {
                do {
                    let o = try run(c, seed: UInt64(s))
                    r.runs += 1
                    for (k, v) in o.metrics where v { r.counts[k, default: 0] += 1 }
                    if !o.expectOK { r.expectFailures += 1 }
                    r.outcomes[o.outcomes.joined(separator: " "), default: 0] += 1
                    if r.sample.isEmpty, !o.violations.isEmpty { r.sample = Array(o.violations.prefix(3)) }
                } catch {
                    r.sample = ["NOT RUN: \(error)"]
                    break
                }
            }
            return r
        }
    }
}
