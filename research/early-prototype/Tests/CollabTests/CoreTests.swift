import Testing
@testable import CollabCore

private func node(_ id: String, _ cfg: [String: Value] = [:]) -> Node { Node(id: id, type: "llm", config: cfg) }
private func stamp(_ seq: Int, _ c: String) -> Stamp { Stamp(seq: seq, client: c) }
private func set(_ n: String, _ path: [String], _ v: String) -> Op { .setField(n, .config(path), .string(v)) }

@Suite("Document rules")
struct DocumentRuleTests {
    @Test func staleWriteIsRefusedNewerValueKept() throws {
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["prompt"], "new"), at: stamp(5, "bob"))
        // Alice wrote against version 3 (before bob's seq 5): refused.
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["prompt"], "old"), base: 3, by: "alice") }
        // Based on version 5 or later: fine.
        try d.validate(set("a", ["prompt"], "ok"), base: 5, by: "alice")
        // Bob himself is never in conflict with his own earlier write.
        try d.validate(set("a", ["prompt"], "again"), base: 3, by: "bob")
        // Different field: never a conflict.
        try d.validate(set("a", ["code"], "x"), base: 3, by: "alice")
    }

    @Test func overlappingPathsConflictSiblingsDoNot() throws {
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["model", "name"], "x"), at: stamp(2, "bob"))
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["model"], "y"), base: 1, by: "alice") }
        #expect(throws: RejectReason.self) { try d.validate(set("a", ["model", "name", "deep"], "y"), base: 1, by: "alice") }
        try d.validate(set("a", ["model", "temp"], "y"), base: 1, by: "alice")
    }

    @Test func deleteMarksReferencesBrokenAndRemovesEdges() {
        var d = Document(nodes: [
            node("a"), node("b", ["in": .ref(OutputRef(node: "a", output: "o")),
                                  "deep": .map(["l": .list([.ref(OutputRef(node: "a", output: "o")), .int(1)])])]),
        ], edges: [Edge(id: "e", source: "a", target: "b")])
        d.apply(.removeNode("a"), at: stamp(1, "x"))
        #expect(d.nodes["b"]?.config["in"] == .brokenRef(OutputRef(node: "a", output: "o")))
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

    @Test func codableRoundTrip() throws {
        // Wire/disk formats come for free; make sure the enums with payloads survive.
        let entry = LogEntry(seq: 3, client: "c", cseq: 1, base: 2,
                             op: .addNode(Node(id: "n", type: "llm", config: ["r": .ref(OutputRef(node: "m", output: "o"))])))
        let data = try JSONCoder.encode(entry)
        #expect(try JSONCoder.decode(LogEntry.self, data) == entry)
        var d = Document(nodes: [node("a")])
        d.apply(set("a", ["p"], "v"), at: stamp(1, "c"))
        #expect(try JSONCoder.decode(Document.self, try JSONCoder.encode(d)) == d)
    }
}

@Suite("Server")
struct ServerTests {
    private func hello(_ s: inout Server, _ c: String, from: Int? = nil) {
        _ = s.handle(.hello(Hello(client: c, lastSeq: from, willResendFrom: 1)))
    }

    @Test func ackedOpIsInDurableLogBeforeBroadcast() {
        var s = Server(initial: Document(nodes: [node("a")]))
        hello(&s, "c")
        let out = s.handle(.submit(ClientOp(client: "c", cseq: 1, base: 0, op: set("a", ["p"], "v"))))
        #expect(s.disk.tail.count == 1)
        #expect(out.count == 1)
        // Crash: rebuild from disk only. State must be identical.
        let r = Server(disk: s.disk)
        #expect(r.doc == s.doc && r.seq == s.seq)
    }

    @Test func retransmitIsIdempotent() {
        var s = Server(initial: Document(nodes: [node("a")]))
        hello(&s, "c")
        let op = ClientOp(client: "c", cseq: 1, base: 0, op: set("a", ["p"], "v"))
        _ = s.handle(.submit(op))
        let again = s.handle(.submit(op))
        #expect(s.seq == 1)
        #expect(again == [Outbound(to: "c", message: .ack(cseq: 1, seq: 1))])
    }

    @Test func outOfOrderCseqIsIgnoredUntilGapFills() {
        var s = Server(initial: Document(nodes: [node("a")]))
        hello(&s, "c")
        #expect(s.handle(.submit(ClientOp(client: "c", cseq: 2, base: 0, op: set("a", ["p"], "2")))).isEmpty)
        #expect(s.seq == 0)
        _ = s.handle(.submit(ClientOp(client: "c", cseq: 1, base: 0, op: set("a", ["p"], "1"))))
        _ = s.handle(.submit(ClientOp(client: "c", cseq: 2, base: 0, op: set("a", ["p"], "2"))))
        #expect(s.doc.nodes["a"]?.config["p"] == .string("2"))
    }

