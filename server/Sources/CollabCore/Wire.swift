/// JSON encoding of the protocol (docs/protocol.md). Hand-written so that the wire format is explicit and
/// stable instead of depending on the compiler's synthesized enum encoding.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func bad(_ c: DecodingError.Context) -> DecodingError { .dataCorrupted(c) }

// MARK: - Value

extension Value: Codable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .int(let i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .list(let xs):
            var c = encoder.unkeyedContainer()
            for x in xs { try c.encode(x) }
        case .ref(let r):
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(r, forKey: DynamicKey("$ref"))
        case .brokenRef(let r):
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(r, forKey: DynamicKey("$broken"))
        case .items(let items):
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(items, forKey: DynamicKey("$items"))
        case .map(let m):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for k in m.keys.sorted() { try c.encode(m[k]!, forKey: DynamicKey(k)) }
        }
    }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            let keys = keyed.allKeys.map(\.stringValue)
            if keys == ["$ref"] { self = .ref(try keyed.decode(OutputRef.self, forKey: DynamicKey("$ref"))); return }
            if keys == ["$broken"] { self = .brokenRef(try keyed.decode(OutputRef.self, forKey: DynamicKey("$broken"))); return }
            if keys == ["$items"] { self = .items(try keyed.decode([Item].self, forKey: DynamicKey("$items"))); return }
            var m: [String: Value] = [:]
            for k in keyed.allKeys {
                guard !k.stringValue.hasPrefix("$") else {
                    throw bad(.init(codingPath: decoder.codingPath, debugDescription: "reserved map key \(k.stringValue)"))
                }
                m[k.stringValue] = try keyed.decode(Value.self, forKey: k)
            }
            self = .map(m)
            return
        }
        if var arr = try? decoder.unkeyedContainer() {
            var xs: [Value] = []
            while !arr.isAtEnd { xs.append(try arr.decode(Value.self)) }
            self = .list(xs)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw bad(.init(codingPath: decoder.codingPath, debugDescription: "unsupported value (numbers must be 64-bit integers)"))
    }
}

// MARK: - Plain structs

// MARK: - FieldKey

extension FieldKey: Codable {
    enum CodingKeys: String, CodingKey { case k, path, id }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .title: try c.encode("title", forKey: .k)
        case .config(let p):
            try c.encode("config", forKey: .k)
            try c.encode(p, forKey: .path)
        case .item(let p, let id):
            try c.encode("item", forKey: .k)
            try c.encode(p, forKey: .path)
            try c.encode(id, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .k) {
        case "title": self = .title
        case "config": self = .config(try c.decode([String].self, forKey: .path))
        case "item": self = .item(try c.decode([String].self, forKey: .path), try c.decode(String.self, forKey: .id))
        case let other: throw bad(.init(codingPath: c.codingPath, debugDescription: "unknown field kind \(other)"))
        }
    }
}

// MARK: - Op

