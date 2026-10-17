/// An op as sent by a client. `(client, cseq)` is the idempotency key; `base` is the server version
/// the client had applied when the user made the edit (it never changes on retransmit).
public struct ClientOp: Hashable, Codable, Sendable {
    public var client: ClientID
    public var cseq: Int
    public var base: Int
    public var op: Op
    public init(client: ClientID, cseq: Int, base: Int, op: Op) {
        self.client = client
        self.cseq = cseq
        self.base = base
        self.op = op
    }
}

/// One committed op in the durable, totally ordered log.
public struct LogEntry: Hashable, Codable, Sendable {
    public var seq: Int
    public var client: ClientID
    public var cseq: Int
    public var base: Int
    public var op: Op
    public var stamp: Stamp { Stamp(seq: seq, client: client) }
}

public struct Hello: Hashable, Codable, Sendable {
    public var client: ClientID
    /// Last server seq the client applied; nil = the client holds no state at all.
    public var lastSeq: Int?
    /// The client promises never to send a cseq below this one on this session; the server may
    /// treat everything below as handled. (After a crash that lost the outbox: `nextCseq`.)
    public var willResendFrom: Int
}

public enum ClientMessage: Hashable, Codable, Sendable {
    case hello(Hello)
    case submit(ClientOp)
}

/// Catch-up / join reply. Contains everything the client needs to resolve each of its own ops.
public struct Welcome: Hashable, Codable, Sendable {
    public var head: Int
    /// Present when the client is behind the latest snapshot (or has no state): full graph + seq.
    public var snapshot: SnapshotPayload?
    /// Log entries after max(client.lastSeq, snapshot.seq), in order.
    public var entries: [LogEntry]
    /// Highest cseq of this client the server has handled (committed or rejected).
    public var clientHigh: Int
    /// Known rejections for this client (in server memory only; lost on a server crash).
    public var rejected: [Int: RejectReason]
}

public struct SnapshotPayload: Hashable, Codable, Sendable {
    public var seq: Int
    public var doc: Document
    /// cseq -> seq for this client's ops committed at or before the snapshot.
    public var committedMine: [Int: Int]
}

public enum ServerMessage: Hashable, Codable, Sendable {
    case welcome(Welcome)
    /// Ordered broadcast of committed entries. The originator treats its own entry as the ack.
    case committed([LogEntry])
    case rejected(cseq: Int, reason: RejectReason)
    /// Reply to a retransmit of an already committed op, in case the broadcast was lost.
    case ack(cseq: Int, seq: Int)
    /// The server has no session for you (restart): send `hello` again.
    case resyncRequired
}

public struct Outbound: Hashable, Sendable {
    public var to: ClientID
    public var message: ServerMessage
}
