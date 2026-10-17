import Testing
import Foundation
@testable import CollabCore

private func node(_ id: String, _ cfg: [String: Value] = [:]) -> Node { Node(id: id, type: "llm", config: cfg) }
private func stamp(_ seq: Int, _ c: String) -> Stamp { Stamp(seq: seq, client: c) }
private func set(_ n: String, _ path: [String], _ v: String) -> Op { .setField(n, .config(path), .string(v)) }
private func ins(_ n: String, _ id: String, after: String? = nil) -> Op {
    .insertItem(n, path: ["outs"], item: Item(id: id, value: .string(id)), after: after)
}

@Suite("Document rules")
struct DocumentRuleTests {
    @Test func staleWriteIsRefusedNewerValueKept() throws {
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["prompt"], "new"), at: stamp(5, "bob"))
        // Alice wrote against version 3 (before bob's seq 5) with a different value: refused.
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["prompt"], "old"), base: 3, by: "alice") }
        // Based on version 5 or later: fine.
        try d.validate(set("a", ["prompt"], "ok"), base: 5, by: "alice")
        // Bob himself is never in conflict with his own earlier write.
        try d.validate(set("a", ["prompt"], "again"), base: 3, by: "bob")
        // Different field: never a conflict.
        try d.validate(set("a", ["code"], "x"), base: 3, by: "alice")
    }

    @Test func staleWriteOfTheCurrentValueIsNotAConflict() throws {
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["prompt"], "same"), at: stamp(5, "bob"))
        try d.validate(set("a", ["prompt"], "same"), base: 3, by: "alice")
        // It is a no-op: it must not re-stamp the register (a reader of version 5 is not made stale by it).
        var e = d
        e.apply(set("a", ["prompt"], "same"), at: stamp(9, "alice"))
        #expect(e == d)
        try e.validate(set("a", ["prompt"], "next"), base: 5, by: "carol")
        // Titles follow the same rule.
        d.apply(.setField("a", .title, .string("T")), at: stamp(6, "bob"))
        try d.validate(.setField("a", .title, .string("T")), base: 0, by: "alice")
        #expect(throws: RejectReason.self) { try d.validate(.setField("a", .title, .string("U")), base: 0, by: "alice") }
    }

    @Test func equalValueWriteLeavesStampAuthorAndTouchesUntouched() throws {
        // The 3-step trace of the formal model: c2 writes v1 (seq 1); c1's equal-value write (base 0) is accepted but must not
        // become the register's last writer, otherwise c1's next stale write (v2, base 0) would be exempt and overwrite c2.
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["f1"], "v1"), at: stamp(1, "c2"))
        try d.validate(set("a", ["f1"], "v1"), base: 0, by: "c1")
        let before = d
        d.apply(set("a", ["f1"], "v1"), at: stamp(2, "c1"))
        #expect(d == before)  // stamps, last writer and per-client touches are all unchanged
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["f1"], "v2"), base: 0, by: "c1") }
    }

    @Test func overlappingPathsConflictSiblingsDoNot() throws {
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["model", "name"], "x"), at: stamp(2, "bob"))
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["model"], "y"), base: 1, by: "alice") }
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["model", "name", "deep"], "y"), base: 1, by: "alice") }
        try d.validate(set("a", ["model", "temp"], "y"), base: 1, by: "alice")
    }

    @Test func moveIsLastWriterWinsAndNeverStale() throws {
        var d = Document(nodes: [node("a")])
        d.apply(.moveNode("a", x: 1, y: 1), at: stamp(5, "bob"))
        try d.validate(.moveNode("a", x: 2, y: 2), base: 0, by: "alice")
        d.apply(.moveNode("a", x: 2, y: 2), at: stamp(6, "alice"))
        #expect(d.nodes["a"]?.x == 2)
        // A drag is not content: it does not make a stale delete conflict.
        try d.validate(.removeNode("a"), base: 0, by: "carol")
    }

    @Test func deleteMarksReferencesBrokenAndRemovesEdges() {
        var d = Document(nodes: [
            node("a"), node("b", ["in": .ref(OutputRef(node: "a", output: "o")),
                                  "deep": .map(["l": .list([.ref(OutputRef(node: "a", output: "o")), .int(1)])]),
                                  "items": .items([Item(id: "i", value: .ref(OutputRef(node: "a", output: "o")))])]),
        ], edges: [Edge(id: "e", source: "a", target: "b")])
        d.apply(.removeNode("a"), at: stamp(1, "x"))
        #expect(d.nodes["b"]?.config["in"] == .brokenRef(OutputRef(node: "a", output: "o")))
        #expect(d.nodes["b"]?.config["items"] == .items([Item(id: "i", value: .brokenRef(OutputRef(node: "a", output: "o")))]))
        #expect(d.edges.isEmpty)
        #expect(d.integrityProblems.isEmpty)
        #expect(d.deletedNodes["a"] != nil)
    }

    @Test func danglingAndBrokenReferencesCannotBeWritten() {
        let d = Document(nodes: [node("a")])
        #expect(throws: RejectReason.self) {
            try d.validate(.setField("a", .config(["r"]), .ref(OutputRef(node: "ghost", output: "o"))), base: 0, by: "x")
        }
        #expect(throws: RejectReason.self) {
            try d.validate(.setField("a", .config(["r"]), .brokenRef(OutputRef(node: "a", output: "o"))), base: 0, by: "x")
        }
    }

    @Test func idsAreNeverReused() {
        var d = Document(nodes: [node("a")])
        d.apply(.removeNode("a"), at: stamp(1, "x"))
        #expect(throws: RejectReason.self) { try d.validate(.addNode(node("a")), base: 1, by: "x") }
    }

    @Test func deleteConflictsWithUnseenReferenceWrite() {
        var d = Document(nodes: [node("a"), node("b")])
        d.apply(.setField("b", .config(["in"]), .ref(OutputRef(node: "a", output: "o"))), at: stamp(4, "bob"))
        #expect(throws: RejectReason.self) { try d.validate(.removeNode("a"), base: 3, by: "alice") }
    }
}

