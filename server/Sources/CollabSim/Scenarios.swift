import CollabCore
import CollabInvariants

public struct ScenarioResult: Sendable {
    public struct Check: Sendable { public var what: String; public var ok: Bool }
    public var name: String
    public var checks: [Check] = []
    public var violations: [String] = []
    public var passed: Bool { violations.isEmpty && checks.allSatisfy(\.ok) }

    mutating func expect(_ ok: Bool, _ what: String) { checks.append(Check(what: what, ok: ok)) }
}

/// The seven shared scenarios (S1-S7, same list as the Dify repro) plus server-side extras.
/// Each is a hand-scripted interleaving on a `World`, followed by the full invariant check.
public enum Scenarios {
    public static let all: [@Sendable () -> ScenarioResult] = [
        s1_differentNodes, s1_sameNodeDifferentFields,
        s2_sameField_secondLoses, s2_sameField_reverseOrder, s2_overlappingPaths, s2_reapplyAfterConflict,
        s3_staleTab, s3_staleTabAfterCompaction,
        s4_dropBeforeServer, s4_ackLostRetransmit, s4_lossyNetwork,
        s5_crashJournaled, s5_crashVolatile, s5_crashAfterCommitBeforeAck,
        s6_fastEditsThenReload_journaled, s6_fastEditsThenReload_volatile,
        s7_staleDeleteVsEdit, s7_editAfterDelete, s7_deleteReferencedNode, s7_refToConcurrentlyDeletedNode,
        s7_doubleDelete, s7_edgeToDeletedNode,
        s8_serverCrashKeepsAcked, s8_serverCrashAfterLogBeforeAck,
        s9_thirtyUsersSameValue, s9_staleSameValueIsNoConflict, s9_sameValueDifferentOneStillConflicts, s9_equalValueWriteDoesNotLaunderLaterWrite,
        s10_itemInsertsNeverConflict, s10_itemRemovesAndUpdates, s10_staleListReplaceVsInsert, s10_removeAlreadyRemovedItem,
        s11_positionIsLastWriterWins, s11_moveDoesNotBlockDelete, s11_moveOfDeletedNode,
        s12_undoOwnDelete, { s12_staleWriteAfterRestore(defects: []) }, { s12_restoreSkipsEdgeToDeletedNode(defects: []) },
        { s12_onlyTheDeleterRestores(defects: []) }, s12_restoreConflictsWithUnseenCascade, s12_restoreBeforeTheDeleteIsConfirmed,
        s12_oldClientNeverSeesARestore,
        s13_differentVariablesNeverConflict, { s13_staleVariableEditIsAConflict(defects: []) }, s13_appTakesOnlyRegisterWrites,
        s13_oldClientsNeverSeeAppWrites,
    ]

    // MARK: helpers

    static func world(clients: Int = 2, volatile: Bool = false, snapshotEvery: Int = 64, drop: Double = 0,
                      nodes: Int = 5, defects: ProtocolDefects = [], legacy: Set<Int> = [], legacy16: Set<Int> = []) -> World {
        var cfg = SimConfig()
        cfg.legacySlots = legacy
        cfg.legacy16Slots = legacy16
        cfg.clientCount = clients
        cfg.initialNodes = nodes
        cfg.snapshotEvery = snapshotEvery
        cfg.maxDelay = 1
        cfg.volatileFraction = volatile ? 1 : 0
        cfg.dropRate = drop
        cfg.defects = defects
        var w = World(seed: 7, cfg: cfg)
        w.drain()
        return w
    }

    static func finish(_ name: String, _ w: inout World, _ r: inout ScenarioResult) -> ScenarioResult {
        r.name = name
        let ok = w.settle()
        r.expect(ok, "system settles after healing")
        r.violations = Fuzz.check(w)
        return r
    }

    static func prompt(_ n: NodeID, _ s: String) -> Op { .setField(n, .config(["prompt"]), .string(s)) }

    static func isConflict(_ t: Terminal) -> Bool {
        if case .rejected(.conflict) = t { return true }
        return false
    }
    static func isCommitted(_ t: [Terminal]) -> Bool {
        if case .committed? = t.first { return true }
        return false
    }
    static func isRejected(_ t: [Terminal], _ name: String) -> Bool {
        if case .rejected(let r)? = t.first { return r.name == name }
        return false
    }

    // MARK: S1 - concurrent edits that must both survive

