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

    /// Same endpoints and handles (two such edges would be duplicates).
    public func sameConnection(_ o: Edge) -> Bool {
        source == o.source && sourceHandle == o.sourceHandle && target == o.target && targetHandle == o.targetHandle
    }
}

/// A versioned content location inside a node. Each one is a register guarded by the stale-write rule
/// (see `Document.validate`). Node position is deliberately NOT a register: layout is last-writer-wins.
public enum FieldKey: Hashable, Sendable {
    case title
    case config([String])
    /// One element of the keyed list at `path`.
    case item([String], ItemID)

    /// Two registers overlap when writing one can change the other:
    /// config paths overlap when one is a prefix of the other (`model` vs `model.name`); a config path
    /// overlaps every item of a list located at or below it; items overlap only when identical.
    public func overlaps(_ other: FieldKey) -> Bool {
        switch (self, other) {
        case (.title, .title): return true
        case (.config(let a), .config(let b)): return Self.prefixRelated(a, b)
        case (.config(let a), .item(let b, _)), (.item(let b, _), .config(let a)): return Self.prefixRelated(a, b)
        case (.item(let p, let i), .item(let q, let j)): return p == q && i == j
        default: return false
        }
    }

    private static func prefixRelated(_ a: [String], _ b: [String]) -> Bool {
        let n = min(a.count, b.count)
        return a.prefix(n) == b.prefix(n)
    }
}

/// The small edit vocabulary. Clients never send graph snapshots.
public enum Op: Hashable, Sendable {
    case addNode(Node)
    case removeNode(NodeID)
    /// Layout: last writer wins, applied in server order, never rejected for staleness.
    case moveNode(NodeID, x: Int, y: Int)
    /// `.title` or `.config(path)`; list items go through the item ops, position through `moveNode`.
    case setField(NodeID, FieldKey, Value)
    case addEdge(Edge)
    case removeEdge(EdgeID)
    /// Inserts `item` into the keyed list at `path` right after item `after` (nil = at the front).
    /// If `after` no longer exists the item is appended. Creates the list if absent.
    case insertItem(NodeID, path: [String], item: Item, after: ItemID?)
    case removeItem(NodeID, path: [String], id: ItemID)
    /// Replaces the value of one item.
    case updateItem(NodeID, path: [String], id: ItemID, value: Value)
    /// Protocol 1.6: brings a deleted node back (undo of a delete), with the edges its delete removed (original ids).
    /// The node id and those edge ids leave the tombstones; `$broken` references to the node turn back into references.
    /// See `Document.validate` and docs/protocol.md ("Restore").
    case restoreNode(Node, edges: [Edge])
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
public struct Conflict: Hashable, Sendable {
    public var node: NodeID
    /// nil = the whole node (delete vs. any modification).
    public var field: FieldKey?
    public var seq: Int
    public var by: ClientID
    /// Display name of `by`, when the author registered one (protocol 1.3). Filled in by the server's HTTP layer only.
    public var byName: String?
    public init(node: NodeID, field: FieldKey?, seq: Int, by: ClientID, byName: String? = nil) {
        self.node = node
        self.field = field
        self.seq = seq
        self.by = by
        self.byName = byName
    }
}

/// Why the server (or a client's local pre-check) refused an op. Always delivered to the sender.
public enum RejectReason: Error, Hashable, Sendable {
    /// Someone else wrote this field/node after the op's base version (with a different value); the newer value is kept.
    case conflict(Conflict)
    case nodeDeleted(NodeID)
    case nodeNotFound(NodeID)
    case nodeExists(NodeID)
    case edgeNotFound(EdgeID)
    case edgeExists(EdgeID)
    case duplicateEdge(EdgeID)
    case danglingReference(NodeID)
    case itemNotFound(ItemID)
    case itemDeleted(ItemID)
    case itemExists(ItemID)
    case invalid(String)
    /// The idempotency key (client, cseq) was already used for a DIFFERENT op: another process is using this client id.
    case clientIdInUse
    /// Duplicate of a cseq the server handled but never committed (abandoned below a client's `floor`).
    case notCommitted

    /// Reasons that are certain to repeat on the server, so a client may warn the user early.
    public var isStaleBased: Bool {
        switch self {
        case .conflict, .nodeDeleted, .danglingReference, .itemDeleted: return true
        default: return false
        }
    }

    /// Stable machine-readable name (used in the wire format and in statistics).
    public var name: String {
        switch self {
        case .conflict: return "conflict"
        case .nodeDeleted: return "nodeDeleted"
        case .nodeNotFound: return "nodeNotFound"
        case .nodeExists: return "nodeExists"
        case .edgeNotFound: return "edgeNotFound"
        case .edgeExists: return "edgeExists"
        case .duplicateEdge: return "duplicateEdge"
        case .danglingReference: return "danglingReference"
        case .itemNotFound: return "itemNotFound"
        case .itemDeleted: return "itemDeleted"
        case .itemExists: return "itemExists"
        case .invalid: return "invalid"
        case .clientIdInUse: return "clientIdInUse"
        case .notCommitted: return "notCommitted"
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
    /// Client sends each op once and never retransmits.
    public static let clientNeverResends = ProtocolDefects(rawValue: 1 << 2)
    /// Server does not de-duplicate by (client, cseq): retransmits are committed twice.
    public static let noDedup = ProtocolDefects(rawValue: 1 << 3)
    /// Server treats every stale same-value write as a conflict anyway (violates the same-value rule).
    public static let sameValueConflicts = ProtocolDefects(rawValue: 1 << 4)
    /// An accepted equal-value write takes over the register's stamp (the TLA+ counterexample: it launders the same
    /// client's next stale write).
    public static let equalValueRestamps = ProtocolDefects(rawValue: 1 << 5)
    /// A restore does not version the restored node (no stamps, no touch): a stale writer that never saw the restore can
    /// overwrite it, and a stale delete can destroy it.
    public static let restoreSkipsStamps = ProtocolDefects(rawValue: 1 << 6)
    /// A restore re-creates its edges even when the other endpoint is deleted (edges to missing nodes).
    public static let restoreIgnoresEndpoints = ProtocolDefects(rawValue: 1 << 7)
}
