import Testing
import Foundation
import Yams
@testable import CollabCore
@testable import CollabDSL

/// Dify's own 24 sample workflows (Fixtures/dify, Apache-2.0, see NOTICE.md).
let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dify")
let fixtures: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: fixtureDir.path)) ?? [])
    .filter { $0.hasSuffix(".yml") }.sorted()

func load(_ name: String) throws -> String { try String(contentsOf: fixtureDir.appendingPathComponent(name), encoding: .utf8) }
func parse(_ yaml: String) throws -> Value { try DifyDSL.value(of: Yams.compose(yaml: yaml)!) }

/// What a round trip must preserve: everything except UI selection, with nodes and edges compared by id.
func normalized(_ v: Value) -> Value {
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

func firstDifference(_ a: Value, _ b: Value, _ path: String = "") -> String? {
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
        let imported = try DifyDSL.importYAML(try load("test_streaming_conversation_variables.yml"))
        let chat = DifyDSL.appMeta(imported.metadata, document: imported.document)
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
        guard case .map(let m) = DifyDSL.appMeta(DifyDSL.defaultMetadata(name: "doc1"), document: Document()),
              case .map(let app)? = m["app"] else { Issue.record("meta shape"); return }
        #expect(app["mode"] == .string("workflow") && app["name"] == .string("doc1"))
        #expect(m["environment_variables"] == .list([]) && m["conversation_variables"] == .list([]) && m["features"] == .map([:]))
    }

    // MARK: protocol 1.7: variables and features live in the document

    @Test func variablesAndFeaturesMoveIntoTheDocument() throws {
        let imported = try DifyDSL.importYAML(try load("test_streaming_conversation_variables.yml"))
        let d = imported.document
        guard case .items(let conv)? = d.app["conversation_variables"], case .map(let v)? = conv.first?.value else {
            Issue.record("conversation variables"); return
        }
        #expect(conv.map(\.id) == ["e208ec58-4503-48a9-baf8-17aae67e5fa0"])
        #expect(v["selector"] == .list([.string("conversation"), .string("str")]))  // selectors stay plain lists
        #expect(d.app["environment_variables"] == .items([]))
        guard case .map(let features)? = d.app["features"] else { Issue.record("features"); return }
        #expect(features["file_upload"] != nil)
        guard case .map(let top) = imported.metadata, case .map(let wf)? = top["workflow"] else { Issue.record("metadata"); return }
        #expect(wf["conversation_variables"] == nil && wf["environment_variables"] == nil && wf["features"] == nil)
        #expect(imported.secrets.isEmpty)
    }

    @Test func variableEditsShowUpInTheExportAndMeta() throws {
        var imp = try DifyDSL.importYAML(try load("test_streaming_conversation_variables.yml"))
        let s = Stamp(seq: 1, client: "a")
        let app = Document.appNode
        let env: Value = .map(["id": .string("e1"), "name": .string("region"), "value": .string("eu"), "value_type": .string("string"),
                               "description": .string("")])
        imp.document.apply(.insertItem(app, path: ["environment_variables"], item: Item(id: "e1", value: env), after: nil), at: s)
        imp.document.apply(.removeItem(app, path: ["conversation_variables"], id: "e208ec58-4503-48a9-baf8-17aae67e5fa0"), at: s)
        imp.document.apply(.setField(app, .config(["features", "opening_statement"]), .string("Hello")), at: s)
        guard case .map(let top) = try DifyDSL.exportValue(imp.document, metadata: imp.metadata), case .map(let wf)? = top["workflow"],
              case .map(let features)? = wf["features"] else { Issue.record("export shape"); return }
        #expect(wf["environment_variables"] == .list([env]) && wf["conversation_variables"] == .list([]))
        #expect(features["opening_statement"] == .string("Hello"))
        guard case .map(let m) = DifyDSL.appMeta(imp.metadata, document: imp.document) else { Issue.record("meta"); return }
        #expect(m["environment_variables"] == .list([env]) && m["features"] == wf["features"])
    }

    @Test func variablesWithoutUsableIdsGetFreshOnes() throws {
        let yaml = """
        app: {name: ids, mode: workflow}
        workflow:
          environment_variables:
          - {name: a, value: '1', value_type: string}
          - {id: k, name: b, value: '2', value_type: string}
          - {id: k, name: c, value: '3', value_type: string}
          - {id: '', name: d, value: '4', value_type: string}
          conversation_variables: []
          graph:
            nodes:
            - id: s
              data: {type: start, title: Start, variables: []}
            edges: []
        """
        var n = 0
        let imported = try DifyDSL.importYAML(yaml, newId: { n += 1; return n == 1 ? "k" : "fresh\(n)" })  // a clash is skipped
        guard case .items(let items)? = imported.document.app["environment_variables"] else { Issue.record("items"); return }
        #expect(items.map(\.id) == ["fresh2", "k", "fresh3", "fresh4"])
        for i in items { if case .map(let m) = i.value { #expect(m["id"] == .string(i.id)) } }
        // The fresh ids are part of the export, so importing the export again gives the same variables.
        let again = try DifyDSL.importYAML(try DifyDSL.exportYAML(imported.document, metadata: imported.metadata))
        #expect(again.document.app["environment_variables"] == imported.document.app["environment_variables"])
        // No features in the file: the export writes Dify's empty default.
        guard case .map(let top) = try DifyDSL.exportValue(imported.document, metadata: imported.metadata),
              case .map(let wf)? = top["workflow"] else { Issue.record("export"); return }
        #expect(wf["features"] == .map([:]))
    }

    static let secretYAML = """
        app: {name: env, mode: workflow}
        kind: app
        version: 0.3.1
        workflow:
          environment_variables:
          - {id: e1, name: api_key, value: sk-not-for-clients, value_type: secret, description: ''}
          - {id: e2, name: region, value: eu, value_type: string, description: ''}
          - {id: e3, name: empty, value: '', value_type: secret, description: ''}
          - {id: e4, name: short, value: abc, value_type: secret, description: ''}
          conversation_variables: []
          features: {}
          graph:
            nodes:
            - id: s
              data: {type: start, title: Start, variables: []}
            edges: []
        """

    @Test func secretsNeverEnterTheDocument() throws {
        var refs = 0
        let imported = try DifyDSL.importYAML(Self.secretYAML, newSecretRef: { refs += 1; return "sec-\(refs)" })
        #expect(imported.secrets == ["sec-1": "sk-not-for-clients", "sec-2": "abc"])
        let docJSON = try WireJSON.encodeString(imported.document)
        #expect(!docJSON.contains("sk-not-for-clients") && !docJSON.contains("\"abc\""))
        guard case .items(let env)? = imported.document.app["environment_variables"], env.count == 4,
              case .map(let key) = env[0].value, case .map(let empty) = env[2].value, case .map(let short) = env[3].value else {
            Issue.record("env items"); return
        }
        #expect(key["value"] == .string("sk-not************ts") && key["secret_ref"] == .string("sec-1"))
        #expect(empty["value"] == .string("") && empty["secret_ref"] == nil)  // empty secrets stay empty, without a reference
        #expect(short["value"] == .string("********************") && short["secret_ref"] == .string("sec-2"))
        #expect(!(try WireJSON.encodeString(imported.metadata)).contains("sk-not-for-clients"))

        func exportedEnv(_ secrets: [String: String]?) throws -> [Value] {
            guard case .map(let top) = try DifyDSL.exportValue(imported.document, metadata: imported.metadata, secrets: secrets),
                  case .map(let wf)? = top["workflow"], case .list(let env)? = wf["environment_variables"] else { return [] }
            return env
        }
        func value(_ v: Value, _ k: String) -> Value? { if case .map(let m) = v { return m[k] }; return nil }
        // Dify's default export: secrets blanked; never a secret_ref.
        let plain = try exportedEnv(nil)
        #expect(plain.map { value($0, "value") } == [.string(""), .string("eu"), .string(""), .string("")])
        #expect(plain.allSatisfy { value($0, "secret_ref") == nil })
        // include_secret: the stored plaintext; an unknown reference exports "".
        let full = try exportedEnv(imported.secrets)
        #expect(full.map { value($0, "value") } == [.string("sk-not-for-clients"), .string("eu"), .string(""), .string("abc")])
        #expect(full.allSatisfy { value($0, "secret_ref") == nil })
        #expect(try exportedEnv(["sec-2": "abc"]).map { value($0, "value") } == [.string(""), .string("eu"), .string(""), .string("abc")])
        // The original variables come back with include_secret.
        let yaml = try DifyDSL.exportYAML(imported.document, metadata: imported.metadata, secrets: imported.secrets)
        func envOf(_ v: Value) -> Value? {
            guard case .map(let top) = v, case .map(let wf)? = top["workflow"] else { return nil }
            return wf["environment_variables"]
        }
        let original = envOf(try parse(Self.secretYAML)), back = envOf(try parse(yaml))
        #expect(original != nil && back == original)
        // The meta endpoint serves the mask, never the plaintext nor the reference.
        guard case .map(let m) = DifyDSL.appMeta(imported.metadata, document: imported.document),
              case .list(let metaEnv)? = m["environment_variables"] else { Issue.record("meta"); return }
        #expect(metaEnv.map { value($0, "value") } == [.string("sk-not************ts"), .string("eu"), .string(""), .string("********************")])
        #expect(metaEnv.allSatisfy { value($0, "secret_ref") == nil })
    }

    @Test func maskIsDifysFormatSecret() {
        #expect(DifyDSL.maskSecret("123456789") == "123456************89")
        #expect(DifyDSL.maskSecret("12345678") == String(repeating: "*", count: 20))
        #expect(DifyDSL.maskSecret("") == String(repeating: "*", count: 20))
        let ref = DifyDSL.newSecretRef()
        #expect(ref.hasPrefix("sec-") && ref.count == 36 && ref.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func documentsImportedBefore17StillExportTheirMetadataVariables() throws {
        // Before 1.7 the variables stayed in the metadata (plaintext secrets included) and the document had no `app`.
        let imported = try DifyDSL.importYAML(Self.secretYAML)
        guard case .map(var top) = imported.metadata, case .map(var wf)? = top["workflow"] else { Issue.record("meta"); return }
        let legacyEnv: Value = .list([.map(["id": .string("e1"), "name": .string("k"), "value": .string("plain"), "value_type": .string("secret")])])
        wf["environment_variables"] = legacyEnv
        wf["features"] = .map(["x": .int(1)])
        top["workflow"] = .map(wf)
        let legacy = Document(nodes: Array(imported.document.nodes.values))
        guard case .map(let out) = try DifyDSL.exportValue(legacy, metadata: .map(top), secrets: [:]), case .map(let owf)? = out["workflow"],
              case .map(let blank) = try DifyDSL.exportValue(legacy, metadata: .map(top)), case .map(let bwf)? = blank["workflow"],
              case .map(let meta) = DifyDSL.appMeta(.map(top), document: legacy) else { Issue.record("export"); return }
        #expect(owf["environment_variables"] == legacyEnv && owf["features"] == .map(["x": .int(1)]))
        #expect(bwf["environment_variables"] == .list([.map(["id": .string("e1"), "name": .string("k"), "value": .string(""), "value_type": .string("secret")])]))
        #expect(meta["environment_variables"] == bwf["environment_variables"])
    }

    @Test func numbersHaveOneRepresentation() throws {
        #expect(Value.number(1.0) == .int(1))
        #expect(Value.number(0.7) == .double(0.7))
        #expect(Value.double(2.0).structuralProblem != nil)
        let data = try JSONEncoder().encode(Value.map(["t": .double(0.7), "n": .int(3)]))
        #expect(try JSONDecoder().decode(Value.self, from: data) == .map(["t": .double(0.7), "n": .int(3)]))
    }
}
