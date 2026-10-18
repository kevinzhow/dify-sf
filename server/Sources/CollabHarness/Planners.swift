import CollabCore

/// What kind of edits a worker's clients make.
public enum PlanKind: String, Codable, Sendable {
    /// Random edits over a small document (chaos runs).
    case chaos
    /// Storm mix (a): only disjoint edits.
    case stormDisjoint
    /// Storm mix (b)/(c): 40% disjoint, 30% same value, 30% different values on shared registers.
    case stormMixed
}

/// Classification of an op used by the ground-truth ledger checks.
public enum EditClass: String, Codable, Sendable {
    case disjoint, sameValue, diffValue, layout, chaos
}

public enum Classifier {
    /// Derives the class from the op itself (so it survives crashes without extra metadata).
    public static func classify(_ op: Op, plan: PlanKind) -> EditClass {
        switch plan {
        case .chaos: return isChaosSameValue(op) ? .sameValue : .chaos
        case .stormDisjoint, .stormMixed:
            switch op {
            case .setField("hot", .config(let p), _) where p.first == "same": return .sameValue
            case .setField("hot", .config(let p), _) where p.first == "diff": return .diffValue
            case .moveNode: return .layout
            default: return .disjoint
            }
        }
    }

    static func isChaosSameValue(_ op: Op) -> Bool {
        if case .setField(_, .config(let p), _) = op, p.first == "hot" { return true }
        return false
    }
}

/// Produces the next edit for one client from its current local view.
public struct EditPlanner: Sendable {
    public let plan: PlanKind
    public let clientIndex: Int
    public let clientCount: Int
    public let clientId: String
    private var rng: Rng
    private var counter = 0

    public init(plan: PlanKind, clientIndex: Int, clientCount: Int, clientId: String, seed: UInt64, counterStart: Int = 0) {
        counter = counterStart
        self.plan = plan
        self.clientIndex = clientIndex
        self.clientCount = clientCount
        self.clientId = clientId
        rng = Rng(seed: seed ^ UInt64(clientIndex) &* 0x9E37_79B9)
    }

    public mutating func nextDelayMillis(min lo: Int, max hi: Int) -> Int { rng.int(lo...hi) }

    public mutating func next(view: Document) -> Op? {
        counter += 1
        switch plan {
        case .chaos: return chaosOp(view)
        case .stormDisjoint: return disjointOp(view)
        case .stormMixed:
            let roll = rng.int(0...99)
            if roll < 40 { return disjointOp(view) }
            let j = rng.int(0...4)
            if roll < 70 { return .setField("hot", .config(["same", "k\(j)"]), .string("V\(j)")) }
            return .setField("hot", .config(["diff", "k\(j)"]), .string("\(clientId)#\(counter)"))
        }
    }

    // MARK: storm: disjoint edits

    private func ownedNodes(_ view: Document) -> [NodeID] {
        view.nodes.keys.filter { StormWorkflow.owner(of: $0, clients: clientCount) == clientIndex }.sorted()
    }

    private mutating func disjointOp(_ view: Document) -> Op? {
        let owned = ownedNodes(view)
        let roll = rng.int(0...99)
        switch roll {
        case 0..<28:
            guard let n = rng.pick(owned) else { return nil }
            return .setField(n, .config(["prompt"]), .string("p \(clientId) #\(counter)"))
        case 28..<38:
            guard let n = rng.pick(owned) else { return nil }
            return .setField(n, .title, .string("title \(clientId) #\(counter)"))
        case 38..<46:
            guard let n = rng.pick(owned) else { return nil }
            return .setField(n, .config(["model", "name"]), .string("m\(rng.int(0...9))-\(clientId)-\(counter)"))
        case 46..<56:
            guard let n = rng.pick(owned) else { return nil }
            return .moveNode(n, x: rng.int(0...5000), y: rng.int(0...5000))
        case 56..<68:
            return .setField("shared", .config(["slots", "s\(clientIndex)"]), .string("\(clientId)#\(counter)"))
        case 68..<84:
            // Insert an item into the shared list, after a random existing item.
            let items = listItems(view)
            let after = items.isEmpty || rng.chance(0.25) ? nil : rng.pick(items)!.id
            return .insertItem("list", path: ["outs"], item: Item(id: "\(clientId)-i\(counter)", value: .map(["name": .string("out\(counter)"), "type": .string("string")])), after: after)
        case 84..<92:
            guard let it = rng.pick(listItems(view).filter { $0.id.hasPrefix("\(clientId)-") }) else { return nil }
            return .updateItem("list", path: ["outs"], id: it.id, value: .map(["name": .string("renamed\(counter)"), "type": .string("number")]))
        default:
            guard let it = rng.pick(listItems(view).filter { $0.id.hasPrefix("\(clientId)-") }) else { return nil }
            return .removeItem("list", path: ["outs"], id: it.id)
        }
    }