@Suite("Keyed lists")
struct ListItemTests {
    @Test func differentItemsNeverConflict() throws {
        var d = Document(nodes: [node("a")])
        d.apply(ins("a", "x"), at: stamp(1, "bob"))
        try d.validate(ins("a", "y"), base: 0, by: "alice")
        d.apply(ins("a", "y"), at: stamp(2, "alice"))
        try d.validate(.updateItem("a", path: ["outs"], id: "y", value: .int(1)), base: 0, by: "alice")
        // Same item, written by bob at seq 1 which carol has not seen: conflict.
        #expect(throws: RejectReason.self) {
            try d.validate(.updateItem("a", path: ["outs"], id: "x", value: .int(2)), base: 0, by: "carol")
        }
    }

    @Test func insertOrderFollowsAnchorAndAppendsWhenAnchorIsGone() {
        var d = Document(nodes: [node("a")])
        d.apply(ins("a", "1"), at: stamp(1, "x"))
        d.apply(ins("a", "2", after: "1"), at: stamp(2, "x"))
        d.apply(ins("a", "3", after: "1"), at: stamp(3, "y"))  // concurrent insert after the same anchor
        d.apply(ins("a", "0"), at: stamp(4, "y"))             // at the front
        guard case .items(let xs)? = d.nodes["a"]?.config["outs"] else { Issue.record("no list"); return }
        #expect(xs.map(\.id) == ["0", "1", "3", "2"])
        d.apply(.removeItem("a", path: ["outs"], id: "1"), at: stamp(5, "x"))
        d.apply(ins("a", "9", after: "1"), at: stamp(6, "y"))  // anchor gone: append
        guard case .items(let ys)? = d.nodes["a"]?.config["outs"] else { return }
        #expect(ys.map(\.id) == ["0", "3", "2", "9"])
    }

    @Test func removeAndUpdateRules() throws {
        var d = Document(nodes: [node("a")])
        d.apply(ins("a", "x"), at: stamp(1, "bob"))
        d.apply(.removeItem("a", path: ["outs"], id: "x"), at: stamp(2, "bob"))
        // Removing again is the intended end state already: success, no-op.
        try d.validate(.removeItem("a", path: ["outs"], id: "x"), base: 0, by: "alice")
        // Editing a removed item is an explicit error; unknown items too.
        #expect(throws: RejectReason.itemDeleted("x")) {
            try d.validate(.updateItem("a", path: ["outs"], id: "x", value: .int(1)), base: 2, by: "alice")
        }
        #expect(throws: RejectReason.itemNotFound("nope")) {
            try d.validate(.removeItem("a", path: ["outs"], id: "nope"), base: 2, by: "alice")
        }
        // Item ids are never reused.
        #expect(throws: RejectReason.itemExists("x")) { try d.validate(ins("a", "x"), base: 2, by: "alice") }
    }

    @Test func wholeListReplaceIsStaleProtected() {
        var d = Document(nodes: [node("a")])
        d.apply(ins("a", "x"), at: stamp(1, "bob"))
        #expect(throws: RejectReason.self) {
            try d.validate(.setField("a", .config(["outs"]), .items([])), base: 0, by: "alice")
        }
    }
}

@Suite("Declared outputs (protocol 1.4)")
struct DeclaredOutputTests {
    // code1 declares outputs result/extra; code2 references code1.result; llm has no declared outputs.
    func doc() -> Document {
        let out = Value.map(["type": .string("string")])
        return Document(nodes: [
            Node(id: "code1", type: "code", config: ["outputs": .items([Item(id: "result", value: out), Item(id: "extra", value: out)])]),
            Node(id: "code2", type: "code", config: ["variables": .items([Item(id: "a", value: .ref(OutputRef(node: "code1", output: "result")))])]),
            Node(id: "llm1", type: "llm"),
        ])
    }
    func setRef(_ n: String, _ to: String, _ o: String) -> Op { .updateItem(n, path: ["variables"], id: "a", value: .ref(OutputRef(node: to, output: o))) }
    let removeResult = Op.removeItem("code1", path: ["outputs"], id: "result")

    @Test func referenceToAMissingDeclaredOutputIsRefused() throws {
        let d = doc()
        #expect(throws: RejectReason.danglingReference("code1")) { try d.validate(setRef("code2", "code1", "nope"), base: 0, by: "b") }
        try d.validate(setRef("code2", "code1", "extra"), base: 0, by: "b")
        try d.validate(setRef("code2", "llm1", "text"), base: 0, by: "b")  // no declared outputs: any name
    }

    @Test func removingAnOutputBreaksItsReferences() {
        var d = doc()
        d.apply(removeResult, at: stamp(1, "a"))
        guard case .items(let vars)? = d.nodes["code2"]?.config["variables"] else { Issue.record("no variables"); return }
        #expect(vars.first?.value == .brokenRef(OutputRef(node: "code1", output: "result")))
        #expect(d.integrityProblems.isEmpty)
    }

    @Test func aReferenceAfterTheRemovalIsRefused() {
        var d = doc()
        d.apply(removeResult, at: stamp(1, "a"))
        #expect(throws: RejectReason.danglingReference("code1")) { try d.validate(setRef("code2", "code1", "result"), base: 0, by: "b") }
    }

    @Test func aStaleRemovalConflictsWithANewerReference() throws {
        // b points code2.a at code1.extra (seq 1); a, who has not seen that, removes extra: refused like a stale node delete.
        var d = doc()
        d.apply(setRef("code2", "code1", "extra"), at: stamp(1, "b"))
        #expect(throws: RejectReason.self) { try d.validate(.removeItem("code1", path: ["outputs"], id: "extra"), base: 0, by: "a") }
        // having seen it, a may remove it: the reference becomes an explicit broken marker
        try d.validate(.removeItem("code1", path: ["outputs"], id: "extra"), base: 1, by: "a")
    }

    @Test func outputsAreReferencedByNameAndARenameBreaksTheOldName() throws {
        // the real shape: stable item id, the output's name in the value
        var d = Document(nodes: [
            Node(id: "code", type: "code", config: ["outputs": .items([Item(id: "o-1", value: .map(["name": .string("result")]))])]),
            Node(id: "ans", type: "answer", config: ["answer": .ref(OutputRef(node: "code", output: "result"))]),
        ])
        #expect(d.integrityProblems.isEmpty)
        try d.validate(.setField("ans", .config(["answer"]), .ref(OutputRef(node: "code", output: "result"))), base: 0, by: "b")
        #expect(throws: RejectReason.danglingReference("code")) {
            try d.validate(.setField("ans", .config(["answer"]), .ref(OutputRef(node: "code", output: "o-1"))), base: 0, by: "b")
        }
        d.apply(.updateItem("code", path: ["outputs"], id: "o-1", value: .map(["name": .string("answer_text")])), at: stamp(1, "a"))
        #expect(d.nodes["ans"]?.config["answer"] == .brokenRef(OutputRef(node: "code", output: "result")))
        #expect(d.integrityProblems.isEmpty)
    }

    @Test func integrityReportsAReferenceToAMissingOutput() {
        // a state the ops can no longer produce, built directly
        let d = Document(nodes: [
            Node(id: "code1", type: "code", config: ["outputs": .items([])]),
            Node(id: "code2", type: "code", config: ["variables": .items([Item(id: "a", value: .ref(OutputRef(node: "code1", output: "result")))])]),
        ])
        #expect(d.integrityProblems.contains { $0.contains("code1.result") })
    }
}

