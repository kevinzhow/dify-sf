import Testing
import Foundation
import Yams
@testable import CollabCore
@testable import CollabDSL

/// Dify's own 24 sample workflows (Fixtures/dify, Apache-2.0, see NOTICE.md).
private let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dify")
private let fixtures: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: fixtureDir.path)) ?? [])
    .filter { $0.hasSuffix(".yml") }.sorted()

private func load(_ name: String) throws -> String { try String(contentsOf: fixtureDir.appendingPathComponent(name), encoding: .utf8) }
private func parse(_ yaml: String) throws -> Value { try DifyDSL.value(of: Yams.compose(yaml: yaml)!) }

/// What a round trip must preserve: everything except UI selection, with nodes and edges compared by id.
private func normalized(_ v: Value) -> Value {
    switch v {
    case .map(var m):
        m["selected"] = nil
        for k in ["nodes", "edges"] {
            if case .list(let xs)? = m[k], xs.allSatisfy({ if case .map(let e) = $0, case .string? = e["id"] { return true }; return false }) {
                m[k] = .list(xs.sorted { a, b in
                    guard case .map(let x) = a, case .map(let y) = b, case .string(let i)? = x["id"], case .string(let j)? = y["id"] else { return false }
                    return i < j
                })
            }
        }
        return .map(m.mapValues(normalized))
    case .list(let xs): return .list(xs.map(normalized))
    default: return v
    }
}

private func firstDifference(_ a: Value, _ b: Value, _ path: String = "") -> String? {
    switch (a, b) {
    case (.map(let x), .map(let y)):
        for k in Set(x.keys).union(y.keys).sorted() {
            guard let xv = x[k] else { return "\(path).\(k): missing in original" }
            guard let yv = y[k] else { return "\(path).\(k): missing after round trip" }
            if let d = firstDifference(xv, yv, "\(path).\(k)") { return d }
        }
        return nil
    case (.list(let x), .list(let y)):
        if x.count != y.count { return "\(path): \(x.count) vs \(y.count) elements" }
        for i in x.indices { if let d = firstDifference(x[i], y[i], "\(path)[\(i)]") { return d } }
        return nil
    default: return a == b ? nil : "\(path): \(a) vs \(b)"
    }
}

