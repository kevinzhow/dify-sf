/// Final fate of one client op. Exactly one is reported per op, in cseq order.
public enum Outcome: Hashable, Sendable {
    case committed(seq: Int)
    case rejected(RejectReason)
    /// The op was created but the client crashed before the server handled it; content is gone.
    case lost
}

/// What the UI should surface. `committed`/`rejected`/`lost` are terminal and each op gets exactly one.
public enum ClientEvent: Hashable, Sendable {
    case committed(cseq: Int, seq: Int)
    /// Not saved. `op` is included so the UI can offer "re-apply mine on top of the latest".
    case rejected(cseq: Int, op: Op, reason: RejectReason)
    /// Not saved, and the content could not be recovered (non-journaled client crashed).
    case lost(cseq: Int)
    /// Early warning: a newer remote write already makes this pending op doomed. The terminal
    /// `.rejected` follows when the server confirms. The op is hidden from the local view meanwhile.
    case conflictDetected(cseq: Int, op: Op, reason: RejectReason)
    /// The edit was refused locally (e.g. the node is already gone); it never became an op.
    case localInvalid(op: Op, reason: RejectReason)
}

public struct JournalEntry: Hashable, Codable, Sendable {
    public var cseq: Int
    public var base: Int
    public var op: Op
}

/// The part of client state that survives a crash/reload (think IndexedDB / local file).
/// `journal` is only written by journaled clients (write-ahead outbox); every client persists the
/// two counters, so even a volatile client can tell *which* ops it lost.
public struct ClientDurable: Hashable, Codable, Sendable {
    public var id: ClientID
    public var nextCseq: Int
    public var unresolvedFrom: Int
    public var journal: [JournalEntry]
}

struct PendingOp: Hashable, Sendable {
    let cseq: Int
    let base: Int
    let op: Op?  // nil = abandoned (content lost in a crash)
    var sentAt: Int?
    var outcome: Outcome?
    var conflictNotified = false
    var sendable: Bool { op != nil && outcome == nil }
}

public struct EditResult: Sendable {
    public var cseq: Int?
    public var messages: [ClientMessage]
}

/// Optimistic client. `confirmed` mirrors the server at `lastSeq`; `view` = confirmed + pending ops
/// (re-derived on every change, which is the "rebase"). Pure: time is passed in, messages returned.
public struct Client: Sendable {
    public let id: ClientID
    public let journaled: Bool
    public private(set) var confirmed = Document()
    public private(set) var view = Document()
    public private(set) var lastSeq = 0
    public private(set) var hasState = false
    public private(set) var connected = false
    public private(set) var sessionOpen = false
    public private(set) var nextCseq = 1
    /// Anything that indicates a bug in the protocol implementation (checked by the simulator).
    public private(set) var violations: [String] = []

    private var outbox: [PendingOp] = []
    private var buffered: [Int: LogEntry] = [:]
    private var events: [ClientEvent] = []
    private var wantsSync = false
    private var lastHelloAt = -1000
    private let defects: ProtocolDefects
    private let retransmitAfter: Int
    private let syncEvery: Int

    public init(id: ClientID, journaled: Bool = true, defects: ProtocolDefects = [],
                retransmitAfter: Int = 8, syncEvery: Int = 12) {
        self.id = id
        self.journaled = journaled
        self.defects = defects
        self.retransmitAfter = retransmitAfter
        self.syncEvery = syncEvery
    }

    // MARK: - Persistence / crash

    public var durable: ClientDurable {
        ClientDurable(id: id, nextCseq: nextCseq, unresolvedFrom: outbox.first?.cseq ?? nextCseq,
                      journal: journaled ? outbox.compactMap { p in
                          p.op.map { JournalEntry(cseq: p.cseq, base: p.base, op: $0) }
                      } : [])
    }

