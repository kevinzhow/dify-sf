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
    /// Server-internal (never on the wire): fingerprint of the op each handled cseq was first used for. A retransmit
    /// with a different fingerprint means two processes share one client id.
    public var fingerprints: [Int: Int64] = [:]
    public init(committed: [Int: Int] = [:], rejected: [Int: RejectReason] = [:], fingerprints: [Int: Int64] = [:]) {
        self.committed = committed
        self.rejected = rejected
        self.fingerprints = fingerprints
    }
}

extension IncomingOp {
    /// Stable 64-bit fingerprint of (base, op) used to recognise a genuine retransmission (FNV-1a over the canonical JSON).
    /// Never 0 (0 means "unknown" in storage).
    public var fingerprint: Int64 {
        let text = op.flatMap { try? WireJSON.encodeString($0) } ?? ""
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in ("\(base)|" + text + (decodeError ?? "")).utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        let v = Int64(bitPattern: h >> 1)
        return v == 0 ? 1 : v
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
    /// `proto` query parameter (protocol 1.6): the protocol version the client implements. nil = a client older than
    /// 1.6. A stream never carries a commit its client cannot decode (`restoreNode` below 1.6, `$app` writes below 1.7;
    /// see `StreamCompat`).
    public var proto: String?
    public init(client: ClientID?, lastEventId: Int?, from: Int?, generation: Int = 0, proto: String? = protocolVersion) {
        self.client = client
        self.lastEventId = lastEventId
        self.from = from
        self.generation = generation
        self.proto = proto
    }
}

/// The protocol version this code implements (docs/protocol.md).
public let protocolVersion = "1.7"

/// Keeping event streams of older clients free of ops they cannot decode. A stream opened without `proto`, or with
/// `proto` < 1.6, never carries a `restoreNode` commit; one with `proto` < 1.7 never carries a commit that writes a
/// document-level register (`Op.touchesApp`). A catch-up range that contains such a commit is answered with a snapshot at
/// head instead of a replay, and a live one ends the stream (the client reconnects and catches up with a snapshot). Both
/// are things every client already handles (protocol section 5).
public enum StreamCompat {
    /// Parses a `proto` value (`major.minor`). nil = not a version (the server answers 400).
    public static func parse(_ proto: String) -> (major: Int, minor: Int)? {
        let parts = proto.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }

    /// True when `proto` names version 1.`minor` or later (nil and unparsable values: never).
    static func atLeast(_ proto: String?, minor: Int) -> Bool {
        guard let p = proto.flatMap(parse) else { return false }
        return p.major > 1 || (p.major == 1 && p.minor >= minor)
    }

    /// True when a stream opened with `proto` may carry `restoreNode` commits (1.6).
    public static func acceptsRestore(_ proto: String?) -> Bool { atLeast(proto, minor: 6) }

    /// True when a stream opened with `proto` may carry commits that write document-level registers (1.7).
    public static func acceptsApp(_ proto: String?) -> Bool { atLeast(proto, minor: 7) }

    /// True when a stream opened with `proto` may carry every commit (its client implements this version or later).
    public static func acceptsAll(_ proto: String?) -> Bool { acceptsRestore(proto) && acceptsApp(proto) }

    /// True when `op` may be sent as a commit event on a stream opened with `proto`.
    public static func streamCarries(_ op: Op, proto: String?) -> Bool {
        if case .restoreNode = op { return acceptsRestore(proto) }
        if op.touchesApp { return acceptsApp(proto) }
        return true
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
