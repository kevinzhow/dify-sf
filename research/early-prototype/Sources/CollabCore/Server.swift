/// Durable snapshot: graph at `seq` plus the de-duplication index needed to answer retransmits.
public struct Snapshot: Hashable, Codable, Sendable {
    public var seq: Int
    public var doc: Document
    public var high: [ClientID: Int]
    public var committed: [ClientID: [Int: Int]]
}

/// What survives a server crash. An op is acked only after it is in `tail`.
/// `archive` is the cold part of the log (entries older than the snapshot), kept for audit/history;
/// the server never reads it back.
public struct Disk: Hashable, Codable, Sendable {
    public var snapshot: Snapshot
    public var tail: [LogEntry]
    public var archive: [LogEntry]

    public init(initial: Document) {
        snapshot = Snapshot(seq: 0, doc: initial, high: [:], committed: [:])
        tail = []
        archive = []
    }

    public var fullLog: [LogEntry] { archive + tail }
}

/// The sequencer. Pure state machine: feed messages in, get messages out. All in-memory state other
/// than `disk` is lost by a crash and rebuilt by `recover`.
public struct Server: Sendable {
    public private(set) var doc: Document
    public private(set) var seq: Int
    public private(set) var disk: Disk
    private var high: [ClientID: Int]
    private var committed: [ClientID: [Int: Int]]
    private var rejected: [ClientID: [Int: RejectReason]] = [:]
    private var sessions: Set<ClientID> = []
    private let snapshotEvery: Int
    private let defects: ProtocolDefects

    public init(initial: Document = Document(), snapshotEvery: Int = 32, defects: ProtocolDefects = []) {
        self.init(disk: Disk(initial: initial), snapshotEvery: snapshotEvery, defects: defects)
    }

    /// Crash recovery: snapshot + replay of the durable tail.
    public init(disk: Disk, snapshotEvery: Int = 32, defects: ProtocolDefects = []) {
        self.disk = disk
        self.snapshotEvery = snapshotEvery
        self.defects = defects
        doc = disk.snapshot.doc
        seq = disk.snapshot.seq
        high = disk.snapshot.high
        committed = disk.snapshot.committed
        for e in disk.tail {
            doc.apply(e.op, at: e.stamp, defects: defects)
            seq = e.seq
            high[e.client] = max(high[e.client] ?? 0, e.cseq)
            committed[e.client, default: [:]][e.cseq] = e.seq
        }
    }

    public var sessionCount: Int { sessions.count }

    public mutating func handle(_ message: ClientMessage) -> [Outbound] {
        switch message {
        case .hello(let h): return handleHello(h)
        case .submit(let op): return handleSubmit(op)
        }
    }

    // MARK: - Hello / catch-up

    private mutating func handleHello(_ h: Hello) -> [Outbound] {
        sessions.insert(h.client)
        high[h.client] = max(high[h.client] ?? 0, h.willResendFrom - 1)
        return [Outbound(to: h.client, message: .welcome(makeWelcome(h)))]
    }

    private func makeWelcome(_ h: Hello) -> Welcome {
        var snapshot: SnapshotPayload?
        var from = h.lastSeq ?? 0
        if h.lastSeq == nil || h.lastSeq! < disk.snapshot.seq {
            snapshot = SnapshotPayload(seq: disk.snapshot.seq, doc: disk.snapshot.doc,
                                       committedMine: disk.snapshot.committed[h.client] ?? [:])
            from = disk.snapshot.seq
        }
        return Welcome(head: seq, snapshot: snapshot, entries: disk.tail.filter { $0.seq > from },
                       clientHigh: high[h.client] ?? 0, rejected: rejected[h.client] ?? [:])
    }

    // MARK: - Submit

    private mutating func handleSubmit(_ c: ClientOp) -> [Outbound] {
        guard sessions.contains(c.client) else { return [Outbound(to: c.client, message: .resyncRequired)] }
        let handled = high[c.client] ?? 0

        if c.cseq <= handled && !defects.contains(.noDedup) {
            // Retransmit of something already handled: answer from memory, never apply twice.
            if let s = committed[c.client]?[c.cseq] {
                return [Outbound(to: c.client, message: .ack(cseq: c.cseq, seq: s))]
            }
            let reason = rejected[c.client]?[c.cseq] ?? .notCommitted
            return [Outbound(to: c.client, message: .rejected(cseq: c.cseq, reason: reason))]
        }
        if c.cseq > handled + 1 && !defects.contains(.noDedup) {
            return []  // gap (reordered/lost earlier op): ignore, the client retransmits in order
        }

        do {
            try doc.validate(c.op, base: c.base, by: c.client,
                             checkConflicts: !defects.contains(.skipStaleCheck))
        } catch {
            high[c.client] = max(handled, c.cseq)
            rejected[c.client, default: [:]][c.cseq] = error
            return [Outbound(to: c.client, message: .rejected(cseq: c.cseq, reason: error))]
        }

        // Commit = durable append FIRST, then in-memory apply, then broadcast.
        seq += 1
        let entry = LogEntry(seq: seq, client: c.client, cseq: c.cseq, base: c.base, op: c.op)
        disk.tail.append(entry)
        doc.apply(entry.op, at: entry.stamp, defects: defects)
        high[c.client] = max(handled, c.cseq)
        committed[c.client, default: [:]][c.cseq] = seq
        if disk.tail.count >= snapshotEvery { compact() }
        return sessions.sorted().map { Outbound(to: $0, message: .committed([entry])) }
    }

    private mutating func compact() {
        disk.archive += disk.tail
        disk.tail = []
        disk.snapshot = Snapshot(seq: seq, doc: doc, high: high, committed: committed)
    }
}