    /// Boot after a crash or reload. Journaled clients get their unsent ops back; others only learn
    /// *that* cseqs in [unresolvedFrom, nextCseq) were in flight and will report them lost or committed
    /// once the server has answered.
    public init(restoring d: ClientDurable, journaled: Bool, defects: ProtocolDefects = [],
                retransmitAfter: Int = 8, syncEvery: Int = 12) {
        self.init(id: d.id, journaled: journaled, defects: defects,
                  retransmitAfter: retransmitAfter, syncEvery: syncEvery)
        nextCseq = d.nextCseq
        if journaled {
            outbox = d.journal.map { PendingOp(cseq: $0.cseq, base: $0.base, op: $0.op) }
            let known = Set(d.journal.map(\.cseq))
            for c in d.unresolvedFrom..<d.nextCseq where !known.contains(c) {
                outbox.append(PendingOp(cseq: c, base: 0, op: nil))
            }
            outbox.sort { $0.cseq < $1.cseq }
        } else {
            outbox = (d.unresolvedFrom..<d.nextCseq).map { PendingOp(cseq: $0, base: 0, op: nil) }
        }
    }

    public mutating func drainEvents() -> [ClientEvent] {
        defer { events = [] }
        return events
    }

    public var unresolvedCount: Int { outbox.count }
    public var isQuiescent: Bool { outbox.isEmpty && buffered.isEmpty && hasState && connected && sessionOpen }

    // MARK: - User edits

    /// Optimistically applies a local edit and queues it. Returns the cseq (nil if refused locally).
    public mutating func edit(_ op: Op, now: Int) -> EditResult {
        guard hasState else {
            events.append(.localInvalid(op: op, reason: .invalid("not synced yet")))
            return EditResult(cseq: nil, messages: [])
        }
        do {
            try view.validate(op, base: lastSeq, by: id)
        } catch {
            events.append(.localInvalid(op: op, reason: error))
            return EditResult(cseq: nil, messages: [])
        }
        let cseq = nextCseq
        nextCseq += 1
        outbox.append(PendingOp(cseq: cseq, base: lastSeq, op: op))
        view.apply(op, at: localStamp, defects: defects)
        var out: [ClientMessage] = []
        if connected && sessionOpen {
            outbox[outbox.count - 1].sentAt = now
            out.append(.submit(ClientOp(client: id, cseq: cseq, base: lastSeq, op: op)))
        }
        return EditResult(cseq: cseq, messages: out)
    }

    // MARK: - Connection lifecycle

    public mutating func connect(now: Int) -> [ClientMessage] {
        connected = true
        sessionOpen = false
        return [hello(now: now)]
    }

    public mutating func connectionLost() {
        connected = false
        sessionOpen = false
    }

    /// Timer: (re)send hello until the session is open, periodic sync, retransmit unacked ops.
    public mutating func tick(now: Int) -> [ClientMessage] {
        guard connected else { return [] }
        var out: [ClientMessage] = []
        if !sessionOpen {
            if now - lastHelloAt >= retransmitAfter { out.append(hello(now: now)) }
            return out
        }
        if (wantsSync || !buffered.isEmpty) && now - lastHelloAt >= 2 || now - lastHelloAt >= syncEvery {
            out.append(hello(now: now))
        }
        out += retransmit(now: now, force: false)
        return out
    }

    private mutating func hello(now: Int) -> ClientMessage {
        lastHelloAt = now
        wantsSync = false
        let first = outbox.first(where: \.sendable)?.cseq ?? nextCseq
        return .hello(Hello(client: id, lastSeq: hasState ? lastSeq : nil, willResendFrom: first))
    }

    private mutating func retransmit(now: Int, force: Bool) -> [ClientMessage] {
        var out: [ClientMessage] = []
        for i in outbox.indices where outbox[i].sendable {
            let p = outbox[i]
            if defects.contains(.clientNeverResends) && p.sentAt != nil { continue }
            if !force, let t = p.sentAt, now - t < retransmitAfter { continue }
            outbox[i].sentAt = now
            out.append(.submit(ClientOp(client: id, cseq: p.cseq, base: p.base, op: p.op!)))
        }
        return out
    }

    // MARK: - Server messages

