/// Replacing a whole document (`POST /v1/docs/{doc}/replace`, docs/protocol.md section 2, "Replacing a document"): the
/// ordinary ops that turn the document at head into another one, so that a replacement is committed, streamed, versioned
/// and conflict-checked like any edit.
///
/// The op vocabulary cannot do everything, which fixes the identity rules (`freshIdsNeeded`):
/// * ids are never reused, so a target node or edge whose id is tombstoned needs a fresh id;
/// * a node's type cannot change and a config key cannot be removed, so a live node with the target's id but another type,
///   or with a config key the target node does not have, is deleted and the target node gets a fresh id;
/// * edges are immutable, so a live edge with the target's id but other endpoints or handles is deleted and the target edge
///   gets a fresh id (as does every edge that touches a node that gets one).
/// Choosing the fresh ids (and rewriting what refers to them) is the caller's business: it depends on the file format.
///
/// Values: clients never write broken markers (`$broken`), so a broken reference of the target is written as the plain
/// `[node, output]` pair it stands for (`writable`): what a Dify export renders for either. Comparisons treat the two alike.
public enum Replacement {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// The target ids that cannot be kept (see the type's documentation).
    public static func freshIdsNeeded(current: Document, target: Document) -> (nodes: Set<NodeID>, edges: Set<EdgeID>) {
        var nodes = Set<NodeID>()
        for (id, t) in target.nodes {
            if current.deletedNodes[id] != nil { nodes.insert(id); continue }
            guard let c = current.nodes[id] else { continue }
            if c.type != t.type || !Set(c.config.keys).isSubset(of: t.config.keys) { nodes.insert(id) }
        }
        var edges = Set<EdgeID>()
        for (id, t) in target.edges {
            if current.deletedEdges[id] != nil { edges.insert(id); continue }
            if nodes.contains(t.source) || nodes.contains(t.target) { if current.edges[id] != nil { edges.insert(id) }; continue }
            if let c = current.edges[id], c != t { edges.insert(id) }
        }
        return (nodes, edges)
    }

    /// Whether `id` is unusable as a fresh node id: live, tombstoned, reserved, or used by `target`.
    public static func nodeIdTaken(_ id: NodeID, current: Document, target: Document) -> Bool {
        id.isEmpty || id.hasPrefix("$") || current.nodes[id] != nil || current.deletedNodes[id] != nil || target.nodes[id] != nil
    }

    /// Whether `id` is unusable as a fresh edge id: live, tombstoned, or used by `target`.
    public static func edgeIdTaken(_ id: EdgeID, current: Document, target: Document) -> Bool {
        id.isEmpty || current.edges[id] != nil || current.deletedEdges[id] != nil || target.edges[id] != nil
    }

    /// Broken markers as the plain `[node, output]` pairs they stand for (clients cannot write markers).
    public static func writable(_ v: Value) -> Value {
        switch v {
        case .brokenRef(let r): return .list([.string(r.node), .string(r.output)])
        case .list(let xs): return .list(xs.map(writable))
        case .items(let xs): return .items(xs.map { Item(id: $0.id, value: writable($0.value)) })
        case .map(let m): return .map(m.mapValues(writable))
        default: return v
        }
    }