    private func listItems(_ view: Document) -> [Item] {
        if case .items(let xs)? = view.nodes["list"]?.config["outs"] { return xs }
        return []
    }

    // MARK: chaos: random edits over a small document

    private static let fieldPool: [[String]] = [["prompt"], ["model"], ["model", "name"], ["model", "temp"], ["code"], ["vars", "a"], ["inputs"]]

    private mutating func chaosOp(_ view: Document) -> Op? {
        let ids = view.nodes.keys.sorted()
        guard !ids.isEmpty else { return nil }
        let node = rng.pick(ids)!
        func items(_ n: NodeID) -> [Item] {
            if case .items(let xs)? = view.nodes[n]?.config["outs"] { return xs }
            return []
        }
        switch rng.int(0...99) {
        case 0..<26:
            let path = rng.pick(Self.fieldPool)!
            let v: Value
            switch rng.int(0...9) {
            case 0: v = .int(rng.int(0...100))
            case 1 where path == ["model"]: v = .map(["name": .string("m\(rng.int(0...9))")])
            case 2: v = .ref(OutputRef(node: rng.pick(ids)!, output: "out"))
            case 3, 4: v = .string("v\(rng.int(0...2))")
            default: v = .string("\(clientId)-\(counter)")
            }
            return .setField(node, .config(path), v)
        case 26..<32: return .setField(node, .title, .string("t\(clientId)\(counter)"))
        case 32..<42: return .moveNode(node, x: rng.int(0...800), y: rng.int(0...800))
        case 42..<47:
            var cfg: [String: Value] = ["prompt": .string("p")]
            if let t = rng.pick(ids), rng.chance(0.4) { cfg["ref"] = .ref(OutputRef(node: t, output: "out")) }
            return .addNode(Node(id: "\(clientId)-n\(counter)", type: "llm", title: "N\(counter)", x: rng.int(0...800), y: rng.int(0...800), config: cfg))
        case 47..<51:
            // Keep the four seed nodes so there is always something to edit.
            guard let victim = rng.pick(ids.filter { $0.contains("-n") }) else { return nil }
            return .removeNode(victim)
        case 51..<60:
            guard let other = rng.pick(ids) else { return nil }
            return .addEdge(Edge(id: "\(clientId)-e\(counter)", source: node, sourceHandle: rng.chance(0.5) ? "out" : "alt", target: other, targetHandle: "in"))
        case 60..<65:
            guard let e = rng.pick(view.edges.keys.sorted()) else { return nil }
            return .removeEdge(e)
        case 65..<70:
            return .setField(node, .config(["inputs"]), .list([.ref(OutputRef(node: rng.pick(ids)!, output: "out"))]))
        case 70..<78:
            let j = rng.int(0...2)
            return .setField(node, .config(["hot", "k\(j)"]), .string("HOT\(j)"))
        case 78..<88:
            let xs = items(node)
            let after = xs.isEmpty || rng.chance(0.3) ? nil : rng.pick(xs)!.id
            return .insertItem(node, path: ["outs"], item: Item(id: "\(clientId)-i\(counter)", value: .string("it\(counter)")), after: after)
        case 88..<93:
            guard let it = rng.pick(items(node)) else { return nil }
            return .removeItem(node, path: ["outs"], id: it.id)
        case 93..<98:
            guard let it = rng.pick(items(node)) else { return nil }
            return .updateItem(node, path: ["outs"], id: it.id, value: .string("u\(rng.int(0...99))"))
        default:
            let fresh = (0..<rng.int(0...3)).map { k in Item(id: "\(clientId)-w\(counter)-\(k)", value: .int(k)) }
            return .setField(node, .config(["outs"]), .items(fresh))
        }
    }
}