    @Test func submitWithoutSessionAsksForHello() {
        var s = Server(initial: Document(nodes: [node("a")]))
        let out = s.handle(.submit(ClientOp(client: "c", cseq: 1, base: 0, op: set("a", ["p"], "v"))))
        #expect(out == [Outbound(to: "c", message: .resyncRequired)])
    }

    @Test func snapshotCompactionKeepsDedupIndexAndJoinWorks() {
        var s = Server(initial: Document(nodes: [node("a")]), snapshotEvery: 3)
        hello(&s, "c")
        for i in 1...7 { _ = s.handle(.submit(ClientOp(client: "c", cseq: i, base: i - 1, op: set("a", ["p"], "\(i)")))) }
        #expect(s.disk.snapshot.seq == 6 && s.disk.tail.count == 1 && s.disk.archive.count == 6)
        let r = Server(disk: s.disk, snapshotEvery: 3)
        #expect(r.doc == s.doc)
        var r2 = r
        // Retransmit of an op that is already inside the snapshot is still recognised.
        let dup = r2.handle(.hello(Hello(client: "c", lastSeq: nil, willResendFrom: 1)))
        guard case .welcome(let w)? = dup.first?.message else { Issue.record("no welcome"); return }
        #expect(w.snapshot?.seq == 6 && w.entries.count == 1 && w.snapshot?.committedMine.count == 6)
    }
}

@Suite("Client")
struct ClientTests {
    @Test func rebaseHidesConflictedPendingOpAndWarnsOnce() {
        var c = Client(id: "me", journaled: true)
        let doc = Document(nodes: [node("a")])
        _ = c.receive(.welcome(Welcome(head: 0, snapshot: SnapshotPayload(seq: 0, doc: doc, committedMine: [:]),
                                       entries: [], clientHigh: 0, rejected: [:])), now: 0)
        _ = c.edit(set("a", ["p"], "mine"), now: 0)
        #expect(c.view.nodes["a"]?.config["p"] == .string("mine"))
        let theirs = LogEntry(seq: 1, client: "bob", cseq: 1, base: 0, op: set("a", ["p"], "theirs"))
        _ = c.receive(.committed([theirs]), now: 1)
        #expect(c.view.nodes["a"]?.config["p"] == .string("theirs"))
        let events = c.drainEvents()
        #expect(events.filter { if case .conflictDetected = $0 { return true }; return false }.count == 1)
        // The op stays queued until the server gives the final verdict.
        #expect(c.unresolvedCount == 1)
        _ = c.receive(.rejected(cseq: 1, reason: .conflict(Conflict(node: "a", field: .config(["p"]), seq: 1, by: "bob"))), now: 2)
        #expect(c.unresolvedCount == 0)
        #expect(c.drainEvents().contains { if case .rejected(1, _, _) = $0 { return true }; return false })
    }

    @Test func outOfOrderBroadcastIsBufferedUntilGapFills() {
        var c = Client(id: "me")
        let doc = Document(nodes: [node("a")])
        _ = c.receive(.welcome(Welcome(head: 0, snapshot: SnapshotPayload(seq: 0, doc: doc, committedMine: [:]),
                                       entries: [], clientHigh: 0, rejected: [:])), now: 0)
        let e1 = LogEntry(seq: 1, client: "bob", cseq: 1, base: 0, op: set("a", ["p"], "1"))
        let e2 = LogEntry(seq: 2, client: "bob", cseq: 2, base: 1, op: set("a", ["p"], "2"))
        _ = c.receive(.committed([e2]), now: 1)
        #expect(c.lastSeq == 0)
        _ = c.receive(.committed([e1]), now: 2)
        #expect(c.lastSeq == 2 && c.view.nodes["a"]?.config["p"] == .string("2"))
    }

    @Test func localEditOfMissingNodeNeverBecomesAnOp() {
        var c = Client(id: "me")
        _ = c.receive(.welcome(Welcome(head: 0, snapshot: SnapshotPayload(seq: 0, doc: Document(), committedMine: [:]),
                                       entries: [], clientHigh: 0, rejected: [:])), now: 0)
        let r = c.edit(set("ghost", ["p"], "x"), now: 0)
        #expect(r.cseq == nil && c.unresolvedCount == 0)
    }
}
