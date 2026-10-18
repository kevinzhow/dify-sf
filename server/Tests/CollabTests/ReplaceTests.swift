import Foundation
import Testing
@testable import CollabCore
@testable import CollabDSL

/// A document as the server holds it (sequencer, import metadata, stored secrets), for replacements without a database.
private struct Held {
    var seq: Sequencer
    var metadata: Value
    var secrets: [String: String]
    var highs: [String: Int] = [:]

    init(_ yaml: String) throws {
        let imp = try DifyDSL.importYAML(yaml)
        seq = Sequencer(initial: imp.document)
        metadata = imp.metadata
        secrets = imp.secrets
    }

    /// Commits `ops` of `client` with base = head (or `base`); returns the response.
    @discardableResult
    mutating func edit(_ client: String, _ ops: [Op], base: Int? = nil) -> SubmitResponse {
        let high = highs[client] ?? 0
        let b = base ?? seq.seq
        let req = SubmitRequest(client: client, ops: ops.enumerated().map { IncomingOp(cseq: high + 1 + $0.offset, base: b, op: $0.element) })
        let batch = seq.process(req, clientHigh: high, known: KnownOutcomes())
        highs[client] = batch.newHigh
        return batch.response
    }

    /// Plans and commits the replacement as the server does (one batch, base = head); every op must be acknowledged.
    mutating func replace(_ yaml: String, client: String = "r", newNodeId: @escaping () -> String = { "1999000000000" }) throws
        -> DifyDSL.ReplacementPlan {
        let plan = try DifyDSL.planReplacement(try DifyDSL.parseYAML(yaml), current: seq.doc, metadata: metadata, storedSecrets: secrets,
                                               client: client, base: seq.seq, newNodeId: newNodeId)
        let r = edit(client, plan.ops)
        #expect(r.results.allSatisfy { if case .ack = $0 { return true }; return false }, "\(r.results.filter { if case .ack = $0 { return false }; return true })")
        metadata = plan.metadata
        secrets.merge(plan.secrets) { $1 }
        #expect(Replacement.difference(seq.doc, plan.document) == nil)
        #expect(seq.doc.integrityProblems.isEmpty, "\(seq.doc.integrityProblems)")
        return plan
    }

    func export(secrets: Bool = false) throws -> Value {
        try DifyDSL.exportValue(seq.doc, metadata: metadata, secrets: secrets ? self.secrets : nil)
    }
}

private func seedYAML(mode: String) -> String {
    """
    app: {name: seed, mode: \(mode), icon: x}
    kind: app
    version: 0.3.1
    workflow:
      graph:
        nodes:
        - id: seed
          data: {type: start, title: Seed, variables: []}
          position: {x: 0, y: 0}
        edges: []
    """
}

private func modeOf(_ yaml: String) throws -> String {
    if case .map(let top) = try parse(yaml), case .map(let app)? = top["app"], case .string(let m)? = app["mode"] { return m }
    return "workflow"
}

private func expectSameFile(_ exported: Value, _ file: Value, _ name: String) {
    let diff = firstDifference(normalized(file), normalized(exported))
    #expect(diff == nil, "\(name): \(diff ?? "")")
}

/// What exporting a fresh import of `yaml` gives (minimal test files gain Dify's defaults on export).
private func importedExport(_ yaml: String) throws -> Value {
    let imp = try DifyDSL.importYAML(yaml)
    return try DifyDSL.exportValue(imp.document, metadata: imp.metadata)
}

private let iteration = "array_iteration_formatting_workflow.yml"

@Suite("Replacing a document from a Dify file")
struct ReplaceTests {
    @Test(arguments: fixtures)
    func replacingAnotherWorkflowGivesTheFile(_ name: String) throws {
        let yaml = try load(name)
        var held = try Held(seedYAML(mode: try modeOf(yaml)))
        let plan = try held.replace(yaml)
        #expect(plan.renamedNodes.isEmpty && plan.renamedEdges.isEmpty)
        #expect(plan.ops.contains(.removeNode("seed")))
        expectSameFile(try held.export(), try parse(yaml), name)
    }

    @Test(arguments: fixtures)
    func replacingWithTheSameFileWritesNothing(_ name: String) throws {
        let yaml = try load(name)
        var held = try Held(yaml)
        let before = held.seq.seq
        let plan = try held.replace(yaml)
        #expect(plan.ops.isEmpty, "\(name): \(plan.ops)")
        #expect(held.seq.seq == before)
        #expect(plan.metadata == held.metadata)
    }

