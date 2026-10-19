// Golden-trace replay: each golden of server/Tests/CollabTests/Fixtures/graphon-traces names its fixture, inputs, query
// and mock outputs (`meta`); the same graph runs on the Swift engine as Dify's table runner builds it
// (api/tests/unit_tests/core/workflow/graph_engine/test_table_runner.py `create_graph_from_fixture`) and the
// normalized traces are compared.

import CollabRuntime
import Foundation
import Yams

public enum Replay {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// YAML -> JSON with mapping order kept (Python's `yaml.safe_load` into dicts).
    public static func json(yaml: String) throws -> JSONValue {
        guard let node = try Yams.compose(yaml: yaml) else { throw Failure("empty YAML") }
        return try json(node)
    }

    static func json(_ node: Yams.Node) throws -> JSONValue {
        switch node {
        case .scalar(let s):
            switch Resolver.default.resolveTag(of: node) {
            case Tag.Name.null: return .null
            case Tag.Name.bool: return .bool(Bool.construct(from: s) ?? false)
            case Tag.Name.int: if let i = Int.construct(from: s) { return .int(i) }; return .string(s.string)
            case Tag.Name.float: if let d = Double.construct(from: s) { return .double(d) }; return .string(s.string)
            default: return .string(s.string)
            }
        case .sequence(let seq): return .array(try seq.map(json))
        case .mapping(let map):
            var o = JSONObject()
            for (k, v) in map {
                guard case .scalar(let ks) = k else { throw Failure("non-scalar map key") }
                o[ks.string] = try json(v)
            }
            return .object(o)
        case .alias: throw Failure("YAML aliases are not supported")
        }
    }

    public enum Outcome: String, Sendable { case pass = "PASS", diff = "DIFF", skip = "SKIP", error = "ERROR" }

    public struct Result: Sendable {
        public var name: String
        public var outcome: Outcome
        public var note: String
        public var differences: [RunTrace.Difference]
        /// Node types the case ran with the runtime's own nodes / with Dify's mocks.
        public var realTypes: [String]
        public var mockedTypes: [String]
        public var trace: JSONValue?
    }

    /// Node types not run yet by the engine.
    public static let unsupportedTypes: Set<String> = []

    /// Replays one golden (`dify-sf-trace/1` with `meta`) against `fixturesDir`.
    public static func replay(golden: JSONValue, fixturesDir: URL, maxWorkers: Int = 1) async -> Result {
        let name = golden["case"]?.string ?? "?"
        guard let meta = golden["meta"], let fixture = meta["fixture"]?.string else {
            return Result(name: name, outcome: .error, note: "golden without meta", differences: [], realTypes: [], mockedTypes: [], trace: nil)
        }
        do {
            let text = try String(contentsOf: fixturesDir.appendingPathComponent(fixture), encoding: .utf8)
            let dsl = try json(yaml: text)
            let workflow = dsl["workflow"] ?? .null
            let config = try GraphConfig(json: workflow["graph"] ?? .null)
            let types = Set(config.nodes.map(\.type))
            let real = types.subtracting(MockNodeFactory.mockedTypes).sorted()
            let mocked = types.intersection(MockNodeFactory.mockedTypes).sorted()
            if let blocked = types.intersection(unsupportedTypes).sorted().first {
                return Result(name: name, outcome: .skip, note: "\(blocked) node (not supported yet)", differences: [], realTypes: real,
                              mockedTypes: mocked, trace: nil)
            }
            var outputs: [String: JSONObject] = [:]
            for (k, v) in meta["mock"]?.object ?? [:] { outputs[k] = v.object ?? [:] }
            let factory = MockNodeFactory(outputs: outputs)
            let query = meta["query"]?.string ?? ""
            var inputs = meta["inputs"]?.object ?? [:]
            if inputs["query"] == nil { inputs["query"] = .string(query) }
            let trace = try await run(config: config, workflow: workflow, factory: factory, query: query, inputs: inputs, name: name,
                                      maxWorkers: maxWorkers)
            let diffs = RunTrace.compare(golden, trace)
            return Result(name: name, outcome: diffs.isEmpty ? .pass : .diff, note: "", differences: diffs, realTypes: real, mockedTypes: mocked,
                          trace: trace)
        } catch {
            return Result(name: name, outcome: .error, note: "\(error)", differences: [], realTypes: [], mockedTypes: [], trace: nil)
        }
    }