@Suite("Restoring a deleted node (protocol 1.6)")
struct RestoreTests {
    private func ref(_ n: String, _ o: String = "o") -> Value { .ref(OutputRef(node: n, output: o)) }
    private func broken(_ n: String, _ o: String = "o") -> Value { .brokenRef(OutputRef(node: n, output: o)) }
    private func reason(_ d: Document, _ op: Op, base: Int, by c: ClientID) -> RejectReason? {
        do throws(RejectReason) { try d.validate(op, base: base, by: c); return nil } catch { return error }
    }

    /// a <- b (b.in refs a), edge a->b, c unrelated; alice deletes a at seq 5.
    private func deleted() -> (Document, Node, [Edge]) {
        let a = node("a", ["p": .string("x")])
        let e = Edge(id: "e", source: "a", target: "b")
        var d = Document(nodes: [a, node("b", ["in": ref("a")]), node("c")], edges: [e, Edge(id: "f", source: "b", target: "c")])
        d.apply(.removeNode("a"), at: stamp(5, "alice"))
        return (d, a, [e])
    }

    @Test func restoreUndoesTheDelete() throws {
        var (d, a, es) = deleted()
        try d.validate(.restoreNode(a, edges: es), base: 4, by: "alice")  // own delete: the base may predate it
        d.apply(.restoreNode(a, edges: es), at: stamp(6, "alice"))
        #expect(d.nodes["a"] == a && d.deletedNodes["a"] == nil)
        #expect(d.edges["e"] == es[0] && d.deletedEdges["e"] == nil)
        #expect(d.nodes["b"]?.config["in"] == ref("a"))
        #expect(d.integrityProblems.isEmpty)
        // The restore versions the whole node and the fields it revived.
        #expect(d.fieldStamps["a"]?[.title] == stamp(6, "alice") && d.fieldStamps["a"]?[.config([])] == stamp(6, "alice"))
        #expect(d.fieldStamps["b"]?[.config(["in"])] == stamp(6, "alice"))
        #expect(d.touches["a"]?["alice"] == 6 && d.touches["b"]?["alice"] == 6)
        // Restoring twice: the node exists.
        #expect(reason(d, .restoreNode(a, edges: []), base: 6, by: "alice") == .nodeExists("a"))
    }

    @Test func refusals() {
        let (d, a, es) = deleted()
        #expect(reason(d, .restoreNode(node("ghost"), edges: []), base: 5, by: "x") == .nodeNotFound("ghost"))
        #expect(reason(d, .restoreNode(node("b"), edges: []), base: 5, by: "x") == .nodeExists("b"))
        // Undo is only of one's own operations: only alice, who deleted it, may restore it (whatever the base).
        #expect(reason(d, .restoreNode(a, edges: es), base: 4, by: "bob") == .notDeleter("a", by: "alice"))
        #expect(reason(d, .restoreNode(a, edges: es), base: 5, by: "bob") == .notDeleter("a", by: "alice"))
        #expect(RejectReason.notDeleter("a", by: "alice").isStaleBased)
        // The rule is a validity rule: it holds when a client replays committed entries too.
        do throws(RejectReason) {
            try d.validate(.restoreNode(a, edges: es), base: 5, by: "bob", checkConflicts: false)
            Issue.record("accepted a restore by someone else")
        } catch { #expect(error == .notDeleter("a", by: "alice")) }
        // Malformed edge lists.
        #expect(reason(d, .restoreNode(a, edges: es + es), base: 5, by: "alice") == .invalid("edge e listed twice"))
        #expect(reason(d, .restoreNode(a, edges: [Edge(id: "f", source: "b", target: "c")]), base: 5, by: "alice")
                == .invalid("edge f does not touch node a"))
        var bad = a
        bad.config["$x"] = .int(1)
        #expect(reason(d, .restoreNode(bad, edges: []), base: 5, by: "alice") == .invalid("config key $x is reserved"))
    }

