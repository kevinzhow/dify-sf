public struct Node: Hashable, Codable, Sendable {
    public var id: NodeID
    public var type: String
    public var title: String
    public var x: Int
    public var y: Int
    public var config: [String: Value]

    public init(id: NodeID, type: String, title: String = "", x: Int = 0, y: Int = 0,
                config: [String: Value] = [:]) {
        self.id = id
        self.type = type
        self.title = title
        self.x = x
        self.y = y
        self.config = config
    }
}

public struct Edge: Hashable, Codable, Sendable {
    public var id: EdgeID
    public var source: NodeID
    public var sourceHandle: String
    public var target: NodeID
    public var targetHandle: String

    public init(id: EdgeID, source: NodeID, sourceHandle: String = "out",
                target: NodeID, targetHandle: String = "in") {
        self.id = id
        self.source = source
        self.sourceHandle = sourceHandle
        self.target = target
        self.targetHandle = targetHandle
    }
}

/// A versioned location inside a node. Each one is a last-writer-wins register guarded by the
/// stale-write rule (see `Document.validate`).
public enum FieldKey: Hashable, Codable, Sendable {
    case title
    case position
    case config([String])

    /// Config paths overlap when one is a prefix of the other (`model` vs `model.name`).
    public func overlaps(_ other: FieldKey) -> Bool {
        switch (self, other) {
        case (.title, .title), (.position, .position): return true
        case (.config(let a), .config(let b)):
            let n = min(a.count, b.count)
            return a.prefix(n) == b.prefix(n)
        default: return false
        }
    }
}

/// The small edit vocabulary. Clients never send graph snapshots.
public enum Op: Hashable, Codable, Sendable {
    case addNode(Node)
    case removeNode(NodeID)
    case moveNode(NodeID, x: Int, y: Int)
    /// `.title` or `.config(path)`; position goes through `moveNode`.
    case setField(NodeID, FieldKey, Value)
    case addEdge(Edge)
    case removeEdge(EdgeID)
}

/// Server version stamp: which committed op (global sequence) last wrote something, and who.
public struct Stamp: Hashable, Codable, Sendable {
    public var seq: Int
    public var client: ClientID
    public init(seq: Int, client: ClientID) {
        self.seq = seq
        self.client = client
    }
}

/// Details of a stale-write conflict: the newer write that the rejected op would have overwritten.
public struct Conflict: Hashable, Codable, Sendable {
    public var node: NodeID
    /// nil = the whole node (delete vs. any modification).
    public var field: FieldKey?
    public var seq: Int
    public var by: ClientID
}

/// Why the server (or a client's local pre-check) refused an op. Always delivered to the sender.
public enum RejectReason: Error, Hashable, Codable, Sendable {
    /// Someone else wrote this field/node after the op's base version; the newer value is kept.
    case conflict(Conflict)
    case nodeDeleted(NodeID)
    case nodeNotFound(NodeID)
    case nodeExists(NodeID)
    case edgeNotFound(EdgeID)
    case edgeExists(EdgeID)
    case duplicateEdge(EdgeID)
    case danglingReference(NodeID)
    case invalid(String)
    /// Duplicate of a cseq the server handled but never committed (and no longer remembers why).
    case notCommitted

    /// Reasons that are certain to repeat on the server, so a client may warn the user early.
    public var isStaleBased: Bool {
        switch self {
        case .conflict, .nodeDeleted, .danglingReference: return true
        default: return false
        }
    }
}

/// Deliberate protocol bugs, used only by mutation tests to prove the invariant checks can fail.
public struct ProtocolDefects: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Server skips the stale-write check (plain last-writer-wins).
    public static let skipStaleCheck = ProtocolDefects(rawValue: 1 << 0)
    /// Deleting a node leaves dangling references instead of broken markers.
    public static let skipBrokenMarkers = ProtocolDefects(rawValue: 1 << 1)
    /// Client sends each op once and never retransmits or resends on reconnect.
    public static let clientNeverResends = ProtocolDefects(rawValue: 1 << 2)
    /// Server does not de-duplicate by (client, cseq): retransmits are committed twice.
    public static let noDedup = ProtocolDefects(rawValue: 1 << 3)
}