    /// `create_graph_from_fixture` + `GraphEngine.run`: the trace of one run.
    public static func run(config: GraphConfig, workflow: JSONValue, factory: any NodeFactory, query: String, inputs: JSONObject, name: String,
                           maxWorkers: Int) async throws -> JSONValue {
        let rootId = try RuntimeGraph.defaultRootId(config)
        let graph = try await RuntimeGraph.build(config, rootId: rootId, factory: factory)
        let system = WorkflowBootstrap.systemVariables([("user_id", "test_user"), ("app_id", "test_app"), ("workflow_id", "test_workflow"),
                                                        ("files", .array([])), ("query", .string(query))])
        // The table runner's conversation variables: number -> FloatVariable, integer -> IntegerVariable, else by type.
        var conversation: [(name: String, segment: Segment)] = []
        for v in workflow["conversation_variables"]?.array ?? [] {
            let name = v["name"]?.string ?? ""
            let value = v["value"] ?? .string("")
            let segment: Segment
            switch v["value_type"]?.string ?? "string" {
            case "number": segment = Segment(.float, .double(value.double ?? 0))
            case "integer": segment = Segment(.integer, .int(value.int ?? 0))
            case "object": segment = Segment(.object, value)
            case "array[string]": segment = Segment(.arrayString, value)
            case "array[number]": segment = Segment(.arrayNumber, value)
            case "array[object]": segment = Segment(.arrayObject, value)
            default: segment = Segment(.string, value)
            }
            conversation.append((name, segment))
        }
        let pool = try WorkflowBootstrap.pool(system: system, environment: [], conversation: conversation, rootId: rootId, inputs: inputs)
        let engine = GraphEngine(graph: graph, config: GraphEngineConfig(maxWorkers: maxWorkers))
        var builder = RunTrace.Builder(case: name, source: "dify-sf-replay", graph: graph)
        for await event in engine.run(pool: pool) { builder.add(event) }
        return builder.result
    }

    /// Every golden in `tracesDir` (sorted by name).
    public static func replayAll(tracesDir: URL, fixturesDir: URL, maxWorkers: Int = 1) async throws -> [Result] {
        let files = try FileManager.default.contentsOfDirectory(atPath: tracesDir.path).filter { $0.hasSuffix(".json") }.sorted()
        var results: [Result] = []
        for f in files {
            let golden = try JSONValue.parse(Data(contentsOf: tracesDir.appendingPathComponent(f)))
            results.append(await replay(golden: golden, fixturesDir: fixturesDir, maxWorkers: maxWorkers))
        }
        return results
    }

    /// The PASS/DIFF/SKIP table.
    public static func table(_ results: [Result]) -> String {
        var lines: [String] = []
        for r in results {
            var line = "\(r.outcome.rawValue)  \(r.name)"
            if !r.note.isEmpty { line += "  (\(r.note))" }
            if !r.mockedTypes.isEmpty { line += "  mocked: \(r.mockedTypes.joined(separator: ","))" }
            lines.append(line)
            for d in r.differences.prefix(12) { lines.append("  \(d)") }
        }
        let count = { (o: Outcome) in results.filter { $0.outcome == o }.count }
        lines.append("total \(results.count): \(count(.pass)) pass, \(count(.diff)) diff, \(count(.skip)) skip, \(count(.error)) error")
        return lines.joined(separator: "\n")
    }
}