    @Test func restoreConflictsWithAnUnseenWriteToAFieldItRevives() {
        var d = Document(nodes: [node("a"), node("b", ["in": .list([ref("a"), ref("c")])]), node("c")])
        d.apply(.removeNode("a"), at: stamp(5, "alice"))
        d.apply(.removeNode("c"), at: stamp(6, "bob"))  // rewrites b.in again
        #expect(reason(d, .restoreNode(node("a"), edges: []), base: 5, by: "alice")
                == .conflict(Conflict(node: "b", field: .config(["in"]), seq: 6, by: "bob")))
        #expect(reason(d, .restoreNode(node("a"), edges: []), base: 6, by: "alice") == nil)
        d.apply(.restoreNode(node("a"), edges: []), at: stamp(7, "alice"))
        #expect(d.nodes["b"]?.config["in"] == .list([ref("a"), broken("c")]))
    }

    @Test func aStaleWriteToTheRestoredNodeConflicts() throws {
        var (d, a, es) = deleted()
        d.apply(.restoreNode(a, edges: es), at: stamp(6, "alice"))
        #expect(reason(d, set("a", ["p"], "y"), base: 4, by: "carol")
                == .conflict(Conflict(node: "a", field: .config([]), seq: 6, by: "alice")))
        #expect(reason(d, set("a", ["new"], "y"), base: 4, by: "carol") != nil)
        #expect(reason(d, .setField("a", .title, .string("t")), base: 4, by: "carol") != nil)
        #expect(reason(d, .removeNode("a"), base: 4, by: "carol") == .conflict(Conflict(node: "a", field: nil, seq: 6, by: "alice")))
        try d.validate(set("a", ["p"], "x"), base: 4, by: "carol")  // same value: still fine
        try d.validate(set("a", ["p"], "y"), base: 6, by: "carol")  // saw the restore
        try d.validate(.moveNode("a", x: 9, y: 9), base: 0, by: "carol")  // layout is never stale
    }

    @Test func edgesThatCannotComeBackAreSkipped() {
        var (d, a, es) = deleted()
        d.apply(.removeNode("b"), at: stamp(6, "bob"))  // the other end of e is gone now
        let fresh = Edge(id: "g", source: "a", target: "c")  // an id the delete did not remove
        #expect(reason(d, .restoreNode(a, edges: es + [fresh]), base: 6, by: "alice") == nil)
        d.apply(.restoreNode(a, edges: es + [fresh]), at: stamp(7, "alice"))
        #expect(d.nodes["a"] != nil && d.edges.isEmpty && d.deletedEdges["e"] == stamp(5, "alice"))
        #expect(d.integrityProblems.isEmpty)
    }

    @Test func restoredReferencesAreLiveExactlyWhenTheirTargetIsThere() {
        var d = Document(nodes: [node("a"), node("b"), node("x", ["outputs": .items([Item(id: "i1", value: .map(["name": .string("r")]))])])])
        d.apply(.removeNode("a"), at: stamp(1, "alice"))
        d.apply(.removeNode("b"), at: stamp(2, "alice"))
        // As alice last saw it, a referenced b (deleted since), x.r (declared), x.gone (not declared) and itself.
        let a = node("a", ["b": ref("b"), "x": ref("x", "r"), "old": broken("x", "r"), "gone": ref("x", "gone"), "me": ref("a")])
        d.apply(.restoreNode(a, edges: []), at: stamp(3, "alice"))
        let cfg = d.nodes["a"]!.config
        #expect(cfg["b"] == broken("b") && cfg["x"] == ref("x", "r") && cfg["old"] == ref("x", "r"))
        #expect(cfg["gone"] == broken("x", "gone") && cfg["me"] == ref("a"))
        #expect(d.integrityProblems.isEmpty)
    }

    @Test func onlyDeclaredOutputsAreRevivedInOtherNodes() {
        func out(_ id: String, _ name: String) -> Item { Item(id: id, value: .map(["name": .string(name)])) }
        var d = Document(nodes: [node("a", ["outputs": .items([out("i1", "r"), out("i2", "s")])]),
                                 node("b", ["r": ref("a", "r"), "s": ref("a", "s")])])
        d.apply(.removeItem("a", path: ["outputs"], id: "i2"), at: stamp(1, "alice"))  // b.s breaks
        d.apply(.removeNode("a"), at: stamp(2, "alice"))  // b.r breaks
        d.apply(.restoreNode(node("a", ["outputs": .items([out("i1", "r")])]), edges: []), at: stamp(3, "alice"))
        #expect(d.nodes["b"]?.config["r"] == ref("a", "r") && d.nodes["b"]?.config["s"] == broken("a", "s"))
        #expect(d.integrityProblems.isEmpty)
    }

    @Test func wireShape() throws {
        let op = Op.restoreNode(Node(id: "n", type: "llm", title: "t", x: 1, y: 2, config: ["r": broken("m")]),
                                edges: [Edge(id: "e", source: "n", target: "m")])
        #expect(try WireJSON.encodeString(op) == #"{"edges":[{"id":"e","source":"n","sourceHandle":"out","target":"m","targetHandle":"in"}],"node":{"config":{"r":{"$broken":{"node":"m","output":"o"}}},"id":"n","title":"t","type":"llm","x":1,"y":2},"t":"restoreNode"}"#)
        #expect(try WireJSON.decode(Op.self, from: try WireJSON.encode(op)) == op)
        // `edges` may be omitted.
        #expect(try WireJSON.decode(Op.self, from: #"{"t":"restoreNode","node":{"id":"n","type":"llm","title":"","x":0,"y":0,"config":{}}}"#)
                == .restoreNode(Node(id: "n", type: "llm"), edges: []))
        // A restored document keeps the 1.5 snapshot shape (the whole-config stamp is a config key with an empty path).
        var (d, a, es) = deleted()
        d.apply(.restoreNode(a, edges: es), at: stamp(6, "alice"))
        #expect(try WireJSON.encodeString(d).contains(#"{"client":"alice","field":{"k":"config","path":[]},"node":"a","seq":6}"#))
        #expect(try WireJSON.decode(Document.self, from: try WireJSON.encode(d)) == d)
    }

    @Test func oldStreamsNeverCarryARestore() throws {
        #expect(StreamCompat.acceptsRestore("1.6") && StreamCompat.acceptsRestore("1.10") && StreamCompat.acceptsRestore("2.0"))
        #expect(!StreamCompat.acceptsRestore(nil) && !StreamCompat.acceptsRestore("1.5") && !StreamCompat.acceptsRestore("x"))
        #expect(StreamCompat.parse("1.6")! == (1, 6) && StreamCompat.parse("1.6.1") == nil && StreamCompat.parse("1.") == nil)
        #expect(StreamCompat.parse("-1.6") == nil && StreamCompat.parse("1.6x") == nil)
        let restore = Op.restoreNode(node("a"), edges: [])
        #expect(!StreamCompat.streamCarries(restore, proto: nil) && StreamCompat.streamCarries(restore, proto: "1.6"))
        #expect(StreamCompat.streamCarries(.removeNode("a"), proto: nil))
        #expect(try WireJSON.encodeString(RejectReason.notDeleter("a", by: "c")) == #"{"by":"c","node":"a","type":"notDeleter"}"#)
    }
}

@Suite("Document-level registers (protocol 1.7)")
struct AppRegisterTests {
    static let fixture = #"{"app":{"environment_variables":{"$items":[{"id":"x","value":{"id":"x","name":"x","value":"1"}}]},"features":{"a":true,"b":1}},"deletedEdges":{},"deletedItems":{"y":{"client":"bob","seq":4}},"deletedNodes":{},"edges":[],"fieldStamps":[{"client":"alice","field":{"k":"config","path":["features"]},"node":"$app","seq":2},{"client":"alice","field":{"id":"x","k":"item","path":["environment_variables"]},"node":"$app","seq":1},{"client":"bob","field":{"id":"y","k":"item","path":["environment_variables"]},"node":"$app","seq":4}],"nodes":[{"config":{},"id":"a","title":"","type":"llm","x":0,"y":0}],"touches":[]}"#

    private let app = Document.appNode
    private let env = ["environment_variables"]
    private func reason(_ d: Document, _ op: Op, base: Int, by c: ClientID) -> RejectReason? {
        do throws(RejectReason) { try d.validate(op, base: base, by: c); return nil } catch { return error }
    }
    private func variable(_ id: String, _ v: String) -> Value { .map(["id": .string(id), "name": .string(id), "value": .string(v)]) }
    private func insVar(_ id: String, _ v: String = "1", after: String? = nil) -> Op {
        .insertItem(app, path: env, item: Item(id: id, value: variable(id, v)), after: after)
    }
    private func updVar(_ id: String, _ v: String) -> Op { .updateItem(app, path: env, id: id, value: variable(id, v)) }