    public mutating func receive(_ message: ServerMessage, now: Int) -> [ClientMessage] {
        var out: [ClientMessage] = []
        switch message {
        case .committed(let entries):
            if hasState { ingest(entries) }

        case .welcome(let w):
            guard hasState || w.snapshot != nil else { return [] }
            handleWelcome(w)
            sessionOpen = true
            out += retransmit(now: now, force: true)

        case .rejected(let cseq, let reason):
            settle(cseq, .rejected(reason))

        case .ack(_, let seq):
            if seq > lastSeq { wantsSync = true }

        case .resyncRequired:
            sessionOpen = false
            out.append(hello(now: now))
        }
        rebuildView()
        releaseResolved()
        return out
    }

    private mutating func handleWelcome(_ w: Welcome) {
        if let s = w.snapshot, !hasState || s.seq > lastSeq {
            confirmed = s.doc
            lastSeq = s.seq
            hasState = true
            buffered = buffered.filter { $0.key > s.seq }
            for (cseq, seq) in s.committedMine.sorted(by: { $0.key < $1.key }) { settle(cseq, .committed(seq: seq)) }
        }
        ingest(w.entries)
        // Every commit of ours with cseq <= clientHigh is now known; whatever has no outcome was not saved.
        guard lastSeq >= w.head else { return }
        for i in outbox.indices where outbox[i].outcome == nil && outbox[i].cseq <= w.clientHigh {
            if outbox[i].op == nil {
                outbox[i].outcome = .lost
            } else {
                outbox[i].outcome = .rejected(w.rejected[outbox[i].cseq] ?? .notCommitted)
            }
        }
    }

    private mutating func ingest(_ entries: [LogEntry]) {
        for e in entries where e.seq > lastSeq { buffered[e.seq] = e }
        while let e = buffered[lastSeq + 1] {
            buffered[lastSeq + 1] = nil
            do {
                try confirmed.validate(e.op, base: e.base, by: e.client, checkConflicts: false)
            } catch {
                violations.append("committed entry \(e.seq) invalid on client: \(error)")
            }
            confirmed.apply(e.op, at: e.stamp, defects: defects)
            lastSeq = e.seq
            if e.client == id { settle(e.cseq, .committed(seq: e.seq)) }
        }
        if !buffered.isEmpty { wantsSync = true }
    }

    private mutating func settle(_ cseq: Int, _ outcome: Outcome) {
        guard let i = outbox.firstIndex(where: { $0.cseq == cseq }) else { return }
        var outcome = outcome
        if outbox[i].op == nil, case .rejected = outcome { outcome = .lost }  // content already gone
        switch (outbox[i].outcome, outcome) {
        case (nil, _): outbox[i].outcome = outcome
        case (.committed(let a)?, .committed(let b)) where a == b: break
        case (.committed?, .rejected): break  // late duplicate answer; commit wins
        case (.rejected?, .committed):
            violations.append("cseq \(cseq) committed after being reported rejected")
        default: break
        }
    }

    // MARK: - Rebase

    private var localStamp: Stamp { Stamp(seq: Int.max, client: id) }

    /// view = confirmed + every unresolved op that is still valid on top of it. Ops that became
    /// invalid (stale conflict, node deleted remotely, ...) are hidden; stale-based ones raise an
    /// early warning once.
    private mutating func rebuildView() {
        var d = confirmed
        for i in outbox.indices where outbox[i].outcome == nil {
            guard let op = outbox[i].op else { continue }
            do {
                try d.validate(op, base: outbox[i].base, by: id)
                d.apply(op, at: localStamp, defects: defects)
            } catch {
                if error.isStaleBased && !outbox[i].conflictNotified {
                    outbox[i].conflictNotified = true
                    events.append(.conflictDetected(cseq: outbox[i].cseq, op: op, reason: error))
                }
            }
        }
        view = d
    }

    /// Reports outcomes strictly in cseq order so the persisted "unresolved from" pointer stays contiguous.
    private mutating func releaseResolved() {
        while let first = outbox.first, let outcome = first.outcome {
            outbox.removeFirst()
            switch outcome {
            case .committed(let seq): events.append(.committed(cseq: first.cseq, seq: seq))
            case .rejected(let r): events.append(.rejected(cseq: first.cseq, op: first.op!, reason: r))
            case .lost: events.append(.lost(cseq: first.cseq))
            }
        }
    }
}