/// The storm benchmark's 500-node workflow: mixed node types, real edges, real variable references,
/// plus the shared registers the mixes fight over.
public enum StormWorkflow {
    public static let nodeCount = 500

    /// Which client owns a node for the disjoint edits (nodes the special shared nodes are owned by nobody).
    public static func owner(of id: NodeID, clients: Int) -> Int? {
        guard id.hasPrefix("n"), let n = Int(id.dropFirst()) else { return nil }
        return n % clients
    }

    public static func make(nodes total: Int = nodeCount, clients: Int) -> Document {
        let types = ["start", "llm", "code", "if-else", "http-request", "template-transform", "knowledge-retrieval",
                     "question-classifier", "variable-aggregator", "answer"]
        func id(_ i: Int) -> String { "n\(i)" }
        func ref(_ i: Int, _ out: String) -> Value { .ref(OutputRef(node: id(i), output: out)) }
        var ops: [Op] = []
        let regular = total - 3
        for i in 0..<regular {
            let type = i == 0 ? "start" : types[1 + i % (types.count - 1)]
            var cfg: [String: Value] = ["prompt": .string("Prompt of node \(i)"), "model": .map(["provider": .string("openai"), "name": .string("gpt-4o")])]
            if i > 0 { cfg["context"] = ref(i - 1, "text") }
            if i > 4 { cfg["inputs"] = .list([ref(i - 1, "text"), ref(i - 5, "text")]) }
            switch type {
            case "code":
                cfg["code"] = .string("def main(x):\n    return {'result': x}")
                // Declared outputs (protocol 1.4): `text` is among them, since the next nodes reference `text`.
                cfg["outputs"] = .items((0..<3).map { Item(id: "o\(i)-\($0)", value: .map(["name": .string($0 == 0 ? "text" : "out\($0)"), "type": .string("string")])) })
            case "if-else":
                cfg["cases"] = .items((0..<2).map { Item(id: "c\(i)-\($0)", value: .map(["operator": .string("contains"), "value": .string("v\($0)")])) })
            case "http-request":
                cfg["url"] = .string("https://example.invalid/\(i)")
                cfg["method"] = .string("post")
                cfg["headers"] = .map(["x-node": .string("\(i)")])
            case "template-transform":
                cfg["template"] = .string("Hello {{ arg }}")
                cfg["variables"] = .items([Item(id: "t\(i)-0", value: .map(["name": .string("arg"), "selector": i > 0 ? ref(i - 1, "text") : .null]))])
            default: break
            }
            ops.append(.addNode(Node(id: id(i), type: type, title: "Node \(i)", x: (i % 25) * 220, y: (i / 25) * 160, config: cfg)))
        }
        var edgeN = 0
        for i in 1..<regular {
            ops.append(.addEdge(Edge(id: "e\(edgeN)", source: id(i - 1), target: id(i)))); edgeN += 1
            if i % 7 == 0, i > 3 {
                ops.append(.addEdge(Edge(id: "e\(edgeN)", source: id(i - 3), sourceHandle: "alt", target: id(i)))); edgeN += 1
            }
        }
        ops.append(.addNode(Node(id: "hot", type: "code", title: "Contended registers", x: 0, y: 3000, config: [
            "same": .map(Dictionary(uniqueKeysWithValues: (0..<5).map { ("k\($0)", Value.string("init")) })),
            "diff": .map(Dictionary(uniqueKeysWithValues: (0..<5).map { ("k\($0)", Value.string("init")) })),
        ])))
        ops.append(.addNode(Node(id: "shared", type: "variable-aggregator", title: "Shared node", x: 300, y: 3000, config: [
            "slots": .map(Dictionary(uniqueKeysWithValues: (0..<max(clients, 1)).map { ("s\($0)", Value.string("init")) })),
        ])))
        ops.append(.addNode(Node(id: "list", type: "code", title: "Shared list", x: 600, y: 3000, config: [
            "outs": .items((0..<10).map { Item(id: "seed-\($0)", value: .map(["name": .string("seed\($0)"), "type": .string("string")])) }),
        ])))
        var doc = Document()
        for op in ops { doc.apply(op, at: Stamp(seq: 0, client: "genesis")) }
        return doc
    }
}