    @Test func itemOpsWorkOnTheAppNode() throws {
        var d = Document(nodes: [node("a")])
        try d.validate(insVar("x"), base: 0, by: "alice")
        d.apply(insVar("x"), at: stamp(1, "alice"))
        d.apply(insVar("y", after: "x"), at: stamp(2, "alice"))
        #expect(d.app["environment_variables"] == .items([Item(id: "x", value: variable("x", "1")), Item(id: "y", value: variable("y", "1"))]))
        d.apply(updVar("y", "2"), at: stamp(3, "bob"))
        d.apply(.removeItem(app, path: env, id: "x"), at: stamp(4, "bob"))
        #expect(d.app["environment_variables"] == .items([Item(id: "y", value: variable("y", "2"))]))
        #expect(d.deletedItems["x"] == stamp(4, "bob"))
        #expect(d.fieldStamps[app]?[.item(env, "y")] == stamp(3, "bob") && d.fieldStamps[app]?[.item(env, "x")] == stamp(4, "bob"))
        // No touches: nothing can delete $app.
        #expect(d.touches[app] == nil && d.nodes[app] == nil)
        #expect(reason(d, updVar("x", "3"), base: 4, by: "alice") == .itemDeleted("x"))
        #expect(reason(d, insVar("x"), base: 4, by: "alice") == .itemExists("x"))
        #expect(reason(d, .removeItem(app, path: env, id: "x"), base: 0, by: "alice") == nil)  // already gone: success
        #expect(reason(d, updVar("ghost", "3"), base: 4, by: "alice") == .itemNotFound("ghost"))
        #expect(d.integrityProblems.isEmpty)
    }

    @Test func configWritesWorkOnTheAppNode() throws {
        var d = Document()
        let f = Op.setField(app, .config(["features", "opening_statement"]), .string("hi"))
        try d.validate(f, base: 0, by: "alice")
        d.apply(f, at: stamp(1, "alice"))
        #expect(d.app["features"] == .map(["opening_statement": .string("hi")]))
        #expect(reason(d, .setField(app, .config(["features", "opening_statement", "x"]), .int(1)), base: 1, by: "alice")
                == .invalid("bad path [\"features\", \"opening_statement\", \"x\"]"))
        #expect(reason(d, .setField(app, .config(["$k"]), .int(1)), base: 1, by: "alice") == .invalid("reserved key in path"))
    }

    @Test func staleWritesConflictDifferentVariablesDoNot() throws {
        var d = Document()
        d.apply(insVar("x"), at: stamp(1, "alice"))
        d.apply(insVar("y"), at: stamp(2, "alice"))
        d.apply(updVar("x", "A"), at: stamp(3, "alice"))
        d.apply(.setField(app, .config(["features", "a"]), .int(1)), at: stamp(4, "alice"))
        // Bob saw version 2: a different variable is fine, the same one is a conflict naming alice's write.
        try d.validate(updVar("y", "B"), base: 2, by: "bob")
        #expect(reason(d, updVar("x", "B"), base: 2, by: "bob") == .conflict(Conflict(node: app, field: .item(env, "x"), seq: 3, by: "alice")))
        #expect(reason(d, .removeItem(app, path: env, id: "x"), base: 2, by: "bob")
                == .conflict(Conflict(node: app, field: .item(env, "x"), seq: 3, by: "alice")))
        // Same-value rule (1.2): writing what is there is no conflict, and a pure no-op.
        try d.validate(updVar("x", "A"), base: 2, by: "bob")
        let before = d
        d.apply(updVar("x", "A"), at: stamp(5, "bob"))
        #expect(d == before)
        // Overlap rules: a whole-list or whole-map replace conflicts with newer item/member writes; siblings do not.
        #expect(reason(d, .setField(app, .config(env), .items([])), base: 2, by: "bob")
                == .conflict(Conflict(node: app, field: .item(env, "x"), seq: 3, by: "alice")))
        #expect(reason(d, .setField(app, .config(["features"]), .map([:])), base: 2, by: "bob")
                == .conflict(Conflict(node: app, field: .config(["features", "a"]), seq: 4, by: "alice")))
        try d.validate(.setField(app, .config(["features", "b"]), .int(2)), base: 2, by: "bob")
        try d.validate(updVar("x", "again"), base: 2, by: "alice")  // own writes never conflict
        // App registers and node registers are independent.
        try d.validate(insVar("z"), base: 0, by: "bob")
    }

    @Test func everythingElseNamingTheAppNodeIsInvalid() {
        var d = Document(nodes: [node("a")])
        d.apply(.removeNode("a"), at: stamp(1, "alice"))
        let d2 = Document(nodes: [node("a"), node("b")])
        #expect(reason(d2, .removeNode(app), base: 0, by: "c") == .invalid("removeNode is not allowed on $app"))
        #expect(reason(d2, .moveNode(app, x: 1, y: 1), base: 0, by: "c") == .invalid("moveNode is not allowed on $app"))
        #expect(reason(d2, .setField(app, .title, .string("t")), base: 0, by: "c") == .invalid("title is not allowed on $app"))
        #expect(reason(d2, .addEdge(Edge(id: "e", source: app, target: "a")), base: 0, by: "c") == .invalid("edge endpoint is not allowed on $app"))
        #expect(reason(d2, .addEdge(Edge(id: "e", source: "a", target: app)), base: 0, by: "c") == .invalid("edge endpoint is not allowed on $app"))
        // Reserved ids: nothing named `$...` can be added or restored.
        #expect(reason(d2, .addNode(Node(id: app, type: "llm")), base: 0, by: "c") == .invalid("node id $app is reserved (ids starting with $)"))
        #expect(reason(d2, .addNode(Node(id: "$x", type: "llm")), base: 0, by: "c") == .invalid("node id $x is reserved (ids starting with $)"))
        #expect(reason(d, .restoreNode(Node(id: "$x", type: "llm"), edges: []), base: 1, by: "alice")
                == .invalid("node id $x is reserved (ids starting with $)"))
        // No references in $app values, live or broken.
        let r = Value.ref(OutputRef(node: "b", output: "o"))
        #expect(reason(d2, .setField(app, .config(["features", "r"]), r), base: 0, by: "c") == .invalid("references are not allowed in $app"))
        #expect(reason(d2, .insertItem(app, path: env, item: Item(id: "v", value: .map(["s": r])), after: nil), base: 0, by: "c")
                == .invalid("references are not allowed in $app"))
        #expect(reason(d2, .setField(app, .config(["features", "r"]), .brokenRef(OutputRef(node: "b", output: "o"))), base: 0, by: "c")
                == .invalid("brokenRef is server-written only"))
        // Other `$` ids are simply unknown.
        #expect(reason(d2, .setField("$other", .config(["p"]), .int(1)), base: 0, by: "c") == .nodeNotFound("$other"))
        // Applying a refused op never changes anything.
        var d3 = d2
        d3.apply(.setField(app, .title, .string("t")), at: stamp(1, "c"))
        d3.apply(.removeNode(app), at: stamp(2, "c"))
        d3.apply(.addEdge(Edge(id: "e", source: app, target: "a")), at: stamp(3, "c"))
        #expect(d3 == d2)
    }

    @Test func wireShapeAndStreamGating() throws {
        #expect(try WireJSON.encodeString(insVar("x")) ==
                #"{"after":null,"item":{"id":"x","value":{"id":"x","name":"x","value":"1"}},"node":"$app","path":["environment_variables"],"t":"insertItem"}"#)
        var d = Document(nodes: [node("a")])
        // Without app registers a document keeps the 1.6 shape.
        #expect(!(try WireJSON.encodeString(d)).contains("\"app\""))
        d.apply(insVar("x"), at: stamp(1, "alice"))
        d.apply(.setField(app, .config(["features"]), .map(["b": .int(1), "a": .bool(true)])), at: stamp(2, "alice"))
        let json = try WireJSON.encodeString(d)
        #expect(json.contains(#""app":{"environment_variables":{"$items":[{"id":"x","value":{"id":"x","name":"x","value":"1"}}]},"features":{"a":true,"b":1}}"#))
        #expect(json.contains(#"{"client":"alice","field":{"id":"x","k":"item","path":["environment_variables"]},"node":"$app","seq":1}"#))
        #expect(try WireJSON.decode(Document.self, from: try WireJSON.encode(d)) == d)
        // Cross-implementation fixture: the Dart port (packages/collab_client test/app_registers_test.dart) decodes and
        // encodes exactly this document.
        d.apply(insVar("y"), at: stamp(3, "alice"))
        d.apply(.removeItem(app, path: env, id: "y"), at: stamp(4, "bob"))
        #expect(try WireJSON.encodeString(d) == Self.fixture)
        #expect(throws: (any Error).self) {
            try WireJSON.decode(Document.self, from: #"{"nodes":[],"edges":[],"app":[],"deletedNodes":{},"deletedEdges":{},"deletedItems":{},"fieldStamps":[],"touches":[]}"#)
        }
        // Streams: $app writes need proto >= 1.7; nothing else changed.
        #expect(insVar("x").touchesApp && updVar("x", "1").touchesApp && Op.removeItem(app, path: env, id: "x").touchesApp)
        #expect(Op.setField(app, .config(["f"]), .int(1)).touchesApp && !set("a", ["p"], "x").touchesApp)
        #expect(StreamCompat.streamCarries(insVar("x"), proto: "1.7") && StreamCompat.streamCarries(insVar("x"), proto: "2.0"))
        #expect(!StreamCompat.streamCarries(insVar("x"), proto: "1.6") && !StreamCompat.streamCarries(insVar("x"), proto: nil))
        #expect(StreamCompat.streamCarries(set("a", ["p"], "x"), proto: "1.6"))
        #expect(StreamCompat.acceptsAll("1.7") && !StreamCompat.acceptsAll("1.6") && protocolVersion == "1.7")
    }
}