    static func s1_differentNodes() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(0, prompt("n1", "from A"))
        w.userEdit(1, prompt("n2", "from B"))
        w.drain()
        r.expect(w.serverField("n1", "prompt") == .string("from A"), "A's edit on n1 is in the server state")
        r.expect(w.serverField("n2", "prompt") == .string("from B"), "B's edit on n2 is in the server state")
        r.expect(w.rec.stats["op.rejected"] == 0, "no rejections for edits on different nodes")
        return finish("S1 different nodes concurrently", &w, &r)
    }

    static func s1_sameNodeDifferentFields() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(0, prompt("n1", "A prompt"))
        w.userEdit(1, .setField("n1", .config(["code"]), .string("B code")))
        w.userEdit(0, .moveNode("n3", x: 5, y: 5))
        w.userEdit(1, .setField("n1", .title, .string("B title")))
        w.drain()
        r.expect(w.serverField("n1", "prompt") == .string("A prompt"), "prompt kept")
        r.expect(w.serverField("n1", "code") == .string("B code"), "code kept")
        r.expect(w.serverDoc?.nodes["n1"]?.title == "B title", "title kept")
        r.expect(w.rec.stats["op.rejected"] == 0, "different fields of one node never conflict")
        return finish("S1b same node, different fields", &w, &r)
    }

    // MARK: S2 - same field concurrently

    static func s2_sameField_secondLoses() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let a = w.userEdit(0, prompt("n1", "A"))!
        let b = w.userEdit(1, prompt("n1", "B"))!
        w.flush(slot: 0, toServer: true)  // server sequences A first
        w.flush(slot: 1, toServer: true)  // B is based on the old version -> must be refused
        w.drain()
        r.expect(w.serverField("n1", "prompt") == .string("A"), "first sequenced write (A) is kept")
        r.expect(isCommitted(w.terminals("c0", a)), "A was acknowledged")
        r.expect(isRejected(w.terminals("c1", b), "conflict"), "B was told explicitly: conflict")
        r.expect(w.slots[1].client?.view.nodes["n1"]?.config["prompt"] == .string("A"), "B's screen shows the winning value")
        r.expect(w.rec.stats["notice.conflictDetectedEarly"] >= 1, "B was warned as soon as A's write arrived")
        return finish("S2 same field concurrently (A first)", &w, &r)
    }

    static func s2_sameField_reverseOrder() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let a = w.userEdit(0, prompt("n1", "A"))!
        let b = w.userEdit(1, prompt("n1", "B"))!
        w.flush(slot: 1, toServer: true)
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(w.serverField("n1", "prompt") == .string("B"), "first sequenced write (B) is kept")
        r.expect(isCommitted(w.terminals("c1", b)) && isRejected(w.terminals("c0", a), "conflict"), "A told: conflict")
        return finish("S2b same field concurrently (B first)", &w, &r)
    }

    static func s2_overlappingPaths() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let a = w.userEdit(0, .setField("n1", .config(["model", "name"]), .string("gpt")))!
        let b = w.userEdit(1, .setField("n1", .config(["model"]), .map(["name": .string("claude")])))!
        let c = w.userEdit(1, .setField("n1", .config(["model", "temp"]), .int(3)))!  // sibling of a, pending behind b
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", a)), "child-path write committed first")
        r.expect(isRejected(w.terminals("c1", b), "conflict"), "ancestor-path write based before it is refused")
        r.expect(isCommitted(w.terminals("c1", c)), "sibling path (model.temp) does not overlap model.name: committed")
        r.expect(w.serverField("n1", "model") == .map(["name": .string("gpt"), "temp": .int(3)]),
                 "merged subtree: A's name + B's temp, B's stale parent write refused")
        return finish("S2c overlapping paths (model vs model.name)", &w, &r)
    }

    static func s2_reapplyAfterConflict() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(0, prompt("n1", "A"))
        let b = w.userEdit(1, prompt("n1", "B"))!
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(isRejected(w.terminals("c1", b), "conflict"), "B's first attempt refused")
        // The user sees A's value and deliberately re-applies theirs on top of it.
        let b2 = w.userEdit(1, prompt("n1", "B (after seeing A)"))!
        w.drain()
        r.expect(isCommitted(w.terminals("c1", b2)), "re-applied edit based on the latest version is accepted")
        r.expect(w.serverField("n1", "prompt") == .string("B (after seeing A)"), "final value is the deliberate overwrite")
        return finish("S2d re-apply after conflict notice", &w, &r)
    }

    // MARK: S3 - stale tab

    static func staleTab(snapshotEvery: Int, name: String) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3, snapshotEvery: snapshotEvery, nodes: 6)
        w.dropLink(2)  // tab C goes to sleep at version 0
        for i in 0..<20 {
            w.userEdit(i % 2, prompt("n1", "v\(i)"))
            w.userEdit(i % 2, .moveNode("n2", x: i, y: i))
            w.userEdit(i % 2, .setField("n2", .config(["code"]), .string("c\(i)")))
            w.drain()
        }
        let cPrompt = w.userEdit(2, prompt("n1", "stale C"))!
        let cTitle = w.userEdit(2, .setField("n3", .title, .string("C was here")))!
        let cMove = w.userEdit(2, .moveNode("n2", x: 999, y: 999))!
        let cDelete = w.userEdit(2, .removeNode("n2"))!  // n2's content was edited since C last looked
        w.restoreLink(2)
        w.drain()
        r.expect(w.serverField("n1", "prompt") == .string("v19"), "stale write did not overwrite newer prompt")
        r.expect(isRejected(w.terminals("c2", cPrompt), "conflict"), "stale prompt edit: explicit conflict notice")
        r.expect(isCommitted(w.terminals("c2", cTitle)), "stale tab's edit to an untouched node still applies")
        r.expect(isRejected(w.terminals("c2", cDelete), "conflict"), "stale delete of a content-modified node refused")
        r.expect(isCommitted(w.terminals("c2", cMove)), "stale move is last-writer-wins: accepted, never a conflict")
        r.expect(w.serverDoc?.nodes["n2"]?.x == 999, "the stale move is the last committed layout write, so it wins")
        r.expect(w.serverDoc?.nodes["n2"] != nil, "n2 still exists")
        r.expect(w.serverDoc?.nodes["n3"]?.title == "C was here", "C's non-conflicting edit is present")
        return finish(name, &w, &r)
    }

    static func s3_staleTab() -> ScenarioResult { staleTab(snapshotEvery: 1000, name: "S3 stale tab returns (log catch-up)") }
    static func s3_staleTabAfterCompaction() -> ScenarioResult {
        var res = staleTab(snapshotEvery: 5, name: "S3b stale tab returns (snapshot join)")
        res.expect(true, "ran with frequent snapshots")
        return res
    }

    // MARK: S4 - network drop / reconnect

    static func s4_dropBeforeServer() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let e1 = w.userEdit(0, prompt("n1", "one"))!
        w.dropLink(0)  // the submit dies with the connection
        let e2 = w.userEdit(0, prompt("n2", "two (offline)"))!
        let e3 = w.userEdit(0, .moveNode("n3", x: 1, y: 2))!
        w.userEdit(1, prompt("n4", "B meanwhile"))
        w.drain()
        r.expect(w.serverField("n1", "prompt") != .string("one"), "nothing from the dead link reached the server yet")
        w.restoreLink(0)
        w.drain()
        for e in [e1, e2, e3] { r.expect(w.terminals("c0", e).isEmpty == false, "op \(e) resolved after reconnect") }
        r.expect(w.serverField("n1", "prompt") == .string("one") && w.serverField("n2", "prompt") == .string("two (offline)"),
                 "all offline edits delivered after reconnect")
        return finish("S4 drop + reconnect during edits", &w, &r)
    }

    static func s4_ackLostRetransmit() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let e = w.userEdit(0, prompt("n1", "once"))!
        w.flush(slot: 0, toServer: true)  // committed on the server...
        w.dropLink(0)                      // ...but the ack / broadcast never reaches A
        r.expect(w.terminals("c0", e).isEmpty, "A has not been told anything yet")
        w.restoreLink(0)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", e)), "after reconnect A learns the op was saved")
        let entries = w.committedLog.filter { $0.client == "c0" && $0.cseq == e }
        r.expect(entries.count == 1, "retransmit did not double-commit (log has \(entries.count) entries)")
        return finish("S4b ack lost, retransmit is idempotent", &w, &r)
    }

    static func s4_lossyNetwork() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var cfg = SimConfig()
        cfg.clientCount = 3; cfg.dropRate = 0.4; cfg.dupRate = 0.2; cfg.maxDelay = 5
        cfg.disconnectRate = 0.05; cfg.steps = 400
        var w = World(seed: 99, cfg: cfg)
        for _ in 0..<cfg.steps { w.step() }
        r.expect(w.rec.stats["net.dropped.random"] > 50, "network really was lossy")
        return finish("S4c 40% loss + 20% dup + flapping links", &w, &r)
    }

    // MARK: S5 - client crash right after edits

    static func s5_crashJournaled() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2, volatile: false)
        let ids = (0..<3).map { w.userEdit(0, prompt("n\($0 + 1)", "A\($0)"))! }
        w.crashClient(0, restartAfter: 3)  // nothing delivered yet
        w.userEdit(1, prompt("n4", "B"))
        w.drain()
        r.expect(w.serverField("n1", "prompt") != .string("A0"), "crash happened before the server saw anything")
        w.restartClient(0)
        w.drain()
        for (k, c) in ids.enumerated() {
            r.expect(isCommitted(w.terminals("c0", c)), "journal replay: op A\(k) committed after restart")
        }
        return finish("S5 crash right after edits (write-ahead journal)", &w, &r)
    }

    static func s5_crashVolatile() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2, volatile: true)
        let ids = (0..<3).map { w.userEdit(0, prompt("n\($0 + 1)", "A\($0)"))! }
        w.crashClient(0, restartAfter: 3)
        w.userEdit(1, prompt("n4", "B"))
        w.drain()
        w.restartClient(0)
        w.drain()
        for (k, c) in ids.enumerated() {
            r.expect(w.terminals("c0", c) == [.lost], "volatile crash: op A\(k) explicitly reported lost/unsaved")
        }
        r.expect(w.serverField("n4", "prompt") == .string("B"), "other user's edit unaffected")
        r.expect(w.slots[0].client?.view.nodes["n4"]?.config["prompt"] == .string("B"), "restarted client caught up")
        return finish("S5b crash right after edits (volatile client)", &w, &r)
    }

    static func s5_crashAfterCommitBeforeAck() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2, volatile: true)
        let e1 = w.userEdit(0, prompt("n1", "saved"))!
        w.flush(slot: 0, toServer: true)  // server commits; ack still in flight
        let e2 = w.userEdit(0, prompt("n2", "never sent"))!
        w.crashClient(0, restartAfter: 2)
        w.drain()
        w.restartClient(0)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", e1)), "restart discovers op1 WAS saved")
        r.expect(w.terminals("c0", e2) == [.lost], "restart reports op2 as not saved")
        return finish("S5c crash after server commit, before ack", &w, &r)
    }

    // MARK: S6 - fast edits then immediate close/reload

    static func fastReload(volatile: Bool, name: String) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2, volatile: volatile)
        var ids: [Int] = []
        for i in 0..<20 {
            ids.append(w.userEdit(0, .moveNode("n1", x: i, y: i))!)
            ids.append(w.userEdit(0, prompt("n2", "draft \(i)"))!)
            if i == 9 { w.flush(slot: 0, toServer: true) }  // half of them reach the server
        }
        w.crashClient(0)       // reload / tab close immediately
        w.restartClient(0)
        w.drain()
        let outcomes = ids.map { w.terminals("c0", $0) }
        let committed = outcomes.filter { isCommitted($0) }.count
        let lost = outcomes.filter { $0 == [.lost] }.count
        r.expect(committed + lost == ids.count, "every op is either saved or reported lost (\(committed) saved, \(lost) lost)")
        if volatile {
            r.expect(lost > 0 && committed > 0, "volatile reload: some saved, the unsaved ones are reported")
            // Server processes in order, so what was saved is a prefix of what was typed.
            let firstLost = outcomes.firstIndex { $0 == [.lost] } ?? ids.count
            r.expect(outcomes[firstLost...].allSatisfy { $0 == [.lost] }, "saved ops form a prefix (no holes)")
        } else {
            r.expect(lost == 0, "journaled reload: nothing lost")
            r.expect(w.serverField("n2", "prompt") == .string("draft 19"), "last draft survived the reload")
        }
        return finish(name, &w, &r)
    }

    static func s6_fastEditsThenReload_journaled() -> ScenarioResult {
        fastReload(volatile: false, name: "S6 fast edits then reload (journaled)")
    }
    static func s6_fastEditsThenReload_volatile() -> ScenarioResult {
        fastReload(volatile: true, name: "S6b fast edits then reload (volatile)")
    }

    // MARK: S7 - delete vs edit / references

    static func s7_staleDeleteVsEdit() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let del = w.userEdit(0, .removeNode("n2"))!  // A has not seen B's edit
        w.userEdit(1, prompt("n2", "B worked on this"))
        w.flush(slot: 1, toServer: true)  // B's edit is sequenced first
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(isRejected(w.terminals("c0", del), "conflict"), "delete based on a stale view is refused with a notice")
        r.expect(w.serverField("n2", "prompt") == .string("B worked on this"), "B's work was not destroyed")
        let del2 = w.userEdit(0, .removeNode("n2"))!  // now A has seen it and deletes deliberately
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del2)) && w.serverDoc?.nodes["n2"] == nil, "deliberate delete after seeing the edit succeeds")
        return finish("S7 delete vs concurrent edit (edit first)", &w, &r)
    }

    static func s7_editAfterDelete() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let del = w.userEdit(0, .removeNode("n2"))!
        let edit = w.userEdit(1, prompt("n2", "edit on doomed node"))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)), "delete committed")
        r.expect(isRejected(w.terminals("c1", edit), "nodeDeleted"), "B's edit refused with an explicit nodeDeleted notice")
        r.expect(w.slots[1].client?.view.nodes["n2"] == nil, "B's screen no longer shows the node")
        return finish("S7b delete vs concurrent edit (delete first)", &w, &r)
    }

    static func s7_deleteReferencedNode() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(nodes: 5)
        w.userEdit(1, .setField("n3", .config(["inputs"]), .list([.ref(OutputRef(node: "n2", output: "text"))])))
        w.userEdit(1, .setField("n4", .config(["vars", "a"]), .ref(OutputRef(node: "n2", output: "text"))))
        w.userEdit(1, .addEdge(Edge(id: "e1", source: "n2", target: "n3")))
        w.drain()
        let del = w.userEdit(0, .removeNode("n2"))!
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)), "delete of a referenced node commits")
        let inputs = w.serverDoc?.nodes["n3"]?.config["inputs"]
        r.expect(inputs == .list([.brokenRef(OutputRef(node: "n2", output: "text"))]), "list reference became an explicit brokenRef")
        r.expect(w.serverField("n4", "vars") == .map(["a": .brokenRef(OutputRef(node: "n2", output: "text"))]), "nested reference became an explicit brokenRef")
        r.expect(w.serverDoc?.edges.isEmpty == true, "incident edge removed with the node")
        return finish("S7c delete a node whose output is referenced", &w, &r)
    }

    static func s7_refToConcurrentlyDeletedNode() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let del = w.userEdit(0, .removeNode("n2"))!
        let ref = w.userEdit(1, .setField("n3", .config(["inputs"]), .ref(OutputRef(node: "n2", output: "out"))))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)), "delete committed")
        r.expect(isRejected(w.terminals("c1", ref), "danglingReference"), "new reference to the deleted node refused (no silent dangling ref)")
        // And the other order: the reference lands first, then the delete turns it into a broken marker.
        let ref2 = w.userEdit(1, .setField("n3", .config(["inputs"]), .ref(OutputRef(node: "n1", output: "out"))))!
        let del2 = w.userEdit(0, .removeNode("n1"))!
        w.flush(slot: 1, toServer: true)
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c1", ref2)), "reference committed first")
        r.expect(isCommitted(w.terminals("c0", del2)) || isRejected(w.terminals("c0", del2), "conflict"), "delete resolved explicitly")
        return finish("S7d reference to a concurrently deleted node", &w, &r)
    }

    static func s7_doubleDelete() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let a = w.userEdit(0, .removeNode("n2"))!
        let b = w.userEdit(1, .removeNode("n2"))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", a)) && isRejected(w.terminals("c1", b), "nodeDeleted"), "second delete gets an explicit 'already deleted'")
        return finish("S7e both users delete the same node", &w, &r)
    }

    static func s7_edgeToDeletedNode() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let del = w.userEdit(0, .removeNode("n2"))!
        let edge = w.userEdit(1, .addEdge(Edge(id: "e9", source: "n1", target: "n2")))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)) && isRejected(w.terminals("c1", edge), "nodeDeleted"), "edge to a deleted node refused")
        return finish("S7f edge to a node deleted concurrently", &w, &r)
    }

    // MARK: S8 - server crash

    static func s8_serverCrashKeepsAcked() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(snapshotEvery: 4)
        var acked: [Int] = []
        for i in 0..<10 {
            acked.append(w.userEdit(i % 2, prompt("n\(i % 4 + 1)", "x\(i)"))!)
            w.drain()
        }
        let before = w.serverSeq!
        w.crashServer(restartAfter: 3)
        w.userEdit(0, prompt("n1", "while server down"))
        w.restartServer()
        w.drain()
        r.expect(w.serverSeq! >= before, "recovered server keeps all \(before) acked entries")
        return finish("S8 server crash/restart keeps acked ops", &w, &r)
    }

    static func s8_serverCrashAfterLogBeforeAck() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let e = w.userEdit(0, prompt("n1", "logged, ack lost"))!
        w.flush(slot: 0, toServer: true)  // committed + broadcast queued
        w.crashServer(restartAfter: 2)    // broadcast dies with the server
        r.expect(w.terminals("c0", e).isEmpty, "client was never told")
        w.restartServer()
        w.settle()
        r.expect(isCommitted(w.terminals("c0", e)), "after restart the client learns its op is saved")
        r.expect(w.serverField("n1", "prompt") == .string("logged, ack lost"), "op survived the crash")
        return finish("S8b crash after log append, before ack", &w, &r)
    }

    // MARK: S9 - same-value writes are not conflicts

    static func s9_thirtyUsersSameValue() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 30, nodes: 3)
        var cseqs: [Int] = []
        for i in 0..<30 { cseqs.append(w.userEdit(i, .setField("n1", .config(["prompt"]), .string("agreed")), sameValue: true)!) }
        for i in 0..<30 { w.flush(slot: i, toServer: true) }  // all 30 are based on the same old version
        w.drain()
        r.expect((0..<30).allSatisfy { isCommitted(w.terminals("c\($0)", cseqs[$0])) }, "all 30 writes acknowledged")
        r.expect(w.serverField("n1", "prompt") == .string("agreed"), "final value is the agreed value")
        r.expect(w.rec.stats["op.rejected"] == 0, "zero rejections")
        r.expect(w.rec.stats["notice.conflictDetectedEarly"] == 0, "zero conflict notices, not even early warnings")
        return finish("S9 30 users write the same value to the same field", &w, &r)
    }

    static func s9_staleSameValueIsNoConflict() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let a = w.userEdit(0, prompt("n1", "X"))!
        let t = w.userEdit(1, .setField("n1", .title, .string("T")))!
        let b = w.userEdit(1, prompt("n1", "X"))!  // stale (A's write is newer) but identical
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", a)) && isCommitted(w.terminals("c1", b)) && isCommitted(w.terminals("c1", t)),
                 "stale write of the current value is acknowledged")
        // Afterwards a client that saw only A's write may still write over B's identical write without conflict.
        let c = w.userEdit(0, prompt("n1", "Y"))!
        w.drain()
        r.expect(isCommitted(w.terminals("c0", c)), "a later write based on A's version is not blocked by B's no-op")
        return finish("S9b stale same-value write is acknowledged", &w, &r)
    }

    static func s9_sameValueDifferentOneStillConflicts() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3)
        let a = w.userEdit(0, prompt("n1", "same"))!
        let b = w.userEdit(1, prompt("n1", "same"))!
        let c = w.userEdit(2, prompt("n1", "different"))!
        for i in 0..<3 { w.flush(slot: i, toServer: true) }
        w.drain()
        r.expect(isCommitted(w.terminals("c0", a)) && isCommitted(w.terminals("c1", b)), "same-value writers both succeed")
        r.expect(isRejected(w.terminals("c2", c), "conflict"), "the different value is rejected with a conflict notice")
        r.expect(w.serverField("n1", "prompt") == .string("same"), "the winning value stays")
        return finish("S9c mixed same/different values on one field", &w, &r)
    }

    /// Regression for the TLA+ counterexample (P2 violation in 3 steps): an accepted equal-value write must be a pure no-op
    /// for conflict tracking. If it took the register's stamp, the same client's NEXT stale write would be exempt ("last
    /// writer is me") and silently overwrite a value it never saw.
    static func s9_equalValueWriteDoesNotLaunderLaterWrite() -> ScenarioResult { equalValueTrace(defects: []) }

    /// `defects` lets the mutation test prove the scenario can fail.
    public static func equalValueTrace(defects: ProtocolDefects) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2, defects: defects)
        let first = w.userEdit(0, prompt("n1", "v1"))!    // c1: f1 := v1   (base 0)
        let second = w.userEdit(0, prompt("n1", "v2"))!   // c1: f1 := v2   (base 0, queued behind the first POST)
        let other = w.userEdit(1, prompt("n1", "v1"))!    // c2: f1 := v1   (base 0), sequenced FIRST
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c1", other)), "c2's write is committed first")
        r.expect(isCommitted(w.terminals("c0", first)), "c1's first write equals the current value: accepted as a no-op")
        r.expect(isRejected(w.terminals("c0", second), "conflict"), "c1's second write is stale against c2's write and must be refused")
        r.expect(w.serverField("n1", "prompt") == .string("v1"), "c2's value survives; nothing was silently overwritten")
        return finish("S9d equal-value write does not launder the next stale write (TLA+ counterexample)", &w, &r)
    }

    // MARK: S10 - list items

    static func listItems(_ w: World, _ node: NodeID) -> [String] {
        if case .items(let xs)? = w.serverField(node, "outs") { return xs.map(\.id) }
        return []
    }
    static func ins(_ node: NodeID, _ id: String, after: String? = nil) -> Op {
        .insertItem(node, path: ["outs"], item: Item(id: id, value: .string("v-\(id)")), after: after)
    }

    static func s10_itemInsertsNeverConflict() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3)
        let ops = [w.userEdit(0, ins("n1", "a"))!, w.userEdit(1, ins("n1", "b"))!, w.userEdit(2, ins("n1", "c"))!]
        for i in 0..<3 { w.flush(slot: i, toServer: true) }
        w.drain()
        r.expect((0..<3).allSatisfy { isCommitted(w.terminals("c\($0)", ops[$0])) }, "three users add three different items concurrently: all committed")
        r.expect(Set(listItems(w, "n1")) == ["a", "b", "c"], "all three items are in the list")
        r.expect(w.rec.stats["op.rejected"] == 0, "no conflicts")
        // Same anchor concurrently: both land, in server order.
        let x = w.userEdit(0, ins("n1", "x", after: "a"))!
        let y = w.userEdit(1, ins("n1", "y", after: "a"))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", x)) && isCommitted(w.terminals("c1", y)), "two inserts after the same anchor both commit")
        return finish("S10 different list items never conflict", &w, &r)
    }

    static func s10_itemRemovesAndUpdates() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2)
        for (i, id) in ["a", "b", "c"].enumerated() { w.userEdit(0, ins("n1", id, after: i == 0 ? nil : ["a", "b", "c"][i - 1])) }
        w.drain()
        let upd = w.userEdit(0, .updateItem("n1", path: ["outs"], id: "a", value: .string("A!")))!
        let rem = w.userEdit(1, .removeItem("n1", path: ["outs"], id: "b"))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", upd)) && isCommitted(w.terminals("c1", rem)), "editing one item while another is removed: both fine")
        r.expect(listItems(w, "n1") == ["a", "c"], "item b removed, a and c remain")
        // Same item edited concurrently with different values: second loses with a conflict.
        let u1 = w.userEdit(0, .updateItem("n1", path: ["outs"], id: "c", value: .string("from A")))!
        let u2 = w.userEdit(1, .updateItem("n1", path: ["outs"], id: "c", value: .string("from B")))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", u1)) && isRejected(w.terminals("c1", u2), "conflict"), "same item, different values: one conflict notice")
        // Editing an item someone removed.
        let rem2 = w.userEdit(0, .removeItem("n1", path: ["outs"], id: "a"))!
        let upd2 = w.userEdit(1, .updateItem("n1", path: ["outs"], id: "a", value: .string("late")))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", rem2)) && isRejected(w.terminals("c1", upd2), "itemDeleted"), "editing a removed item: explicit itemDeleted")
        return finish("S10b item remove/update interplay", &w, &r)
    }

    static func s10_staleListReplaceVsInsert() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2)
        w.userEdit(0, ins("n1", "a"))
        w.drain()
        let rep = w.userEdit(1, .setField("n1", .config(["outs"]), .items([Item(id: "z", value: .int(1))])))!  // replaces the list wholesale
        let add = w.userEdit(0, ins("n1", "b", after: "a"))!
        w.flush(slot: 0, toServer: true)  // b is inserted first
        w.flush(slot: 1, toServer: true)  // B's replacement is based before b: it would destroy b
        w.drain()
        r.expect(isCommitted(w.terminals("c0", add)), "insert committed")
        r.expect(isRejected(w.terminals("c1", rep), "conflict"), "stale whole-list replace refused instead of silently dropping the new item")
        r.expect(Set(listItems(w, "n1")) == ["a", "b"], "list intact")
        return finish("S10c stale whole-list replace vs item insert", &w, &r)
    }

    static func s10_removeAlreadyRemovedItem() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2)
        w.userEdit(0, ins("n1", "a"))
        w.drain()
        let a = w.userEdit(0, .removeItem("n1", path: ["outs"], id: "a"))!
        let b = w.userEdit(1, .removeItem("n1", path: ["outs"], id: "a"))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", a)) && isCommitted(w.terminals("c1", b)), "both removals acknowledged (same end state, not a conflict)")
        r.expect(listItems(w, "n1").isEmpty, "item is gone")
        return finish("S10d two users remove the same item", &w, &r)
    }

    // MARK: S11 - layout is last-writer-wins

    static func s11_positionIsLastWriterWins() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3)
        let ids = (0..<3).map { w.userEdit($0, .moveNode("n1", x: 100 + $0, y: 200 + $0))! }
        w.flush(slot: 2, toServer: true)
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect((0..<3).allSatisfy { isCommitted(w.terminals("c\($0)", ids[$0])) }, "concurrent moves of one node are all acknowledged")
        r.expect(w.serverDoc?.nodes["n1"]?.x == 101, "final position is the last write in server order (c1)")
        r.expect(w.rec.stats["op.rejected"] == 0 && w.rec.stats["notice.conflictDetectedEarly"] == 0, "no conflict notices for layout")
        return finish("S11 concurrent moves: last writer wins", &w, &r)
    }

    static func s11_moveDoesNotBlockDelete() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2)
        let del = w.userEdit(0, .removeNode("n2"))!
        w.userEdit(1, .moveNode("n2", x: 5, y: 5))
        w.flush(slot: 1, toServer: true)  // the drag lands first
        w.flush(slot: 0, toServer: true)  // the delete is based before the drag
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)), "deleting a node someone merely dragged is allowed (no content lost)")
        return finish("S11b a drag does not block a delete", &w, &r)
    }

    static func s11_moveOfDeletedNode() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 2)
        let del = w.userEdit(0, .removeNode("n2"))!
        let mv = w.userEdit(1, .moveNode("n2", x: 5, y: 5))!
        w.flush(slot: 0, toServer: true)
        w.flush(slot: 1, toServer: true)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)) && isRejected(w.terminals("c1", mv), "nodeDeleted"), "moving a deleted node: explicit nodeDeleted")
        return finish("S11c move of a node deleted concurrently", &w, &r)
    }

    // MARK: S12 - restoring a deleted node (protocol 1.6)

    /// What an undo sends: the node as client `i` sees it now, with its edges.
    static func restoreOp(_ w: World, _ i: Int, _ id: NodeID) -> Op {
        let v = w.slots[i].client!.view
        return .restoreNode(v.nodes[id]!, edges: v.edges.values.filter { $0.source == id || $0.target == id }.sorted { $0.id < $1.id })
    }
    static func ref(_ n: NodeID) -> Value { .ref(OutputRef(node: n, output: "out")) }
    static func broken(_ n: NodeID) -> Value { .brokenRef(OutputRef(node: n, output: "out")) }

    static func s12_undoOwnDelete() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(1, .setField("n3", .config(["inputs"]), .list([ref("n2"), ref("n1")])))
        w.userEdit(1, .setField("n4", .config(["vars", "a"]), ref("n2")))
        w.userEdit(1, .addEdge(Edge(id: "e1", source: "n2", target: "n3")))
        w.userEdit(1, .addEdge(Edge(id: "e2", source: "n1", target: "n2")))
        w.drain()
        let undo = restoreOp(w, 0, "n2")
        let del = w.userEdit(0, .removeNode("n2"))!
        w.drain()
        r.expect(w.serverField("n3", "inputs") == .list([broken("n2"), ref("n1")]), "the delete broke the references")
        let res = w.userEdit(0, undo)!
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)) && isCommitted(w.terminals("c0", res)), "delete and its undo both commit")
        let doc = w.serverDoc!
        r.expect(doc.nodes["n2"] != nil && doc.deletedNodes["n2"] == nil, "the node is back and no longer tombstoned")
        r.expect(Set(doc.edges.keys) == ["e1", "e2"] && doc.deletedEdges.isEmpty, "both edges are back with their ids")
        r.expect(w.serverField("n3", "inputs") == .list([ref("n2"), ref("n1")]), "list reference is live again")
        r.expect(w.serverField("n4", "vars") == .map(["a": ref("n2")]), "nested reference is live again")
        let again = w.userEdit(1, prompt("n2", "after undo"))!
        w.drain()
        r.expect(isCommitted(w.terminals("c1", again)), "the restored node can be edited by someone who saw the restore")
        return finish("S12 undo of one's own delete restores node, edges and references", &w, &r)
    }

    /// A writer whose base predates the restore must not overwrite the restored content. Fails with `restoreSkipsStamps`.
    public static func s12_staleWriteAfterRestore(defects: ProtocolDefects) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3, defects: defects)
        w.dropLink(2)  // C is offline (a stale tab) for all of this
        w.userEdit(1, prompt("n2", "B's work"))
        w.drain()
        let undo = restoreOp(w, 0, "n2")
        w.userEdit(0, .removeNode("n2"))
        w.drain()
        let res = w.userEdit(0, undo)!
        w.drain()
        let late = w.userEdit(2, prompt("n2", "C's stale draft"))!  // based on what C saw before B's write
        w.restoreLink(2)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", res)), "restore committed")
        r.expect(isRejected(w.terminals("c2", late), "conflict"), "C never saw B's write nor the restore: its write is a conflict")
        r.expect(w.serverField("n2", "prompt") == .string("B's work"), "B's work came back with the node and survives")
        return finish("S12b stale write after a restore is a conflict", &w, &r)
    }

    /// The other end of an edge was deleted meanwhile: the edge stays deleted, the node comes back. Fails with
    /// `restoreIgnoresEndpoints`.
    public static func s12_restoreSkipsEdgeToDeletedNode(defects: ProtocolDefects) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(defects: defects)
        w.userEdit(0, .addEdge(Edge(id: "e1", source: "n2", target: "n3")))
        w.userEdit(0, .addEdge(Edge(id: "e2", source: "n1", target: "n2")))
        w.userEdit(0, .setField("n2", .config(["inputs"]), ref("n3")))
        w.drain()
        let undo = restoreOp(w, 0, "n2")
        w.userEdit(0, .removeNode("n2"))
        w.drain()
        w.userEdit(1, .removeNode("n3"))
        w.drain()
        let res = w.userEdit(0, undo)!
        w.drain()
        r.expect(isCommitted(w.terminals("c0", res)), "restore commits although one edge cannot come back")
        r.expect(Set(w.serverDoc!.edges.keys) == ["e2"], "only the edge whose other end still exists is back")
        r.expect(w.serverDoc!.deletedEdges["e1"] != nil, "the other edge stays deleted")
        r.expect(w.serverField("n2", "inputs") == broken("n3"), "the restored node's reference to the deleted node is broken")
        return finish("S12c restore skips an edge whose other end was deleted", &w, &r)
    }

    /// Undo is only of one's own operations. Fails with `anyoneRestores` (I7).
    public static func s12_onlyTheDeleterRestores(defects: ProtocolDefects) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(defects: defects)
        let undo = restoreOp(w, 0, "n2")
        w.userEdit(1, .removeNode("n2"))
        w.drain()
        if defects.isEmpty {
            r.expect(w.userEdit(0, undo) == nil && w.rec.localRefusals.last.map { $0 == ("c0", "notDeleter") } == true,
                     "restoring someone else's delete is refused (locally, as the server would)")
        }
        // A delete that lost the race: A's delete and its undo are sent while B's delete is sequenced first.
        let undo3 = restoreOp(w, 0, "n3")
        let mine = w.userEdit(0, .removeNode("n3"))!
        let res = w.userEdit(0, undo3)!
        w.userEdit(1, .removeNode("n3"))
        w.flush(slot: 1, toServer: true)
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(isRejected(w.terminals("c0", mine), "nodeDeleted"), "A's delete lost the race")
        r.expect(isRejected(w.terminals("c0", res), "notDeleter"), "A's undo would undo B's delete: notDeleter")
        r.expect(w.serverDoc!.nodes["n3"] == nil && w.serverDoc!.nodes["n2"] == nil, "both nodes stay deleted")
        return finish("S12d only the deleter may restore", &w, &r)
    }

    static func s12_restoreConflictsWithUnseenCascade() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(1, .setField("n4", .config(["inputs"]), .list([ref("n2"), ref("n3")])))
        w.drain()
        let undo = restoreOp(w, 0, "n2")
        w.userEdit(0, .removeNode("n2"))
        w.drain()
        w.userEdit(1, .removeNode("n3"))  // rewrites n4.inputs again, concurrently with A's undo
        let stale = w.userEdit(0, undo)!
        w.flush(slot: 1, toServer: true)  // B's delete is sequenced first
        w.flush(slot: 0, toServer: true)
        w.drain()
        r.expect(isRejected(w.terminals("c0", stale), "conflict"), "the restore would rewrite a field someone else wrote after its base")
        let fresh = w.userEdit(0, undo)!
        w.drain()
        r.expect(isCommitted(w.terminals("c0", fresh)), "re-applied on the latest version it commits")
        r.expect(w.serverField("n4", "inputs") == .list([ref("n2"), broken("n3")]), "only the restored node's reference is live again")
        return finish("S12e restore vs an unseen write to a field it rewrites", &w, &r)
    }

    static func s12_restoreBeforeTheDeleteIsConfirmed() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(0, .addEdge(Edge(id: "e1", source: "n2", target: "n3")))
        w.drain()
        let undo = restoreOp(w, 0, "n2")
        let del = w.userEdit(0, .removeNode("n2"))!
        let res = w.userEdit(0, undo)!  // undo pressed before the delete reached the server
        w.drain()
        r.expect(isCommitted(w.terminals("c0", del)) && isCommitted(w.terminals("c0", res)), "delete and undo in one batch both commit")
        r.expect(w.serverDoc!.nodes["n2"] != nil && w.serverDoc!.edges["e1"] != nil, "node and edge are back")
        return finish("S12f undo before the delete is confirmed", &w, &r)
    }

    static func s12_oldClientNeverSeesARestore() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3, legacy: [1, 2])
        let undo = restoreOp(w, 0, "n2")
        w.userEdit(0, .removeNode("n2"))
        w.drain()
        w.dropLink(2)  // c2 is offline while the restore happens: its catch-up range contains it
        let res = w.userEdit(0, undo)!
        w.drain()
        w.restoreLink(2)
        r.expect(isCommitted(w.terminals("c0", res)), "restore committed")
        r.expect(w.rec.stats["sync.legacyStreamEnded"] >= 1, "the old client's live stream was ended instead of carrying the restore")
        let ok = w.settle()
        r.expect(ok && w.slots[1].client!.view.nodes["n2"] != nil && w.slots[2].client!.view.nodes["n2"] != nil,
                 "both old clients caught up with a snapshot that has the node back")
        return finish("S12g a client older than 1.6 never receives a restoreNode commit", &w, &r)
    }

    // MARK: S13 - document-level registers (protocol 1.7)

    static let envPath = ["environment_variables"]
    static func envVar(_ id: String, _ value: String) -> Item {
        Item(id: id, value: .map(["id": .string(id), "name": .string(id), "value": .string(value), "value_type": .string("string")]))
    }
    static func appVars(_ d: Document?) -> [Item] {
        if case .items(let xs)? = d?.app[envPath[0]] { return xs }
        return []
    }

    static func s13_differentVariablesNeverConflict() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        w.userEdit(0, .insertItem(Document.appNode, path: envPath, item: envVar("a", "1"), after: nil))
        w.userEdit(0, .insertItem(Document.appNode, path: envPath, item: envVar("b", "1"), after: "a"))
        w.drain()
        let x = w.userEdit(0, .updateItem(Document.appNode, path: envPath, id: "a", value: envVar("a", "A's").value))!
        let y = w.userEdit(1, .updateItem(Document.appNode, path: envPath, id: "b", value: envVar("b", "B's").value))!
        let z = w.userEdit(1, .setField(Document.appNode, .config(["features", "opening_statement"]), .string("hi")))!
        w.drain()
        r.expect(isCommitted(w.terminals("c0", x)) && isCommitted(w.terminals("c1", y)) && isCommitted(w.terminals("c1", z)),
                 "edits of different variables and of a feature all commit")
        r.expect(appVars(w.serverDoc) == [envVar("a", "A's"), envVar("b", "B's")], "both variables carry their edit, in order")
        return finish("S13 concurrent edits of different variables never conflict", &w, &r)
    }

    /// A stale edit of a variable someone else changed is a conflict; the newer value is kept. Fails with `appSkipsStamps`.
    public static func s13_staleVariableEditIsAConflict(defects: ProtocolDefects) -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(defects: defects)
        w.userEdit(0, .insertItem(Document.appNode, path: envPath, item: envVar("a", "1"), after: nil))
        w.drain()
        w.dropLink(1)  // B edits offline (a stale tab)
        let mine = w.userEdit(0, .updateItem(Document.appNode, path: envPath, id: "a", value: envVar("a", "A's").value))!
        let feat = w.userEdit(0, .setField(Document.appNode, .config(["features", "x"]), .int(1)))!
        w.drain()
        let stale = w.userEdit(1, .updateItem(Document.appNode, path: envPath, id: "a", value: envVar("a", "B's").value))!
        let staleFeat = w.userEdit(1, .setField(Document.appNode, .config(["features"]), .map([:])))!
        let same = w.userEdit(1, .updateItem(Document.appNode, path: envPath, id: "a", value: envVar("a", "A's").value))
        w.restoreLink(1)
        w.drain()
        r.expect(isCommitted(w.terminals("c0", mine)) && isCommitted(w.terminals("c0", feat)), "A's edits committed")
        r.expect(isRejected(w.terminals("c1", stale), "conflict"), "B never saw A's edit: conflict")
        r.expect(isRejected(w.terminals("c1", staleFeat), "conflict"), "a stale whole-map write conflicts with a newer member write")
        r.expect(same == nil || isCommitted(w.terminals("c1", same!)) || isRejected(w.terminals("c1", same!), "conflict"),
                 "a write of the current value is never lost")
        r.expect(appVars(w.serverDoc) == [envVar("a", "A's")], "A's value is kept")
        return finish("S13b a stale variable edit is a conflict", &w, &r)
    }

    static func s13_appTakesOnlyRegisterWrites() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world()
        let app = Document.appNode
        let refused: [Op] = [
            .setField(app, .title, .string("t")), .moveNode(app, x: 1, y: 1), .removeNode(app),
            .addNode(Node(id: "$x", type: "llm")), .addEdge(Edge(id: "e9", source: "n1", target: app)),
            .setField(app, .config(["features", "r"]), ref("n1")),
            .insertItem(app, path: envPath, item: Item(id: "v", value: .map(["r": ref("n1")])), after: nil),
        ]
        for op in refused {
            r.expect(w.userEdit(0, op) == nil && w.rec.localRefusals.last.map { $0 == ("c0", "invalid") } == true, "refused: \(op)")
        }
        r.expect(w.userEdit(0, .setField(app, .config(["features", "a"]), .string("ok"))) != nil, "a config write is accepted")
        w.drain()
        r.expect(w.serverDoc!.app["features"] == .map(["a": .string("ok")]), "and committed")
        return finish("S13c $app takes config and item writes only", &w, &r)
    }

    static func s13_oldClientsNeverSeeAppWrites() -> ScenarioResult {
        var r = ScenarioResult(name: "")
        var w = world(clients: 3, legacy: [1], legacy16: [2])
        w.dropLink(2)  // c2 (1.6) is offline while the variable is added: its catch-up range contains the write
        let res = w.userEdit(0, .insertItem(Document.appNode, path: envPath, item: envVar("a", "1"), after: nil))!
        w.drain()
        w.restoreLink(2)
        r.expect(isCommitted(w.terminals("c0", res)), "variable committed")
        r.expect(w.rec.stats["sync.legacyStreamEnded"] >= 1, "the 1.5 client's live stream was ended instead of carrying the write")
        let ok = w.settle()
        r.expect(ok && appVars(w.slots[1].client!.view) == [envVar("a", "1")] && appVars(w.slots[2].client!.view) == [envVar("a", "1")],
                 "both old clients caught up with a snapshot that has the variable")
        return finish("S13d clients older than 1.7 never receive a $app commit", &w, &r)
    }
}
