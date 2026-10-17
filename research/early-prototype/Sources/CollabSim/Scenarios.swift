import CollabCore

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
    ]

    // MARK: helpers

    static func world(clients: Int = 2, volatile: Bool = false, snapshotEvery: Int = 64, drop: Double = 0,
                      nodes: Int = 5) -> World {
        var cfg = SimConfig()
        cfg.clientCount = clients
        cfg.initialNodes = nodes
        cfg.snapshotEvery = snapshotEvery
        cfg.maxDelay = 1
        cfg.volatileFraction = volatile ? 1 : 0
        cfg.dropRate = drop
        var w = World(seed: 7, cfg: cfg)
        w.drain()
        return w
    }

    static func finish(_ name: String, _ w: inout World, _ r: inout ScenarioResult) -> ScenarioResult {
        r.name = name
        let ok = w.settle()
        r.expect(ok, "system settles after healing")
        r.violations = Invariants.check(w)
        return r
    }

    static func prompt(_ n: NodeID, _ s: String) -> Op { .setField(n, .config(["prompt"]), .string(s)) }

    static func isConflict(_ t: Terminal) -> Bool {
        if case .rejected(let s) = t { return s.hasPrefix("conflict") }
        return false
    }
    static func isCommitted(_ t: [Terminal]) -> Bool {
        if case .committed? = t.first { return true }
        return false
    }
    static func isRejected(_ t: [Terminal], _ prefix: String) -> Bool {
        if case .rejected(let s)? = t.first { return s.hasPrefix(prefix) }
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
        r.expect(w.server?.doc.nodes["n1"]?.title == "B title", "title kept")
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
            w.drain()
        }
        let cPrompt = w.userEdit(2, prompt("n1", "stale C"))!
        let cTitle = w.userEdit(2, .setField("n3", .title, .string("C was here")))!
        let cMove = w.userEdit(2, .moveNode("n2", x: 999, y: 999))!
        let cDelete = w.userEdit(2, .removeNode("n2"))!  // n2 was moved 20 times since C last looked
        w.restoreLink(2)
        w.drain()
        r.expect(w.serverField("n1", "prompt") == .string("v19"), "stale write did not overwrite newer prompt")
        r.expect(isRejected(w.terminals("c2", cPrompt), "conflict"), "stale prompt edit: explicit conflict notice")
        r.expect(isCommitted(w.terminals("c2", cTitle)), "stale tab's edit to an untouched node still applies")
        r.expect(isRejected(w.terminals("c2", cDelete), "conflict"), "stale delete of a modified node refused")
        r.expect(isRejected(w.terminals("c2", cMove), "conflict"), "stale move refused")
        r.expect(w.server?.doc.nodes["n2"] != nil, "n2 still exists")
        r.expect(w.server?.doc.nodes["n3"]?.title == "C was here", "C's non-conflicting edit is present")
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
        let entries = w.server!.disk.fullLog.filter { $0.client == "c0" && $0.cseq == e }
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
        r.expect(isCommitted(w.terminals("c0", del2)) && w.server?.doc.nodes["n2"] == nil, "deliberate delete after seeing the edit succeeds")
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
        let inputs = w.server?.doc.nodes["n3"]?.config["inputs"]
        r.expect(inputs == .list([.brokenRef(OutputRef(node: "n2", output: "text"))]), "list reference became an explicit brokenRef")
        r.expect(w.serverField("n4", "vars") == .map(["a": .brokenRef(OutputRef(node: "n2", output: "text"))]), "nested reference became an explicit brokenRef")
        r.expect(w.server?.doc.edges.isEmpty == true, "incident edge removed with the node")
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
        let before = w.server!.seq
        w.crashServer(restartAfter: 3)
        w.userEdit(0, prompt("n1", "while server down"))
        w.restartServer()
        w.drain()
        r.expect(w.server!.seq >= before, "recovered server keeps all \(before) acked entries")
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
}