@Suite("Wire format")
struct WireTests {
    private func roundTrip<T: Codable & Equatable>(_ v: T) throws {
        #expect(try WireJSON.decode(T.self, from: try WireJSON.encode(v)) == v)
    }

    @Test func valuesUseNaturalJSON() throws {
        let v: Value = .map(["a": .int(1), "b": .list([.null, .bool(true), .string("s")]),
                             "r": .ref(OutputRef(node: "n", output: "o")), "i": .items([Item(id: "x", value: .int(2))])])
        #expect(try WireJSON.encodeString(v) ==
                #"{"a":1,"b":[null,true,"s"],"i":{"$items":[{"id":"x","value":2}]},"r":{"$ref":{"node":"n","output":"o"}}}"#)
        try roundTrip(v)
        // protocol 1.5: fractional numbers are doubles, integral ones stay ints (one representation per number)
        #expect(try WireJSON.decode(Value.self, from: "1.5") == .double(1.5))
        #expect(try WireJSON.decode(Value.self, from: "2.0") == .int(2))
        #expect(try WireJSON.encodeString(Value.double(0.7)) == "0.7")
        #expect(throws: (any Error).self) { try WireJSON.decode(Value.self, from: #"{"$weird":1}"#) }
    }

    @Test func opsRoundTripAndHaveStableShape() throws {
        let ops: [Op] = [
            .addNode(Node(id: "n", type: "llm", title: "t", x: 1, y: 2, config: ["p": .string("x")])),
            .removeNode("n"), .moveNode("n", x: 3, y: 4),
            .setField("n", .title, .string("t")), .setField("n", .config(["a", "b"]), .int(1)),
            .addEdge(Edge(id: "e", source: "a", target: "b")), .removeEdge("e"),
            ins("n", "i", after: "j"), ins("n", "k"),
            .removeItem("n", path: ["outs"], id: "i"), .updateItem("n", path: ["outs"], id: "i", value: .null),
        ]
        for op in ops { try roundTrip(op) }
        #expect(try WireJSON.encodeString(Op.moveNode("n", x: 3, y: 4)) == #"{"node":"n","t":"moveNode","x":3,"y":4}"#)
        #expect(try WireJSON.encodeString(ins("n", "i")) ==
                #"{"after":null,"item":{"id":"i","value":"i"},"node":"n","path":["outs"],"t":"insertItem"}"#)
    }

    @Test func rejectReasonsRoundTrip() throws {
        let reasons: [RejectReason] = [
            .conflict(Conflict(node: "n", field: .item(["outs"], "i"), seq: 3, by: "c")),
            .conflict(Conflict(node: "n", field: nil, seq: 3, by: "c")),
            .conflict(Conflict(node: "n", field: .title, seq: 3, by: "c", byName: "Bo")),
            .nodeDeleted("n"), .nodeNotFound("n"), .nodeExists("n"), .edgeNotFound("e"), .edgeExists("e"), .duplicateEdge("e"),
            .danglingReference("n"), .itemNotFound("i"), .itemDeleted("i"), .itemExists("i"), .invalid("why"), .notCommitted, .clientIdInUse,
            .notDeleter("n", by: "c"),
        ]
        for r in reasons { try roundTrip(r) }
    }

    @Test func conflictNameIsOptionalOnTheWire() throws {
        let plain = try WireJSON.encodeString(RejectReason.conflict(Conflict(node: "n", field: nil, seq: 3, by: "c")))
        #expect(!plain.contains("byName"))
        let named = try WireJSON.encodeString(RejectReason.conflict(Conflict(node: "n", field: nil, seq: 3, by: "c", byName: "Bo")))
        #expect(named.contains(#""byName":"Bo""#))
        // Old payloads (no byName) still decode.
        #expect(try WireJSON.decode(RejectReason.self, from: plain) == .conflict(Conflict(node: "n", field: nil, seq: 3, by: "c")))
    }

    @Test func documentSnapshotRoundTripKeepsStamps() throws {
        var d = Document(nodes: [node("a"), node("b")], edges: [])
        d.apply(set("a", ["p"], "v"), at: stamp(1, "c"))
        d.apply(ins("a", "i"), at: stamp(2, "c"))
        d.apply(.removeItem("a", path: ["outs"], id: "i"), at: stamp(3, "d"))
        d.apply(.addEdge(Edge(id: "e", source: "a", target: "b")), at: stamp(4, "d"))
        d.apply(.removeNode("b"), at: stamp(5, "d"))
        try roundTrip(d)
        // Encoding is deterministic.
        #expect(try WireJSON.encode(d) == WireJSON.encode(try WireJSON.decode(Document.self, from: try WireJSON.encode(d))))
    }

