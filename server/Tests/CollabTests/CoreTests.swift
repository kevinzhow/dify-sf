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
        #expect(throws: (any Error).self) { try WireJSON.decode(Value.self, from: "1.5") }
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
            .nodeDeleted("n"), .nodeNotFound("n"), .nodeExists("n"), .edgeNotFound("e"), .edgeExists("e"), .duplicateEdge("e"),
            .danglingReference("n"), .itemNotFound("i"), .itemDeleted("i"), .itemExists("i"), .invalid("why"), .notCommitted, .clientIdInUse,
        ]
        for r in reasons { try roundTrip(r) }
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