    /// The ops, in order, that turn `current` (the document at `base`) into `target`, as written by `client`: every op is
    /// valid when its predecessors are applied (validated here with `base`, so committing them in one batch with that base
    /// cannot be refused), and the result has `target`'s content (nodes, edges, document-level registers; tombstones and
    /// version stamps are history). Requires `freshIdsNeeded(current, target)` to be empty.
    ///
    /// Order: edge and node removals; then, retried until nothing is left, the document-level registers, new nodes (config
    /// entries with references to other nodes are written after every node exists), titles, positions, config entries
    /// (`outputs` first, so references find the outputs they name) and new edges. Keyed lists are reconciled item by item
    /// (`removeItem`, `updateItem`, `insertItem`) when the surviving items keep their order, no new item id is tombstoned and
    /// some item survives unchanged (or it takes a single op); otherwise the entry is written whole with `setField`.
    public static func ops(from current: Document, to target: Document, client: ClientID, base: Int) throws(Failure) -> [Op] {
        let fresh = freshIdsNeeded(current: current, target: target)
        guard fresh.nodes.isEmpty, fresh.edges.isEmpty else {
            throw Failure("ids need fresh ids first: \((fresh.nodes.sorted() + fresh.edges.sorted()).joined(separator: ", "))")
        }
        var plan = Planner(doc: current, target: target, client: client, base: base)
        // Removals first: they cannot fail on a consistent document, and they free connections for new edges.
        for id in current.edges.keys.sorted() where target.edges[id] != current.edges[id] {
            try plan.mustApply([.removeEdge(id)])
        }
        for id in current.nodes.keys.sorted() where target.nodes[id] == nil {
            try plan.mustApply([.removeNode(id)])
        }
        var tasks: [Task] = []
        for key in Set(current.app.keys).union(target.app.keys).sorted() { tasks.append(.app(key)) }
        let ids = target.nodes.keys.sorted()
        for id in ids where current.nodes[id] == nil { tasks.append(.addNode(id)) }
        for id in ids { tasks.append(.title(id)); tasks.append(.move(id)) }
        for id in ids where target.nodes[id]!.config[Document.outputsKey] != nil { tasks.append(.config(id, Document.outputsKey)) }
        for id in ids {
            for key in target.nodes[id]!.config.keys.sorted() where key != Document.outputsKey { tasks.append(.config(id, key)) }
        }
        for id in target.edges.keys.sorted() where current.edges[id] == nil { tasks.append(.addEdge(id)) }
        try plan.run(tasks)
        if let d = difference(plan.doc, target) { throw Failure("the replacement does not reach the target: \(d)") }
        return plan.ops
    }

    /// The first content difference between `a` and `b` (nil = same nodes, edges and document-level registers, with broken
    /// markers and plain pairs alike and absent registers equal to empty ones).
    public static func difference(_ a: Document, _ b: Document) -> String? {
        if Set(a.nodes.keys) != Set(b.nodes.keys) {
            return "nodes \(Set(a.nodes.keys).symmetricDifference(b.nodes.keys).sorted())"
        }
        for id in a.nodes.keys.sorted() {
            let x = a.nodes[id]!, y = b.nodes[id]!
            if x.type != y.type || x.title != y.title || x.x != y.x || x.y != y.y { return "node \(id)" }
            for key in Set(x.config.keys).union(y.config.keys).sorted()
            where x.config[key].map(writable) != y.config[key].map(writable) {
                return "node \(id) config \(key)"
            }
        }
        if a.edges != b.edges { return "edges \(Set(a.edges.keys).symmetricDifference(b.edges.keys).sorted())" }
        for key in Set(a.app.keys).union(b.app.keys).sorted() {
            let x = a.app[key].map(writable), y = b.app[key].map(writable)
            if x != y && !(isEmpty(x) && isEmpty(y)) { return "\(Document.appNode).\(key)" }
        }
        return nil
    }

    static func isEmpty(_ v: Value?) -> Bool {
        switch v {
        case nil, .null?: return true
        case .items(let xs)?: return xs.isEmpty
        case .list(let xs)?: return xs.isEmpty
        case .map(let m)?: return m.isEmpty
        default: return false
        }
    }

    enum Task: CustomStringConvertible {
        case app(String), addNode(NodeID), title(NodeID), move(NodeID), config(NodeID, String), addEdge(EdgeID)
        var description: String {
            switch self {
            case .app(let k): return "\(Document.appNode).\(k)"
            case .addNode(let n): return "add node \(n)"
            case .title(let n): return "title of \(n)"
            case .move(let n): return "position of \(n)"
            case .config(let n, let k): return "\(n).\(k)"
            case .addEdge(let e): return "add edge \(e)"
            }
        }
    }

    struct NotYet: Error {}

    struct Planner {
        var doc: Document
        let target: Document
        let client: ClientID
        let base: Int
        var ops: [Op] = []

        init(doc: Document, target: Document, client: ClientID, base: Int) {
            self.doc = doc
            self.target = target
            self.client = client
            self.base = base
        }

        /// Validates and applies `batch` on a copy; adopts it only if every op is valid.
        mutating func tryApply(_ batch: [Op]) throws(RejectReason) {
            guard !batch.isEmpty else { return }
            if batch.count == 1 {  // no copy needed: validation does not mutate
                try doc.validate(batch[0], base: base, by: client)
                doc.apply(batch[0], at: Stamp(seq: base + ops.count + 1, client: client))
                ops.append(batch[0])
                return
            }
            var d = doc
            for (i, op) in batch.enumerated() {
                try d.validate(op, base: base, by: client)
                d.apply(op, at: Stamp(seq: base + ops.count + i + 1, client: client))
            }
            doc = d
            ops += batch
        }