    @Test func editsAreUndoneWithFineGrainedOps() throws {
        let yaml = try load(iteration)
        var held = try Held(yaml)
        let app = Document.appNode
        let env: Value = .map(["id": .string("e1"), "name": .string("region"), "value": .string("eu"), "value_type": .string("string")])
        let r = held.edit("u", [
            .setField("1754683442688", .title, .string("Make numbers")),
            .moveNode("1754683442688", x: 1, y: 2),
            .setField("1754683442688", .config(["code"]), .string("pass")),
            .insertItem("1754683442688", path: ["outputs"], item: Item(id: "count", value: .map(["name": .string("count"), "type": .string("number")])), after: "result"),
            .addNode(Node(id: "extra", type: "llm", title: "Extra", config: ["context": .ref(OutputRef(node: "1754683442688", output: "count"))])),
            .addEdge(Edge(id: "e-extra", source: "1754683480778", sourceHandle: "source", target: "extra", targetHandle: "target")),
            .insertItem(app, path: ["environment_variables"], item: Item(id: "e1", value: env), after: nil),
            .setField(app, .config(["features", "opening_statement"]), .string("Hi")),
        ])
        #expect(r.results.allSatisfy { if case .ack = $0 { return true }; return false })
        let plan = try held.replace(yaml)
        #expect(plan.renamedNodes.isEmpty && plan.renamedEdges.isEmpty)
        // One op per difference: the added edge and node go, the item comes out, every edited register is written back.
        #expect(plan.ops.contains(.removeEdge("e-extra")) && plan.ops.contains(.removeNode("extra")))
        #expect(plan.ops.contains(.removeItem("1754683442688", path: ["outputs"], id: "count")))
        #expect(plan.ops.contains(.removeItem(app, path: ["environment_variables"], id: "e1")))
        #expect(plan.ops.contains(.moveNode("1754683442688", x: 384, y: 282)))
        #expect(plan.ops.count == 8, "\(plan.ops)")
        expectSameFile(try held.export(), try parse(yaml), iteration)
    }

