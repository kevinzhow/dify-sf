/// Final fate of one client op. Exactly one is reported per op, in cseq order.
public enum Outcome: Hashable, Sendable {
    case committed(seq: Int)
    case rejected(RejectReason)
    /// The op was created but the client crashed before the server handled it; content is gone.
    case lost
}

/// What the UI should surface. `committed`/`rejected`/`lost` are terminal and each op gets exactly one
/// (at-least-once across a process crash: a crash between reporting and persisting repeats the same outcome).
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

/// Requests the pure client asks its transport to perform.
public enum ClientRequest: Hashable, Sendable {
    /// `POST /v1/docs/{doc}/ops`. At most one is outstanding at a time.
    case submit(SubmitRequest)
    /// `GET /v1/docs/{doc}/events`. Supersedes (and implicitly cancels) any older stream.
    case openStream(StreamOpen)
}

/// Timing knobs, in whatever unit the caller's `now` uses (simulator ticks, or milliseconds).
public struct ClientConfig: Sendable {
    /// Resend the outstanding POST if it has not been answered after this long.
    public var retransmitAfter: Int
    /// Reopen the stream if nothing (not even a ping) arrived for this long.
    public var streamSilence: Int
    /// Reconnect backoff: delay = half..full of min(reconnectMax, reconnectBase * 2^attempts).
    public var reconnectBase: Int
    public var reconnectMax: Int
    public var maxBatch: Int

    public init(retransmitAfter: Int = 8, streamSilence: Int = 30, reconnectBase: Int = 2,
                reconnectMax: Int = 40, maxBatch: Int = 50) {
        self.retransmitAfter = retransmitAfter
        self.streamSilence = streamSilence
        self.reconnectBase = reconnectBase
        self.reconnectMax = reconnectMax
        self.maxBatch = maxBatch
    }
}

struct PendingOp: Hashable, Sendable {
    let cseq: Int
    let base: Int
    let op: Op?  // nil = abandoned (content lost in a crash)
    var ackedSeq: Int?
    var outcome: Outcome?
    var conflictNotified = false
    var sendable: Bool { op != nil && outcome == nil && ackedSeq == nil }
}

public struct EditResult: Sendable {
    public var cseq: Int?
    public var requests: [ClientRequest]
}

/// Optimistic client. `confirmed` mirrors the server at `lastSeq`; `view` = confirmed + pending ops
/// (re-derived on every change, which is the "rebase"). Pure: time is passed in, requests are returned.
///
/// Transport contract (docs/protocol.md, "Client algorithm"): the driver performs the returned
/// `ClientRequest`s, feeds back `receive(_:generation:now:)` for stream events, `receive(_:now:)` for POST
/// responses, `streamClosed` when the stream ends, `submitFailed` when a POST errors, and calls `tick`
/// regularly.
public struct Client: Sendable {
    public let id: ClientID
    public let journaled: Bool
    public private(set) var confirmed = Document()
    public private(set) var view = Document()
    public private(set) var lastSeq = 0
    public private(set) var hasState = false
    public private(set) var nextCseq = 1
    /// Anything that indicates a bug in the protocol implementation (checked by the simulator).
    public private(set) var violations: [String] = []

    // Stream state
    public private(set) var generation = 0
    public private(set) var streamActive = false
    public private(set) var streamReady = false
    private var lastStreamActivity = 0
    private var nextOpenAt = 0
    private var reconnectAttempts = 0
    // POST state
    private var inFlightSince: Int?
    private var submitBlockedUntil = 0
    private var submitFailures = 0

    private var outbox: [PendingOp] = []
    private var events: [ClientEvent] = []
    private var rng: Rng
    private let defects: ProtocolDefects
    private let config: ClientConfig