        mutating func mustApply(_ batch: [Op]) throws(Failure) {
            do { try tryApply(batch) } catch { throw Failure("\(batch.first.map { "\($0)" } ?? ""): \(error)") }
        }

        mutating func run(_ tasks: [Task]) throws(Failure) {
            var pending = tasks
            while !pending.isEmpty {
                var left: [Task] = []
                var firstProblem: String?
                for task in pending {
                    do {
                        try tryApply(try opsFor(task))
                    } catch let e as RejectReason {
                        left.append(task)
                        firstProblem = firstProblem ?? "\(task): \(e)"
                    } catch {
                        left.append(task)
                        firstProblem = firstProblem ?? "\(task): waits for its node"
                    }
                }
                if left.count == pending.count { throw Failure("cannot be written with ops: \(firstProblem ?? "")") }
                pending = left
            }
        }

        func opsFor(_ task: Task) throws -> [Op] {
            switch task {
            case .app(let key):
                let cur = doc.app[key]
                guard let tgt = target.app[key] ?? cur.map(Replacement.emptied) else { return [] }
                return register(Document.appNode, key, cur, Replacement.writable(tgt))
            case .addNode(let id):
                guard doc.nodes[id] == nil else { return [] }
                var n = target.nodes[id]!
                // Entries that reference other nodes wait until every node exists (`.config` tasks write them).
                n.config = n.config.mapValues(Replacement.writable).filter { $0.value.liveRefs.allSatisfy { $0.node == id } }
                return [.addNode(n)]
            case .title(let id):
                guard let n = doc.nodes[id] else { throw NotYet() }
                let t = target.nodes[id]!.title
                return n.title == t ? [] : [.setField(id, .title, .string(t))]
            case .move(let id):
                guard let n = doc.nodes[id] else { throw NotYet() }
                let t = target.nodes[id]!
                return n.x == t.x && n.y == t.y ? [] : [.moveNode(id, x: t.x, y: t.y)]
            case .config(let id, let key):
                guard let n = doc.nodes[id] else { throw NotYet() }
                return register(id, key, n.config[key], Replacement.writable(target.nodes[id]!.config[key]!))
            case .addEdge(let id):
                return doc.edges[id] == nil ? [.addEdge(target.edges[id]!)] : []
            }
        }

        /// The ops that make config entry `key` of `node` (`$app`: a document-level register) equal to `tgt`.
        func register(_ node: NodeID, _ key: String, _ cur: Value?, _ tgt: Value) -> [Op] {
            if let cur, Replacement.writable(cur) == tgt { return [] }
            if case .items(let c)? = cur, case .items(let t) = tgt, let ops = itemOps(node, [key], c, t) { return ops }
            return [.setField(node, .config([key]), tgt)]
        }

        func itemOps(_ node: NodeID, _ path: [String], _ c: [Item], _ t: [Item]) -> [Op]? {
            let cIds = Set(c.map(\.id)), tIds = Set(t.map(\.id))
            guard c.map(\.id).filter(tIds.contains) == t.map(\.id).filter(cIds.contains) else { return nil }  // no move op
            guard !t.contains(where: { !cIds.contains($0.id) && doc.deletedItems[$0.id] != nil }) else { return nil }
            let old = Dictionary(uniqueKeysWithValues: c.map { ($0.id, Replacement.writable($0.value)) })
            var ops: [Op] = []
            for i in c where !tIds.contains(i.id) { ops.append(.removeItem(node, path: path, id: i.id)) }
            var unchanged = 0
            for i in t {
                guard let o = old[i.id] else { continue }
                if o == i.value { unchanged += 1 } else { ops.append(.updateItem(node, path: path, id: i.id, value: i.value)) }
            }
            var after: ItemID?
            for i in t {
                if !cIds.contains(i.id) { ops.append(.insertItem(node, path: path, item: i, after: after)) }
                after = i.id
            }
            return unchanged > 0 || ops.count <= 1 ? ops : nil
        }
    }

    /// The empty value of a register's shape (a document-level register the target does not have).
    static func emptied(_ v: Value) -> Value {
        switch v {
        case .items: return .items([])
        case .list: return .list([])
        case .map: return .map([:])
        case .string: return .string("")
        default: return .null
        }
    }
}