    @Test func undecodableOpBecomesPerOpErrorNotBatchFailure() throws {
        let json = #"{"client":"c","ops":[{"cseq":1,"base":0,"op":{"t":"teleport"}},{"cseq":2,"base":0,"op":{"t":"removeNode","node":"n"}}]}"#
        let req = try WireJSON.decode(SubmitRequest.self, from: json)
        #expect(req.ops.count == 2)
        #expect(req.ops[0].op == nil && req.ops[0].decodeError != nil)
        #expect(req.ops[1].op == .removeNode("n"))
    }

    @Test func sseFraming() throws {
        let e = LogEntry(seq: 7, client: "c", cseq: 2, base: 5, op: .removeEdge("e"))
        let frame = try StreamEvent.commit(e).sseFrame()
        #expect(frame == "id: 7\nevent: commit\ndata: {\"base\":5,\"client\":\"c\",\"cseq\":2,\"op\":{\"edge\":\"e\",\"t\":\"removeEdge\"},\"seq\":7}\n\n")
        #expect(try StreamEvent.ping.sseFrame() == ": ping\n\n")
        #expect(try StreamEvent.parse(event: "commit", data: String(frame.split(separator: "\n")[2].dropFirst(6))) == .commit(e))
        #expect(try StreamEvent.ready(head: 3).sseFrame() == "event: ready\ndata: {\"head\":3}\n\n")
    }
}

@Suite("Sequencer")
struct SequencerTests {
    private func req(_ c: String, _ ops: [(Int, Int, Op)], floor: Int? = nil, resolveFrom: Int? = nil) -> SubmitRequest {
        SubmitRequest(client: c, floor: floor, resolveFrom: resolveFrom,
                      ops: ops.map { IncomingOp(cseq: $0.0, base: $0.1, op: $0.2) })
    }

    @Test func commitAssignsSeqAndRetransmitsAreIdempotent() {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        let b1 = s.process(req("c", [(1, 0, set("a", ["p"], "v"))]), clientHigh: 0, known: KnownOutcomes())
        #expect(b1.response.results == [.ack(cseq: 1, seq: 1)] && b1.entries.count == 1 && b1.newHigh == 1)
        // Retransmit: answered from durable facts (here supplied by the caller), nothing new.
        let b2 = s.process(req("c", [(1, 0, set("a", ["p"], "v"))]), clientHigh: 1, known: KnownOutcomes(committed: [1: 1]))
        #expect(b2.response.results == [.ack(cseq: 1, seq: 1)] && b2.isEmpty && s.seq == 1)
    }

    @Test func rejectionAdvancesCseqAndIsRemembered() {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        let b = s.process(req("c", [(1, 0, set("ghost", ["p"], "v")), (2, 0, set("a", ["p"], "ok"))]), clientHigh: 0, known: KnownOutcomes())
        #expect(b.response.results == [.reject(cseq: 1, reason: .nodeNotFound("ghost")), .ack(cseq: 2, seq: 1)])
        #expect(b.rejections[1] == .nodeNotFound("ghost") && b.newHigh == 2)
    }

    @Test func reusedIdempotencyKeyWithADifferentOpIsRefused() {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        let first = s.process(req("c", [(1, 0, set("a", ["p"], "mine"))]), clientHigh: 0, known: KnownOutcomes())
        let known = KnownOutcomes(committed: [1: 1], fingerprints: first.fingerprints)
        // A genuine retransmit (same op, same base) is acknowledged again ...
        let again = s.process(req("c", [(1, 0, set("a", ["p"], "mine"))]), clientHigh: 1, known: known)
        #expect(again.response.results == [.ack(cseq: 1, seq: 1)])
        // ... but another process that also uses client id "c" and its own cseq 1 for a different edit must be told so,
        // instead of being handed an ack for somebody else's op.
        let other = s.process(req("c", [(1, 0, set("a", ["p"], "theirs"))]), clientHigh: 1, known: known)
        #expect(other.response.results == [.reject(cseq: 1, reason: .clientIdInUse)] && other.isEmpty && s.seq == 1)
    }

    @Test func basesNeedNotBeMonotone() throws {
        // A client's later op may carry an older base (a typing draft keeps the version it started from).
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["p"], "foreign"), at: stamp(5, "bob"))
        d.apply(set("a", ["p"], "mine1"), at: stamp(6, "alice"))   // alice saw bob's write (base >= 5) and replaced it
        try d.validate(set("a", ["p"], "mine2"), base: 2, by: "alice")  // older draft base: only her own write is last
        d.apply(set("a", ["p"], "carol"), at: stamp(7, "carol"))
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["p"], "late"), base: 6, by: "alice") }
    }

    @Test func gapIsNotProcessed() {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        let b = s.process(req("c", [(3, 0, set("a", ["p"], "v"))]), clientHigh: 1, known: KnownOutcomes())
        #expect(b.response.results == [.gap(cseq: 3, expected: 2)] && b.isEmpty && s.seq == 0)
    }

    @Test func floorAbandonsAndResolveReportsFates() {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        let known = KnownOutcomes(committed: [2: 7], rejected: [3: .nodeDeleted("x")])
        let b = s.process(req("c", [], floor: 6, resolveFrom: 2), clientHigh: 3, known: known)
        #expect(b.newHigh == 5 && b.highChanged)
        #expect(b.response.known == KnownOutcomes(committed: [2: 7], rejected: [3: .nodeDeleted("x")]))
        // A late retransmit below the floor that was never committed is "notCommitted", never applied.
        let late = s.process(req("c", [(4, 0, set("a", ["p"], "late"))]), clientHigh: 5, known: KnownOutcomes())
        #expect(late.response.results == [.reject(cseq: 4, reason: .notCommitted)] && s.seq == 0)
    }

    @Test func baseFromTheFutureIsRejected() {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        let b = s.process(req("c", [(1, 99, set("a", ["p"], "v"))]), clientHigh: 0, known: KnownOutcomes())
        guard case .reject(_, .invalid)? = b.response.results.first else { Issue.record("expected invalid"); return }
    }

    @Test func recoveryReplaysTail() throws {
        var s = Sequencer(initial: Document(nodes: [node("a")]))
        var entries: [LogEntry] = []
        var snap: Snapshot?
        for i in 1...5 {
            let b = s.process(req("c", [(i, i - 1, set("a", ["p"], "\(i)"))]), clientHigh: i - 1, known: KnownOutcomes())
            entries += b.entries
            if i == 3 { snap = s.snapshot }
        }
        let r = try Sequencer(snapshot: snap!, tail: entries)
        #expect(r.doc == s.doc && r.seq == 5)
        #expect(throws: RecoveryError.logGap(expected: 4, found: 5)) {
            _ = try Sequencer(snapshot: snap!, tail: [entries[4]])
        }
    }

    @Test func resumePlans() {
        #expect(resumePlan(lastEventId: nil, head: 10, maxReplay: 5) == .snapshot)
        #expect(resumePlan(lastEventId: 10, head: 10, maxReplay: 5) == .replay(after: 10))
        #expect(resumePlan(lastEventId: 5, head: 10, maxReplay: 5) == .replay(after: 5))
        #expect(resumePlan(lastEventId: 4, head: 10, maxReplay: 5) == .snapshot)
        #expect(resumePlan(lastEventId: 11, head: 10, maxReplay: 5) == .snapshot)  // client is ahead: server lost data
    }
}

