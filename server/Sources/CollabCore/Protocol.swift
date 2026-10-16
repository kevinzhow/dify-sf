/// Wire-level message types shared by the server, the clients and the simulator.
/// The JSON encoding of every type here is specified in docs/protocol.md and implemented in Wire.swift.

/// One committed op in the durable, totally ordered log.
public struct LogEntry: Hashable, Codable, Sendable {
    public var seq: Int
    public var client: ClientID
    public var cseq: Int
    public var base: Int
    public var op: Op
    public var stamp: Stamp { Stamp(seq: seq, client: client) }
    public init(seq: Int, client: ClientID, cseq: Int, base: Int, op: Op) {
        self.seq = seq
        self.client = client
        self.cseq = cseq
        self.base = base
        self.op = op
    }
}

/// An op as received from a client. `(client, cseq)` is the idempotency key; `base` is the server
/// version the client had applied when the user made the edit (it never changes on retransmit).
/// `op` is nil when the JSON of the op could not be understood; the server then rejects it with
/// `invalid(decodeError)` (and advances the client's cseq so one bad op cannot wedge the queue).
public struct IncomingOp: Hashable, Sendable {
    public var cseq: Int
    public var base: Int
    public var op: Op?
    public var decodeError: String?
    public init(cseq: Int, base: Int, op: Op) {
        self.cseq = cseq
        self.base = base
        self.op = op
    }
    public init(cseq: Int, base: Int, decodeError: String) {
        self.cseq = cseq
        self.base = base
        self.decodeError = decodeError
    }
}

/// `POST /v1/docs/{doc}/ops`
public struct SubmitRequest: Hashable, Codable, Sendable {
    public var client: ClientID
    /// "I will never send a cseq below this": the server treats every cseq below as handled
    /// (abandoned if it was never committed or rejected). Used after losing the outbox.
    public var floor: Int?
    /// Ask for the fate of this client's cseqs in `[resolveFrom, high]`.
    public var resolveFrom: Int?
    public var ops: [IncomingOp]
    public init(client: ClientID, floor: Int? = nil, resolveFrom: Int? = nil, ops: [IncomingOp] = []) {
        self.client = client
        self.floor = floor
        self.resolveFrom = resolveFrom
        self.ops = ops
    }
}

public enum OpResult: Hashable, Sendable {
    /// Committed (now or earlier) at global sequence `seq`.
    case ack(cseq: Int, seq: Int)
    case reject(cseq: Int, reason: RejectReason)
    /// Not processed: an earlier cseq of this client has not been handled yet. Resend from `expected`.
    case gap(cseq: Int, expected: Int)

    public var cseq: Int {
        switch self {
        case .ack(let c, _), .reject(let c, _), .gap(let c, _): return c
        }
    }
}

public struct KnownOutcomes: Hashable, Sendable {
    public var committed: [Int: Int] = [:]
    public var rejected: [Int: RejectReason] = [:]
    public init(committed: [Int: Int] = [:], rejected: [Int: RejectReason] = [:]) {
        self.committed = committed
        self.rejected = rejected
    }
}

public struct SubmitResponse: Hashable, Codable, Sendable {
    /// Server head (last committed seq) after processing the batch.
    public var head: Int
    /// Highest cseq of this client the server has handled (committed, rejected or abandoned).
    public var high: Int
    public var results: [OpResult]
    /// Present iff the request had `resolveFrom`.
    public var known: KnownOutcomes?
    public init(head: Int, high: Int, results: [OpResult], known: KnownOutcomes? = nil) {
        self.head = head
        self.high = high
        self.results = results
        self.known = known
    }
}

/// Full state at `seq`, sent when a client cannot be caught up from the log.
public struct SnapshotEvent: Hashable, Sendable {
    public var seq: Int
    public var doc: Document
    /// cseq -> seq of the requesting client's ops committed at or before `seq` (cseq >= the `from` query).
    public var committed: [Int: Int]
    public init(seq: Int, doc: Document, committed: [Int: Int] = [:]) {
        self.seq = seq
        self.doc = doc
        self.committed = committed
    }
}

/// What the SSE stream carries.
public enum StreamEvent: Hashable, Sendable {
    case snapshot(SnapshotEvent)
    case commit(LogEntry)
    /// Catch-up finished; everything up to `head` (as of subscription) has been delivered.
    case ready(head: Int)
    /// Keep-alive (an SSE comment line on the wire).
    case ping
}

/// `GET /v1/docs/{doc}/events` parameters.
public struct StreamOpen: Hashable, Sendable {
    public var client: ClientID?
    /// `Last-Event-ID`: the last seq the client applied. nil = no state, send a snapshot.
    public var lastEventId: Int?
    /// Lowest unresolved cseq of this client (limits the `committed` map of a snapshot event).
    public var from: Int?
    /// Client-side stream generation (not sent on the wire; lets drivers ignore events of dead streams).
    public var generation: Int
    public init(client: ClientID?, lastEventId: Int?, from: Int?, generation: Int = 0) {
        self.client = client
        self.lastEventId = lastEventId
        self.from = from
        self.generation = generation
    }
}

/// How the server answers a stream open.
public enum ResumePlan: Equatable, Sendable {
    /// Send entries `(after, head]` from the log.
    case replay(after: Int)
    /// Send a full snapshot at head.
    case snapshot
}

public func resumePlan(lastEventId: Int?, head: Int, maxReplay: Int) -> ResumePlan {
    guard let last = lastEventId, last >= 0, last <= head, head - last <= maxReplay else { return .snapshot }
    return .replay(after: last)
}