extension Op: Codable {
    enum CodingKeys: String, CodingKey { case t, node, edge, x, y, field, value, path, item, itemId, after }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addNode(let n):
            try c.encode("addNode", forKey: .t)
            try c.encode(n, forKey: .node)
        case .removeNode(let id):
            try c.encode("removeNode", forKey: .t)
            try c.encode(id, forKey: .node)
        case .moveNode(let id, let x, let y):
            try c.encode("moveNode", forKey: .t)
            try c.encode(id, forKey: .node)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .setField(let id, let f, let v):
            try c.encode("setField", forKey: .t)
            try c.encode(id, forKey: .node)
            try c.encode(f, forKey: .field)
            try c.encode(v, forKey: .value)
        case .addEdge(let e):
            try c.encode("addEdge", forKey: .t)
            try c.encode(e, forKey: .edge)
        case .removeEdge(let id):
            try c.encode("removeEdge", forKey: .t)
            try c.encode(id, forKey: .edge)
        case .insertItem(let id, let path, let item, let after):
            try c.encode("insertItem", forKey: .t)
            try c.encode(id, forKey: .node)
            try c.encode(path, forKey: .path)
            try c.encode(item, forKey: .item)
            try c.encode(after, forKey: .after)
        case .removeItem(let id, let path, let itemId):
            try c.encode("removeItem", forKey: .t)
            try c.encode(id, forKey: .node)
            try c.encode(path, forKey: .path)
            try c.encode(itemId, forKey: .itemId)
        case .updateItem(let id, let path, let itemId, let v):
            try c.encode("updateItem", forKey: .t)
            try c.encode(id, forKey: .node)
            try c.encode(path, forKey: .path)
            try c.encode(itemId, forKey: .itemId)
            try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "addNode": self = .addNode(try c.decode(Node.self, forKey: .node))
        case "removeNode": self = .removeNode(try c.decode(String.self, forKey: .node))
        case "moveNode":
            self = .moveNode(try c.decode(String.self, forKey: .node), x: try c.decode(Int.self, forKey: .x),
                             y: try c.decode(Int.self, forKey: .y))
        case "setField":
            self = .setField(try c.decode(String.self, forKey: .node), try c.decode(FieldKey.self, forKey: .field),
                             try c.decode(Value.self, forKey: .value))
        case "addEdge": self = .addEdge(try c.decode(Edge.self, forKey: .edge))
        case "removeEdge": self = .removeEdge(try c.decode(String.self, forKey: .edge))
        case "insertItem":
            self = .insertItem(try c.decode(String.self, forKey: .node), path: try c.decode([String].self, forKey: .path),
                               item: try c.decode(Item.self, forKey: .item),
                               after: try c.decodeIfPresent(String.self, forKey: .after))
        case "removeItem":
            self = .removeItem(try c.decode(String.self, forKey: .node), path: try c.decode([String].self, forKey: .path),
                               id: try c.decode(String.self, forKey: .itemId))
        case "updateItem":
            self = .updateItem(try c.decode(String.self, forKey: .node), path: try c.decode([String].self, forKey: .path),
                               id: try c.decode(String.self, forKey: .itemId), value: try c.decode(Value.self, forKey: .value))
        case let other: throw bad(.init(codingPath: c.codingPath, debugDescription: "unknown op type \(other)"))
        }
    }
}

// MARK: - RejectReason

extension RejectReason: Codable {
    enum CodingKeys: String, CodingKey { case type, node, edge, item, field, seq, by, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .type)
        switch self {
        case .conflict(let x):
            try c.encode(x.node, forKey: .node)
            try c.encode(x.field, forKey: .field)
            try c.encode(x.seq, forKey: .seq)
            try c.encode(x.by, forKey: .by)
        case .nodeDeleted(let n), .nodeNotFound(let n), .nodeExists(let n), .danglingReference(let n):
            try c.encode(n, forKey: .node)
        case .edgeNotFound(let e), .edgeExists(let e), .duplicateEdge(let e):
            try c.encode(e, forKey: .edge)
        case .itemNotFound(let i), .itemDeleted(let i), .itemExists(let i):
            try c.encode(i, forKey: .item)
        case .invalid(let m): try c.encode(m, forKey: .message)
        case .notCommitted, .clientIdInUse: break
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "conflict":
            self = .conflict(Conflict(node: try c.decode(String.self, forKey: .node),
                                      field: try c.decodeIfPresent(FieldKey.self, forKey: .field),
                                      seq: try c.decode(Int.self, forKey: .seq), by: try c.decode(String.self, forKey: .by)))
        case "nodeDeleted": self = .nodeDeleted(try c.decode(String.self, forKey: .node))
        case "nodeNotFound": self = .nodeNotFound(try c.decode(String.self, forKey: .node))
        case "nodeExists": self = .nodeExists(try c.decode(String.self, forKey: .node))
        case "danglingReference": self = .danglingReference(try c.decode(String.self, forKey: .node))
        case "edgeNotFound": self = .edgeNotFound(try c.decode(String.self, forKey: .edge))
        case "edgeExists": self = .edgeExists(try c.decode(String.self, forKey: .edge))
        case "duplicateEdge": self = .duplicateEdge(try c.decode(String.self, forKey: .edge))
        case "itemNotFound": self = .itemNotFound(try c.decode(String.self, forKey: .item))
        case "itemDeleted": self = .itemDeleted(try c.decode(String.self, forKey: .item))
        case "itemExists": self = .itemExists(try c.decode(String.self, forKey: .item))
        case "invalid": self = .invalid(try c.decode(String.self, forKey: .message))
        case "notCommitted": self = .notCommitted
        case "clientIdInUse": self = .clientIdInUse
        case let other: throw bad(.init(codingPath: c.codingPath, debugDescription: "unknown reject type \(other)"))
        }
    }
}

// MARK: - Document