@Suite("Client")
struct ClientTests {
    private func joined(_ id: String = "me", doc: Document = Document(nodes: [node("a")])) -> Client {
        var c = Client(id: id, journaled: true)
        let reqs = c.tick(now: 0)
        guard case .openStream(let o)? = reqs.first else { fatalError("no open") }
        _ = c.receive(.snapshot(SnapshotEvent(seq: 0, doc: doc)), generation: o.generation, now: 1)
        _ = c.receive(.ready(head: 0), generation: o.generation, now: 1)
        return c
    }

    @Test func rebaseHidesConflictedPendingOpAndWarnsOnce() {
        var c = joined()
        let g = c.generation
        let r = c.edit(set("a", ["p"], "mine"), now: 2)
        #expect(r.requests.count == 1)
        #expect(c.view.nodes["a"]?.config["p"] == .string("mine"))
        let theirs = LogEntry(seq: 1, client: "bob", cseq: 1, base: 0, op: set("a", ["p"], "theirs"))
        _ = c.receive(.commit(theirs), generation: g, now: 3)
        #expect(c.view.nodes["a"]?.config["p"] == .string("theirs"))
        #expect(c.drainEvents().filter { if case .conflictDetected = $0 { return true }; return false }.count == 1)
        #expect(c.unresolvedCount == 1)  // stays queued until the server gives the verdict
        let verdict = SubmitResponse(head: 1, high: 1, results: [.reject(cseq: 1, reason: .conflict(Conflict(node: "a", field: .config(["p"]), seq: 1, by: "bob")))])
        _ = c.receive(verdict, now: 4)
        #expect(c.unresolvedCount == 0)
        #expect(c.drainEvents().contains { if case .rejected(1, _, _) = $0 { return true }; return false })
    }

    @Test func ackWaitsForTheStreamBeforeReportingCommitted() {
        var c = joined()
        let g = c.generation
        _ = c.edit(set("a", ["p"], "mine"), now: 2)
        _ = c.receive(SubmitResponse(head: 1, high: 1, results: [.ack(cseq: 1, seq: 1)]), now: 3)
        #expect(c.drainEvents().isEmpty && c.unresolvedCount == 1)
        #expect(c.view.nodes["a"]?.config["p"] == .string("mine"))  // still shown, no flicker
        _ = c.receive(.commit(LogEntry(seq: 1, client: "me", cseq: 1, base: 0, op: set("a", ["p"], "mine"))), generation: g, now: 4)
        #expect(c.drainEvents() == [.committed(cseq: 1, seq: 1)] && c.unresolvedCount == 0)
    }

    @Test func holeInTheStreamReopensFromLastSeq() {
        var c = joined()
        let g = c.generation
        let e2 = LogEntry(seq: 2, client: "bob", cseq: 2, base: 0, op: set("a", ["p"], "2"))
        let out = c.receive(.commit(e2), generation: g, now: 2)
        guard case .openStream(let o)? = out.first else { Issue.record("expected reopen"); return }
        #expect(o.lastEventId == 0 && o.generation == c.generation && o.generation > g && c.lastSeq == 0)
        // Events of the dead generation are ignored.
        _ = c.receive(.commit(LogEntry(seq: 1, client: "bob", cseq: 1, base: 0, op: set("a", ["p"], "1"))), generation: g, now: 3)
        #expect(c.lastSeq == 0)
    }

    @Test func silentStreamIsReopenedWithBackoff() {
        var c = joined()
        let cfg = ClientConfig()
        var opened = 0
        var t = 1
        while t < 400 {
            t += 1
            if c.tick(now: t).contains(where: { if case .openStream = $0 { return true }; return false }) { opened += 1 }
        }
        // Silent forever: watchdog fires, and reconnect attempts back off instead of hammering.
        #expect(opened >= 3 && opened <= 400 / cfg.streamSilence)
    }

    @Test func postIsResentAfterTimeoutAndOnlyOneIsInFlight() {
        var c = joined()
        let first = c.edit(set("a", ["p"], "1"), now: 2).requests
        #expect(first.count == 1)
        #expect(c.edit(set("a", ["q"], "2"), now: 3).requests.isEmpty)  // queued behind the in-flight POST
        let resent = c.tick(now: 2 + ClientConfig().retransmitAfter)
        guard case .submit(let req)? = resent.first(where: { if case .submit = $0 { return true }; return false }) else {
            Issue.record("no resend"); return
        }
        #expect(req.ops.map(\.cseq) == [1, 2])
    }

    @Test func localEditOfMissingNodeNeverBecomesAnOp() {
        var c = joined()
        let r = c.edit(set("ghost", ["p"], "x"), now: 2)
        #expect(r.cseq == nil && c.unresolvedCount == 0)
    }

    @Test func volatileRestartResolvesLostAndCommittedOps() {
        var c = Client(id: "v", journaled: false)
        let d = ClientDurable(id: "v", nextCseq: 4, unresolvedFrom: 2, journal: [])
        c = Client(restoring: d, journaled: false)
        let reqs = c.tick(now: 0)
        guard case .submit(let s)? = reqs.first(where: { if case .submit = $0 { return true }; return false }) else {
            Issue.record("expected resolve request"); return
        }
        #expect(s.floor == 4 && s.resolveFrom == 2 && s.ops.isEmpty)
        guard case .openStream(let o)? = reqs.first(where: { if case .openStream = $0 { return true }; return false }) else { return }
        _ = c.receive(.snapshot(SnapshotEvent(seq: 9, doc: Document(), committed: [2: 5])), generation: o.generation, now: 1)
        _ = c.receive(SubmitResponse(head: 9, high: 3, results: [], known: KnownOutcomes(committed: [2: 5])), now: 2)
        #expect(c.drainEvents() == [.committed(cseq: 2, seq: 5), .lost(cseq: 3)])
    }
}