@Suite("Dify DSL import/export")
struct DSLTests {
    @Test func all24SamplesArePresent() { #expect(fixtures.count == 24) }

    @Test(arguments: fixtures)
    func roundTripIsLossless(_ name: String) throws {
        let yaml = try load(name)
        let imported = try DifyDSL.importYAML(yaml)
        #expect(imported.document.integrityProblems.isEmpty)
        let exported = try DifyDSL.exportYAML(imported.document, metadata: imported.metadata)
        let diff = firstDifference(normalized(try parse(yaml)), normalized(try parse(exported)))
        #expect(diff == nil, "\(name): \(diff ?? "")")
        // and importing the export gives the same document
        let again = try DifyDSL.importYAML(exported)
        #expect(again.document == imported.document)
    }

    @Test func structureBecomesCollaborative() throws {
        let d = try DifyDSL.importYAML(try load("array_iteration_formatting_workflow.yml")).document
        // code outputs: keyed items carrying their name (references point at it)
        guard case .items(let outs)? = d.nodes["1754683442688"]?.config["outputs"] else { Issue.record("outputs"); return }
        #expect(outs.map(\.id) == ["result"])
        // template variables: keyed by variable, the selector is a checked reference to the iteration node
        guard case .items(let vars)? = d.nodes["1754683458843"]?.config["variables"],
              case .map(let v)? = vars.first?.value else { Issue.record("variables"); return }
        #expect(vars.map(\.id) == ["arg1"])
        #expect(v["value_selector"] == .ref(OutputRef(node: "1754683430480", output: "item")))
        // system variables are not nodes: they stay plain lists
        let chat = try DifyDSL.importYAML(try load("basic_chatflow.yml")).document
        #expect(chat.nodes.values.contains { $0.type == "llm" })
    }

    @Test func editsShowUpInTheExport() throws {
        var imp = try DifyDSL.importYAML(try load("array_iteration_formatting_workflow.yml"))
        let s = Stamp(seq: 1, client: "a")
        imp.document.apply(.setField("1754683442688", .title, .string("Make numbers")), at: s)
        imp.document.apply(.insertItem("1754683442688", path: ["outputs"], item: Item(id: "count", value: .map(["name": .string("count"), "type": .string("number"), "children": .null])), after: "result"), at: s)
        imp.document.apply(.moveNode("1754683442688", x: 400, y: 300), at: s)
        imp.document.apply(.setField("1754683442688", .config(["temperature_like"]), .double(0.7)), at: s)
        let out = try parse(DifyDSL.exportYAML(imp.document, metadata: imp.metadata))
        guard case .map(let top) = out, case .map(let wf)? = top["workflow"], case .map(let g)? = wf["graph"], case .list(let nodes)? = g["nodes"],
              let code = nodes.first(where: { if case .map(let n) = $0, n["id"] == .string("1754683442688") { return true }; return false }),
              case .map(let n) = code, case .map(let data)? = n["data"], case .map(let outputs)? = data["outputs"] else { Issue.record("export shape"); return }
        #expect(data["title"] == .string("Make numbers"))
        #expect(Set(outputs.keys) == ["result", "count"])
        #expect(n["position"] == .map(["x": .int(400), "y": .int(300)]))
        #expect(data["temperature_like"] == .double(0.7))
    }

    @Test func appMetaCarriesModeAndVariablesWithoutTheGraph() throws {
        let chat = DifyDSL.appMeta(try DifyDSL.importYAML(try load("test_streaming_conversation_variables.yml")).metadata)
        guard case .map(let m) = chat, case .map(let app)? = m["app"], case .list(let conv)? = m["conversation_variables"],
              case .map(let v)? = conv.first else { Issue.record("meta shape"); return }
        #expect(app["mode"] == .string("advanced-chat"))
        #expect(v["name"] == .string("str") && v["value"] == .string("default"))
        #expect(m["environment_variables"] == .list([]))
        guard case .map(let features)? = m["features"] else { Issue.record("features"); return }
        #expect(features["file_upload"] != nil)
        #expect(m["workflow"] == nil && m["_edges"] == nil && m["graph"] == nil)
        #expect(m["kind"] == .string("app") && m["version"] == .string("0.3.1") && m["dependencies"] == .list([]))
    }

    @Test func appMetaOfANonImportedDocumentIsTheExportDefault() {
        guard case .map(let m) = DifyDSL.appMeta(DifyDSL.defaultMetadata(name: "doc1")), case .map(let app)? = m["app"] else {
            Issue.record("meta shape"); return
        }
        #expect(app["mode"] == .string("workflow") && app["name"] == .string("doc1"))
        #expect(m["environment_variables"] == .list([]) && m["conversation_variables"] == .list([]) && m["features"] == .map([:]))
    }

    @Test func appMetaBlanksSecretEnvironmentValuesLikeDify() throws {
        let yaml = """
        app: {name: env, mode: workflow}
        kind: app
        version: 0.3.1
        workflow:
          environment_variables:
          - {id: e1, name: api_key, value: sk-not-for-clients, value_type: secret, description: ''}
          - {id: e2, name: region, value: eu, value_type: string, description: ''}
          conversation_variables: []
          features: {}
          graph:
            nodes:
            - id: s
              data: {type: start, title: Start, variables: []}
            edges: []
        """
        let imported = try DifyDSL.importYAML(yaml)
        guard case .map(let m) = DifyDSL.appMeta(imported.metadata), case .list(let env)? = m["environment_variables"],
              env.count == 2, case .map(let secret) = env[0], case .map(let plain) = env[1] else { Issue.record("meta shape"); return }
        #expect(secret["value"] == .string("") && secret["name"] == .string("api_key") && secret["value_type"] == .string("secret"))
        #expect(plain["value"] == .string("eu"))
        // the stored metadata (used by export) is unchanged
        #expect(try DifyDSL.exportYAML(imported.document, metadata: imported.metadata).contains("sk-not-for-clients"))
    }

    @Test func numbersHaveOneRepresentation() throws {
        #expect(Value.number(1.0) == .int(1))
        #expect(Value.number(0.7) == .double(0.7))
        #expect(Value.double(2.0).structuralProblem != nil)
        let data = try JSONEncoder().encode(Value.map(["t": .double(0.7), "n": .int(3)]))
        #expect(try JSONDecoder().decode(Value.self, from: data) == .map(["t": .double(0.7), "n": .int(3)]))
    }
}