    @Test func tombstonedIdsGetFreshIdsAndEverythingFollows() throws {
        let yaml = try load(iteration)
        var held = try Held(yaml)
        // Delete the iteration (its edges go with it; references to it break), then put the file back.
        held.edit("u", [.removeNode("1754683430480")])
        var next = 1999000000000
        let plan = try held.replace(yaml, newNodeId: { next += 1; return String(next) })
        let fresh = "1999000000001"
        #expect(plan.renamedNodes == ["1754683430480": fresh])
        #expect(plan.renamedEdges == [
            "1754683442688-source-1754683430480-target": "1754683442688-source-\(fresh)-target",
            "1754683430480-source-1754683480778-target": "\(fresh)-source-1754683480778-target",
        ])
        let d = held.seq.doc
        #expect(d.nodes[fresh]?.type == "iteration" && d.nodes["1754683430480"] == nil)
        // References, children (parentId) and edge extras follow the new id.
        guard case .items(let vars)? = d.nodes["1754683458843"]?.config["variables"], case .map(let v)? = vars.first?.value,
              case .map(let child)? = d.nodes["1754683458843"]?.config["_dify_node"] else { Issue.record("template node"); return }
        #expect(v["value_selector"] == .ref(OutputRef(node: fresh, output: "item")))
        #expect(child["parentId"] == .string(fresh))
        #expect(d.nodes["1754683458843"]?.config["iteration_id"] == .string(fresh))
        // The export is the file with the ids renamed.
        let renamed = DifyDSL.renaming(try parse(yaml), nodes: plan.renamedNodes, edges: plan.renamedEdges)
        expectSameFile(try held.export(), renamed, iteration)
    }

    @Test func aNodeOfAnotherTypeOrWithFewerKeysIsReplacedUnderAFreshId() throws {
        func file(_ nodes: String) -> String {
            """
            app: {name: t, mode: workflow}
            workflow:
              graph:
                nodes:
            \(nodes)
                edges:
                - {id: ab, source: a, target: b, sourceHandle: source, targetHandle: target}
            """
        }
        var held = try Held(file("""
                - {id: a, data: {type: start, title: A, k1: 1}}
                - {id: b, data: {type: llm, title: B, k1: 1, k2: 2}}
                - {id: c, data: {type: llm, title: C, k1: 1}}
            """))
        let plan = try held.replace(file("""
                - {id: a, data: {type: start, title: A2, k1: 1, k3: 3}}
                - {id: b, data: {type: llm, title: B, k1: 1}}
                - {id: c, data: {type: code, title: C, k1: 1}}
            """), newNodeId: { "100" })
        #expect(plan.renamedNodes == ["b": "100", "c": "101"])
        #expect(plan.renamedEdges == ["ab": "a-source-100-target"])
        // `a` keeps its id: the title and the new key are written.
        #expect(plan.ops.contains(.setField("a", .title, .string("A2"))))
        #expect(plan.ops.contains(.setField("a", .config(["k3"]), .int(3))))
        #expect(held.seq.doc.nodes["100"]?.config["k2"] == nil && held.seq.doc.nodes["101"]?.type == "code")
    }

    @Test func aKeyedListWhoseNewItemIdIsTombstonedIsWrittenWhole() throws {
        let yaml = """
        app: {name: v, mode: workflow}
        kind: app
        version: 0.3.1
        workflow:
          environment_variables:
          - {id: e1, name: a, value: '1', value_type: string}
          - {id: e2, name: b, value: '2', value_type: string}
          graph:
            nodes:
            - {id: s, data: {type: start, title: S}}
            edges: []
        """
        var held = try Held(yaml)
        held.edit("u", [.removeItem(Document.appNode, path: ["environment_variables"], id: "e2")])
        let plan = try held.replace(yaml)
        guard case .setField(Document.appNode, .config(["environment_variables"]), .items(let items))? = plan.ops.first else {
            Issue.record("\(plan.ops)"); return
        }
        #expect(items.map(\.id) == ["e1", "e2"] && plan.ops.count == 1)
        expectSameFile(try held.export(), try importedExport(yaml), "variables")
    }

    @Test func brokenReferencesAreWrittenAsThePairsTheyStandFor() throws {
        let yaml = """
        app: {name: b, mode: workflow}
        kind: app
        version: 0.3.1
        workflow:
          graph:
            nodes:
            - {id: c, data: {type: code, title: C, outputs: {x: {type: string}}}}
            - {id: l, data: {type: llm, title: L, context: {variable_selector: [c, gone]}}}
            edges: []
        """
        var held = try Held(seedYAML(mode: "workflow"))
        let plan = try held.replace(yaml)
        #expect(held.seq.doc.nodes["l"]?.config["context"] == .map(["variable_selector": .list([.string("c"), .string("gone")])]))
        #expect(plan.ops.allSatisfy { if case .addNode(let n) = $0 { return !n.config.values.contains { $0.containsBrokenRef } }; return true })
        expectSameFile(try held.export(), try importedExport(yaml), "broken")
        // ... and the same file again is no change (a marker and its pair are alike).
        var imported = try Held(yaml)
        #expect(try imported.replace(yaml).ops.isEmpty)
    }

    @Test func secretsAreStoredAsideAndKeepTheirReferenceWhileTheyAreUnchanged() throws {
        func file(_ secret: String) -> String {
            """
            app: {name: s, mode: workflow}
            workflow:
              environment_variables:
              - {id: k, name: api_key, value: \(secret), value_type: secret}
              graph:
                nodes:
                - {id: s, data: {type: start, title: S}}
                edges: []
            """
        }
        var held = try Held(seedYAML(mode: "workflow"))
        let first = try held.replace(file("sk-first-secret-1"))
        #expect(first.secrets.values.sorted() == ["sk-first-secret-1"])
        for op in first.ops { #expect(!"\(op)".contains("sk-first-secret-1")) }
        let again = try held.replace(file("sk-first-secret-1"))
        #expect(again.ops.isEmpty && again.secrets.isEmpty)
        let changed = try held.replace(file("sk-second-secret-2"))
        #expect(changed.secrets.values.sorted() == ["sk-second-secret-2"])
        #expect(changed.ops.count == 1)
        guard case .updateItem(Document.appNode, ["environment_variables"], "k", .map(let v))? = changed.ops.first else {
            Issue.record("\(changed.ops)"); return
        }
        #expect(v["value"] == .string(DifyDSL.maskSecret("sk-second-secret-2")) && v["secret_ref"] == .string(changed.secrets.keys.first!))
        guard case .map(let top) = try held.export(secrets: true), case .map(let wf)? = top["workflow"],
              case .list(let env)? = wf["environment_variables"], case .map(let e)? = env.first else { Issue.record("export"); return }
        #expect(e["value"] == .string("sk-second-secret-2") && e["secret_ref"] == nil)
    }

    @Test func theAppKeepsItsModeAndTakesTheFilesName() throws {
        var held = try Held(seedYAML(mode: "advanced-chat"))
        let chat = try load("basic_chatflow.yml")
        _ = try held.replace(chat)
        guard case .map(let top) = held.metadata, case .map(let app)? = top["app"] else { Issue.record("metadata"); return }
        #expect(app["mode"] == .string("advanced-chat"))
        if case .map(let f) = try parse(chat), case .map(let fa)? = f["app"] { #expect(app["name"] == fa["name"]) }
    }

    @Test func staleEditsOfOthersConflictWithTheReplacement() throws {
        let yaml = try load(iteration)
        var held = try Held(yaml)
        held.edit("u", [.setField("1754683442688", .config(["code"]), .string("draft"))])
        let seen = held.seq.seq  // what another client has seen
        _ = try held.replace(yaml, client: "r")
        // A write based on a version before the replacement, to a register the replacement wrote: refused, naming it.
        let stale = held.edit("o", [.setField("1754683442688", .config(["code"]), .string("mine"))], base: seen)
        guard case .reject(_, .conflict(let c))? = stale.results.first else { Issue.record("\(stale.results)"); return }
        #expect(c.by == "r")
        // A register the replacement did not touch is still free.
        let other = held.edit("o", [.setField("1754683442688", .config(["desc"]), .string("note"))], base: seen)
        guard case .ack? = other.results.first else { Issue.record("\(other.results)"); return }
    }

    @Test func difyVersionAndModeRules() throws {
        func root(_ s: String) throws -> Value { try DifyDSL.parseYAML(s) }
        let ok = "app: {mode: workflow, name: x}\nversion: 0.7.0\nworkflow: {graph: {nodes: []}}"
        #expect(try DifyDSL.checkReplacement(root(ok), appMode: "workflow", confirm: false).status == .completed)
        let older = ok.replacingOccurrences(of: "0.7.0", with: "0.3.1")
        #expect(try DifyDSL.checkReplacement(root(older), appMode: "workflow", confirm: false).status == .completedWithWarnings)
        let newer = ok.replacingOccurrences(of: "0.7.0", with: "0.8.0")
        #expect(throws: DifyDSL.ReplaceRefusal.self) { try DifyDSL.checkReplacement(root(newer), appMode: "workflow", confirm: false) }
        #expect(try DifyDSL.checkReplacement(root(newer), appMode: "workflow", confirm: true).status == .pending)
        func refusal(_ s: String, mode: String = "workflow") -> String? {
            do { _ = try DifyDSL.checkReplacement(try root(s), appMode: mode, confirm: false); return nil } catch let e as DifyDSL.ReplaceRefusal {
                return e.message
            } catch { return "\(error)" }
        }
        #expect(refusal("- a") == "Invalid YAML format: content must be a mapping")
        #expect(refusal("version: 0.3\napp: {mode: workflow}") == "Invalid version type, expected str, got <class 'float'>")
        #expect(refusal("version: 0.3.1\nworkflow: {}") == "Missing app data in YAML content")
        #expect(refusal("app: {name: x}") == "loss app mode")
        #expect(refusal("app: {mode: chat, name: x}")?.hasPrefix("Only workflow or advanced chat") == true)
        let answer = "app: {mode: advanced-chat, name: x}\nworkflow: {graph: {nodes: [{id: a, data: {type: answer}}]}}"
        #expect(refusal(answer, mode: "workflow")?.hasPrefix("Import Failed") == true)
        #expect(refusal(answer, mode: "advanced-chat") == nil)
        let end = "app: {mode: workflow, name: x}\nworkflow: {graph: {nodes: [{id: e, data: {type: end}}]}}"
        #expect(refusal(end, mode: "advanced-chat")?.hasPrefix("Import Failed") == true)
        #expect(DifyDSL.versionStatus("abc") == .failed && DifyDSL.versionStatus("1.0.0") == .pending)
    }
}