extension Document: Codable {
    enum CodingKeys: String, CodingKey {
        case nodes, edges, deletedNodes, deletedEdges, deletedItems, fieldStamps, touches
    }
    struct FieldStampRow: Codable { var node: NodeID; var field: FieldKey; var seq: Int; var client: ClientID }
    struct TouchRow: Codable { var node: NodeID; var client: ClientID; var seq: Int }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodes.keys.sorted().map { nodes[$0]! }, forKey: .nodes)
        try c.encode(edges.keys.sorted().map { edges[$0]! }, forKey: .edges)
        try c.encode(deletedNodes, forKey: .deletedNodes)
        try c.encode(deletedEdges, forKey: .deletedEdges)
        try c.encode(deletedItems, forKey: .deletedItems)
        var rows: [FieldStampRow] = []
        for n in fieldStamps.keys.sorted() {
            for (k, s) in (fieldStamps[n] ?? [:]).sorted(by: { Self.keyOrder($0.key) < Self.keyOrder($1.key) }) {
                rows.append(FieldStampRow(node: n, field: k, seq: s.seq, client: s.client))
            }
        }
        try c.encode(rows, forKey: .fieldStamps)
        var trows: [TouchRow] = []
        for n in touches.keys.sorted() {
            for cl in (touches[n] ?? [:]).keys.sorted() { trows.append(TouchRow(node: n, client: cl, seq: touches[n]![cl]!)) }
        }
        try c.encode(trows, forKey: .touches)
    }

    private static func keyOrder(_ k: FieldKey) -> String {
        switch k {
        case .title: return "0"
        case .config(let p): return "1/" + p.joined(separator: "\u{1}")
        case .item(let p, let id): return "2/" + p.joined(separator: "\u{1}") + "\u{2}" + id
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var stamps: [NodeID: [FieldKey: Stamp]] = [:]
        for r in try c.decode([FieldStampRow].self, forKey: .fieldStamps) {
            stamps[r.node, default: [:]][r.field] = Stamp(seq: r.seq, client: r.client)
        }
        var touches: [NodeID: [ClientID: Int]] = [:]
        for r in try c.decode([TouchRow].self, forKey: .touches) { touches[r.node, default: [:]][r.client] = r.seq }
        self.init(nodes: try c.decode([Node].self, forKey: .nodes), edges: try c.decode([Edge].self, forKey: .edges),
                  deletedNodes: try c.decode([NodeID: Stamp].self, forKey: .deletedNodes),
                  deletedEdges: try c.decode([EdgeID: Stamp].self, forKey: .deletedEdges),
                  deletedItems: try c.decode([ItemID: Stamp].self, forKey: .deletedItems),
                  fieldStamps: stamps, touches: touches)
    }
}

// MARK: - Log entries, requests, responses, events

private func encodeIntMap<V: Encodable>(_ m: [Int: V], _ c: inout KeyedEncodingContainer<DynamicKey>, _ key: String) throws {
    var sub = c.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(key))
    for k in m.keys.sorted() { try sub.encode(m[k]!, forKey: DynamicKey(String(k))) }
}

private func decodeIntMap<V: Decodable>(_ type: V.Type, _ c: KeyedDecodingContainer<DynamicKey>, _ key: String) throws -> [Int: V] {
    guard c.contains(DynamicKey(key)) else { return [:] }
    let sub = try c.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(key))
    var out: [Int: V] = [:]
    for k in sub.allKeys {
        guard let i = Int(k.stringValue) else { throw bad(.init(codingPath: sub.codingPath, debugDescription: "non-integer key")) }
        out[i] = try sub.decode(V.self, forKey: k)
    }
    return out
}

extension KnownOutcomes: Codable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try encodeIntMap(committed, &c, "committed")
        try encodeIntMap(rejected, &c, "rejected")
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.init(committed: try decodeIntMap(Int.self, c, "committed"), rejected: try decodeIntMap(RejectReason.self, c, "rejected"))
    }
}

extension OpResult: Codable {
    enum CodingKeys: String, CodingKey { case cseq, status, seq, reason, expected }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ack(let cs, let seq):
            try c.encode(cs, forKey: .cseq); try c.encode("ack", forKey: .status); try c.encode(seq, forKey: .seq)
        case .reject(let cs, let r):
            try c.encode(cs, forKey: .cseq); try c.encode("reject", forKey: .status); try c.encode(r, forKey: .reason)
        case .gap(let cs, let e):
            try c.encode(cs, forKey: .cseq); try c.encode("gap", forKey: .status); try c.encode(e, forKey: .expected)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cs = try c.decode(Int.self, forKey: .cseq)
        switch try c.decode(String.self, forKey: .status) {
        case "ack": self = .ack(cseq: cs, seq: try c.decode(Int.self, forKey: .seq))
        case "reject": self = .reject(cseq: cs, reason: try c.decode(RejectReason.self, forKey: .reason))
        case "gap": self = .gap(cseq: cs, expected: try c.decode(Int.self, forKey: .expected))
        case let other: throw bad(.init(codingPath: c.codingPath, debugDescription: "unknown status \(other)"))
        }
    }
}

