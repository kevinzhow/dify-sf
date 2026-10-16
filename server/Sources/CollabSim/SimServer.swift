import CollabCore

/// In-memory model of what survives a server crash: the Postgres tables, as far as the protocol cares.
/// `commit` is atomic (one transaction per batch), exactly like the real store.
struct SimDisk: Sendable {
    var snapshot: Snapshot
    var log: [LogEntry] = []
    var highs: [ClientID: Int] = [:]
    var rejections: [ClientID: [Int: RejectReason]] = [:]
    var fingerprints: [ClientID: [Int: Int64]] = [:]

    init(initial: Document) { snapshot = Snapshot(seq: 0, doc: initial) }

    func known(_ client: ClientID, _ range: ClosedRange<Int>?) -> KnownOutcomes {
        guard let range else { return KnownOutcomes() }
        var k = KnownOutcomes()
        for e in log where e.client == client && range.contains(e.cseq) { k.committed[e.cseq] = e.seq }
        for (c, r) in rejections[client] ?? [:] where range.contains(c) { k.rejected[c] = r }
        for (c, f) in fingerprints[client] ?? [:] where range.contains(c) { k.fingerprints[c] = f }
        return k
    }

    mutating func commit(_ batch: SequencerBatch, client: ClientID, snapshot snap: Snapshot?) {
        log += batch.entries
        for (c, r) in batch.rejections { rejections[client, default: [:]][c] = r }
        for (c, f) in batch.fingerprints { fingerprints[client, default: [:]][c] = f }
        if batch.highChanged { highs[client] = batch.newHigh }
        if let snap { snapshot = snap }
    }

    var tail: [LogEntry] { log.filter { $0.seq > snapshot.seq } }

    /// Mutation `lossyDisk`: pretend acked entries were only in the page cache.
    mutating func dropTail(_ n: Int) {
        log.removeLast(n)
        var highs: [ClientID: Int] = [:]
        for e in log { highs[e.client] = max(highs[e.client] ?? 0, e.cseq) }
        for (c, rs) in rejections { highs[c] = max(highs[c] ?? 0, rs.keys.max() ?? 0) }
        self.highs = highs
        if snapshot.seq > log.count { snapshot = Snapshot(seq: 0, doc: Document()) }  // unrecoverable in this mutation
    }
}

/// Simulated server process: the pure sequencer + the stream hub, on top of `SimDisk`.
struct SimServer: Sendable {
    var seqr: Sequencer
    var disk: SimDisk
    /// client -> its live stream: `conn` orders connections by when the client opened them, `generation` tags events.
    var subs: [ClientID: (conn: Int, generation: Int)] = [:]
    let snapshotEvery: Int
    let maxReplay: Int

    /// Boot / crash recovery from the durable state.
    init(disk: SimDisk, snapshotEvery: Int, maxReplay: Int, defects: ProtocolDefects) throws(RecoveryError) {
        self.disk = disk
        self.snapshotEvery = snapshotEvery
        self.maxReplay = maxReplay
        seqr = try Sequencer(snapshot: disk.snapshot, tail: disk.tail, defects: defects)
    }

    struct Output {
        var response: SubmitResponse?
        var events: [(to: ClientID, event: StreamEvent)] = []
    }

    mutating func submit(_ req: SubmitRequest) -> Output {
        let high = disk.highs[req.client] ?? 0
        let known = disk.known(req.client, Sequencer.lookupRange(for: req, clientHigh: high))
        var working = seqr
        let batch = working.process(req, clientHigh: high, known: known)
        var snap: Snapshot?
        if Sequencer.snapshotDue(oldSeq: seqr.seq, newSeq: working.seq, every: snapshotEvery) { snap = working.snapshot }
        disk.commit(batch, client: req.client, snapshot: snap)  // durable BEFORE anything is announced
        seqr = working
        var out = Output(response: batch.response)
        for e in batch.entries {
            for c in subs.keys.sorted() { out.events.append((c, .commit(e))) }
        }
        return out
    }

    /// A client opened (or re-opened) its event stream.
    mutating func open(_ o: StreamOpen, conn: Int) -> [StreamEvent] {
        guard let client = o.client else { return [] }
        if let cur = subs[client], cur.conn > conn { return [] }  // an older request overtaken by a newer one
        subs[client] = (conn, o.generation)
        let head = seqr.seq
        var events: [StreamEvent] = []
        switch resumePlan(lastEventId: o.lastEventId, head: head, maxReplay: maxReplay) {
        case .replay(let after):
            events += disk.log.filter { $0.seq > after && $0.seq <= head }.map { .commit($0) }
        case .snapshot:
            var committed: [Int: Int] = [:]
            if let from = o.from {
                for e in disk.log where e.client == client && e.cseq >= from { committed[e.cseq] = e.seq }
            }
            events.append(.snapshot(SnapshotEvent(seq: head, doc: seqr.doc, committed: committed)))
        }
        events.append(.ready(head: head))
        return events
    }

    func pings() -> [(to: ClientID, event: StreamEvent)] { subs.keys.sorted().map { ($0, .ping) } }
}