    public init(id: ClientID, journaled: Bool = true, defects: ProtocolDefects = [], config: ClientConfig = ClientConfig()) {
        self.id = id
        self.journaled = journaled
        self.defects = defects
        self.config = config
        rng = Rng(label: id)
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
    public init(restoring d: ClientDurable, journaled: Bool, defects: ProtocolDefects = [], config: ClientConfig = ClientConfig()) {
        self.init(id: d.id, journaled: journaled, defects: defects, config: config)
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
    /// Human-readable state of the outbox, for diagnostics.
    public var debugOutbox: [String] {
        outbox.map { "cseq \($0.cseq) op=\($0.op == nil ? "abandoned" : "set") acked=\(String(describing: $0.ackedSeq)) outcome=\(String(describing: $0.outcome))" }
            + ["lastSeq=\(lastSeq) hasState=\(hasState) streamActive=\(streamActive) ready=\(streamReady) inFlight=\(String(describing: inFlightSince)) blockedUntil=\(submitBlockedUntil)"]
    }
    public var isQuiescent: Bool { outbox.isEmpty && hasState && streamActive && streamReady }

    // MARK: - User edits

    /// Optimistically applies a local edit and queues it. Returns the cseq (nil if refused locally).
    public mutating func edit(_ op: Op, now: Int) -> EditResult {
        guard hasState else {
            events.append(.localInvalid(op: op, reason: .invalid("not synced yet")))
            return EditResult(cseq: nil, requests: [])
        }
        do {
            try view.validate(op, base: lastSeq, by: id)
        } catch {
            events.append(.localInvalid(op: op, reason: error))
            return EditResult(cseq: nil, requests: [])
        }
        let cseq = nextCseq
        nextCseq += 1
        outbox.append(PendingOp(cseq: cseq, base: lastSeq, op: op))
        view.apply(op, at: localStamp, defects: defects)
        return EditResult(cseq: cseq, requests: flushIfIdle(now: now))
    }

    // MARK: - Timers and transport signals

    /// Call regularly (and once at boot). Opens/reopens the stream, runs the silence watchdog, and
    /// (re)sends the outstanding POST.
    public mutating func tick(now: Int) -> [ClientRequest] {
        var out: [ClientRequest] = []
        if streamActive && now - lastStreamActivity >= config.streamSilence {
            // Half-open or stalled connection: no events and no pings for too long.
            closeStream(now: now, backoff: true)
        }
        if !streamActive && now >= nextOpenAt { out.append(openStream(now: now)) }
        if let t = inFlightSince, now - t >= config.retransmitAfter {
            inFlightSince = nil  // the POST (or its response) is presumed lost; resend below
        }
        out += flushIfIdle(now: now)
        return out
    }

    /// The platform says connectivity is back (or the server restarted): reconnect right away instead of
    /// waiting out the backoff, and resend the outstanding POST.
    public mutating func networkAvailable(now: Int) -> [ClientRequest] {
        reconnectAttempts = 0
        submitFailures = 0
        submitBlockedUntil = 0
        inFlightSince = nil
        if streamActive { closeStream(now: now, backoff: false) }
        var out = [openStream(now: now)]
        out += flushIfIdle(now: now)
        return out
    }

    /// The transport saw the stream of `generation` end (EOF, error, cut).
    public mutating func streamClosed(generation g: Int, now: Int) {
        guard g == generation, streamActive else { return }
        closeStream(now: now, backoff: true)
    }

    /// The POST failed at the transport level (connect error, timeout, 5xx). Safe to resend: idempotent.
    public mutating func submitFailed(now: Int) {
        inFlightSince = nil
        submitFailures += 1
        submitBlockedUntil = now + backoffDelay(attempts: submitFailures)
    }

    private mutating func closeStream(now: Int, backoff: Bool) {
        streamActive = false
        streamReady = false
        generation += 1  // events of the old stream are now ignored
        if backoff {
            reconnectAttempts += 1
            nextOpenAt = now + backoffDelay(attempts: reconnectAttempts)
        } else {
            nextOpenAt = now
        }
    }

    private mutating func openStream(now: Int) -> ClientRequest {
        streamActive = true
        streamReady = false
        generation += 1
        lastStreamActivity = now
        return .openStream(StreamOpen(client: id, lastEventId: hasState ? lastSeq : nil,
                                      from: outbox.first?.cseq, generation: generation))
    }

    private mutating func backoffDelay(attempts: Int) -> Int {
        let cap = min(config.reconnectMax, config.reconnectBase << min(attempts, 20))
        return cap / 2 + rng.int(0...max(0, cap - cap / 2))
    }

    // MARK: - Submitting

    private mutating func flushIfIdle(now: Int) -> [ClientRequest] {
        guard inFlightSince == nil, now >= submitBlockedUntil else { return [] }
        let abandoned = outbox.contains { $0.op == nil && $0.outcome == nil }
        var batch: [IncomingOp] = []
        for p in outbox where p.sendable {
            if defects.contains(.clientNeverResends) && sentOnce.contains(p.cseq) { continue }
            batch.append(IncomingOp(cseq: p.cseq, base: p.base, op: p.op!))
            sentOnce.insert(p.cseq)
            if batch.count >= config.maxBatch { break }
        }
        guard abandoned || !batch.isEmpty else { return [] }
        var req = SubmitRequest(client: id, ops: batch)
        if abandoned {
            // We lost the content of some in-flight ops: tell the server to stop waiting for them and
            // report what it did with them.
            req.floor = outbox.first(where: \.sendable)?.cseq ?? nextCseq
            req.resolveFrom = outbox.first?.cseq
        }
        inFlightSince = now
        return [.submit(req)]
    }
    private var sentOnce: Set<Int> = []

    // MARK: - Server -> client

    /// A stream event of the given generation (stale generations are ignored).
    public mutating func receive(_ event: StreamEvent, generation g: Int, now: Int) -> [ClientRequest] {
        guard g == generation, streamActive else { return [] }
        lastStreamActivity = now
        var out: [ClientRequest] = []
        switch event {
        case .ping: break
        case .ready:
            streamReady = true
            reconnectAttempts = 0
        case .snapshot(let s):
            adopt(s)
        case .commit(let e):
            guard hasState else { break }
            if e.seq <= lastSeq { break }  // duplicate
            if e.seq != lastSeq + 1 {
                // A hole in the stream: reconnect and resume from lastSeq.
                closeStream(now: now, backoff: false)
                out.append(openStream(now: now))
                break
            }
            ingest(e)
        }
        settleAckedUpToLastSeq()
        rebuildView()
        releaseResolved()
        out += flushIfIdle(now: now)
        return out
    }

    /// The answer to a POST (possibly a stale one from an earlier retransmit; that is harmless).
    public mutating func receive(_ response: SubmitResponse, now: Int) -> [ClientRequest] {
        inFlightSince = nil
        submitFailures = 0
        submitBlockedUntil = 0
        for r in response.results {
            switch r {
            case .ack(let cseq, let seq):
                guard let i = outbox.firstIndex(where: { $0.cseq == cseq }), outbox[i].outcome == nil else { continue }
                if seq <= lastSeq && hasState { settle(cseq, .committed(seq: seq)) } else { outbox[i].ackedSeq = seq }
            case .reject(let cseq, let reason):
                settle(cseq, .rejected(reason))
            case .gap:
                break  // resend from the front on the next flush (nothing was recorded)
            }
        }
        if let known = response.known {
            for (cseq, seq) in known.committed.sorted(by: { $0.key < $1.key }) {
                guard let i = outbox.firstIndex(where: { $0.cseq == cseq }), outbox[i].outcome == nil else { continue }
                if seq <= lastSeq && hasState { settle(cseq, .committed(seq: seq)) } else { outbox[i].ackedSeq = seq }
            }
            for (cseq, reason) in known.rejected { settle(cseq, .rejected(reason)) }
            // Abandoned ops the server handled but never committed or rejected: definitively not saved.
            for i in outbox.indices where outbox[i].op == nil && outbox[i].outcome == nil
                && outbox[i].ackedSeq == nil && outbox[i].cseq <= response.high {
                outbox[i].outcome = .lost
            }
        }
        settleAckedUpToLastSeq()
        rebuildView()
        releaseResolved()
        return flushIfIdle(now: now)
    }

    private mutating func adopt(_ s: SnapshotEvent) {
        confirmed = s.doc
        lastSeq = s.seq
        hasState = true
        reconnectAttempts = 0
        for (cseq, seq) in s.committed.sorted(by: { $0.key < $1.key }) where seq <= s.seq {
            settle(cseq, .committed(seq: seq))
        }
    }

    private mutating func ingest(_ e: LogEntry) {
        do {
            try confirmed.validate(e.op, base: e.base, by: e.client, checkConflicts: false)
        } catch {
            violations.append("committed entry \(e.seq) invalid on client: \(error)")
        }
        confirmed.apply(e.op, at: e.stamp, defects: defects)
        lastSeq = e.seq
        if e.client == id { settle(e.cseq, .committed(seq: e.seq)) }
    }

    /// An acked op whose entry we have since passed is committed (covers snapshot joins).
    private mutating func settleAckedUpToLastSeq() {
        guard hasState else { return }
        for i in outbox.indices where outbox[i].outcome == nil {
            if let s = outbox[i].ackedSeq, s <= lastSeq { outbox[i].outcome = .committed(seq: s) }
        }
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
            sentOnce.remove(first.cseq)
            switch outcome {
            case .committed(let seq): events.append(.committed(cseq: first.cseq, seq: seq))
            case .rejected(let r): events.append(.rejected(cseq: first.cseq, op: first.op!, reason: r))
            case .lost: events.append(.lost(cseq: first.cseq))
            }
        }
    }
}