extension IncomingOp: Codable {
    enum CodingKeys: String, CodingKey { case cseq, base, op }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cseq, forKey: .cseq)
        try c.encode(base, forKey: .base)
        if let op { try c.encode(op, forKey: .op) }
    }
    /// Lenient on the op itself: an un-decodable op becomes `decodeError` instead of failing the whole batch.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cs = try c.decode(Int.self, forKey: .cseq)
        let base = try c.decode(Int.self, forKey: .base)
        do {
            self.init(cseq: cs, base: base, op: try c.decode(Op.self, forKey: .op))
        } catch {
            self.init(cseq: cs, base: base, decodeError: Self.describe(error))
        }
    }
    private static func describe(_ e: Error) -> String {
        if let d = e as? DecodingError {
            switch d {
            case .dataCorrupted(let c): return c.debugDescription
            case .keyNotFound(let k, _): return "missing key \(k.stringValue)"
            case .typeMismatch(_, let c), .valueNotFound(_, let c): return c.debugDescription
            @unknown default: return "malformed op"
            }
        }
        return "malformed op"
    }
}

extension SnapshotEvent: Codable {
    enum CodingKeys: String, CodingKey { case seq, doc, committed }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(doc, forKey: .doc)
        var d = encoder.container(keyedBy: DynamicKey.self)
        try encodeIntMap(committed, &d, "committed")
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = try decoder.container(keyedBy: DynamicKey.self)
        self.init(seq: try c.decode(Int.self, forKey: .seq), doc: try c.decode(Document.self, forKey: .doc),
                  committed: try decodeIntMap(Int.self, d, "committed"))
    }
}

/// `GET /v1/docs/{doc}/snapshot` body.
public struct SnapshotResponse: Hashable, Codable, Sendable {
    public var seq: Int
    public var doc: Document
    public init(seq: Int, doc: Document) {
        self.seq = seq
        self.doc = doc
    }
}

/// Convenience JSON coding with the settings the protocol assumes (sorted keys for reproducibility).
public enum WireJSON {
    public static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(v)
    }
    public static func encodeString<T: Encodable>(_ v: T) throws -> String {
        String(decoding: try encode(v), as: UTF8.self)
    }
    public static func decode<T: Decodable>(_ t: T.Type, from d: Data) throws -> T { try JSONDecoder().decode(t, from: d) }
    public static func decode<T: Decodable>(_ t: T.Type, from s: String) throws -> T { try decode(t, from: Data(s.utf8)) }
}

// MARK: - SSE framing

extension StreamEvent {
    /// The SSE `event:` name.
    public var eventName: String {
        switch self {
        case .snapshot: return "snapshot"
        case .commit: return "commit"
        case .ready: return "ready"
        case .ping: return "ping"
        }
    }

    /// The SSE `id:` (global seq) for events that advance the resume point.
    public var eventId: Int? {
        switch self {
        case .snapshot(let s): return s.seq
        case .commit(let e): return e.seq
        case .ready, .ping: return nil
        }
    }

    /// Serialises to the exact bytes of one SSE frame (`ping` is a comment line).
    public func sseFrame() throws -> String {
        switch self {
        case .ping: return ": ping\n\n"
        case .ready(let head): return "event: ready\ndata: {\"head\":\(head)}\n\n"
        case .snapshot(let s): return "id: \(s.seq)\nevent: snapshot\ndata: \(try WireJSON.encodeString(s))\n\n"
        case .commit(let e): return "id: \(e.seq)\nevent: commit\ndata: \(try WireJSON.encodeString(e))\n\n"
        }
    }

    /// Inverse of `sseFrame` for a parsed SSE message (event name + data); nil for unknown events (ignored).
    public static func parse(event: String, data: String) throws -> StreamEvent? {
        switch event {
        case "commit": return .commit(try WireJSON.decode(LogEntry.self, from: data))
        case "snapshot": return .snapshot(try WireJSON.decode(SnapshotEvent.self, from: data))
        case "ready":
            struct Ready: Decodable { var head: Int }
            return .ready(head: try WireJSON.decode(Ready.self, from: data).head)
        default: return nil
        }
    }
}
