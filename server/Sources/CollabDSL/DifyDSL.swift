import CollabCore
import Foundation
import Yams

/// Dify workflow files (the app DSL, YAML) <-> dify-sf documents.
///
/// Import keeps everything: what the collaboration model understands becomes structure (nodes, edges, keyed lists that
/// can be edited item by item, checked references), everything else rides along unchanged so that an untouched workflow
/// exports to the same file (compared after parsing, ignoring `selected`, which is UI state).
///
/// * Node `data` becomes the node's config, minus `type` and `title` (first-class fields) and `selected`. The node's other
///   top-level fields (sizes, `parentId`, `extent`, `zIndex`, ...) are kept in config `_dify_node`; a fractional position
///   in `_dify_node.position` (the document stores integer coordinates; the exact one is used while the node is not moved).
/// * Arrays become keyed lists (`.items`) only where every element has a unique key (see `keyedLists`); code-node
///   `outputs` (a map in Dify) becomes items whose value carries `name`, which is what references point at (protocol 1.4).
/// * Every `[node, output]` pair whose first element is a node of the graph becomes a reference (`.ref`).
/// * Everything outside `workflow.graph.nodes/edges` is returned as `metadata` (with the edges' Dify-only fields under
///   `_edges`); `export` needs it back.
public enum DifyDSL {
    public struct Imported: Sendable {
        public var document: Document
        public var metadata: Value
    }

    public struct DSLError: Error, CustomStringConvertible, Sendable {
        public var description: String
        init(_ d: String) { description = d }
    }

    /// (node type, config key, item key): arrays imported as keyed lists. `*` = any node type.
    static let keyedLists: [(type: String, key: String, itemKey: String)] = [
        ("*", "variables", "variable"),
        ("end", "outputs", "variable"),
        ("if-else", "cases", "case_id"),
        ("llm", "prompt_template", "id"),
        ("loop", "loop_variables", "id"),
        ("loop", "break_conditions", "id"),
    ]
    /// Node types whose `outputs` is a map {name: spec} in Dify.
    static let outputMaps: Set<String> = ["code"]

    // MARK: - Import

    public static func importYAML(_ yaml: String) throws -> Imported {
        guard let node = try Yams.compose(yaml: yaml) else { throw DSLError("empty document") }
        return try importValue(value(of: node))
    }

    public static func importValue(_ root: Value) throws -> Imported {
        guard case .map(var top) = root, case .map(var workflow)? = top["workflow"],
              case .map(var graph)? = workflow["graph"] else { throw DSLError("not a Dify workflow DSL (workflow.graph missing)") }
        guard case .list(let rawNodes)? = graph["nodes"] else { throw DSLError("workflow.graph.nodes missing") }
        let rawEdges: [Value] = { if case .list(let e)? = graph["edges"] { return e }; return [] }()
        var ids = Set<String>()
        for case .map(let n) in rawNodes { if case .string(let id)? = n["id"] { ids.insert(id) } }

        var nodes: [CollabCore.Node] = []
        for raw in rawNodes {
            guard case .map(var n) = raw, case .string(let id)? = n.removeValue(forKey: "id"),
                  case .map(var data)? = n.removeValue(forKey: "data") else { throw DSLError("node without id or data") }
            guard case .string(let type)? = data.removeValue(forKey: "type") else { throw DSLError("node \(id) has no data.type") }
            let title: String = { if case .string(let t)? = data.removeValue(forKey: "title") { return t }; return "" }()
            data["selected"] = nil
            n["selected"] = nil
            let (x, y, exact) = position(n.removeValue(forKey: "position"))
            if let exact { n["position"] = exact }
            var config: [String: Value] = [:]
            for (k, v) in data { config[k] = refs(in: v, nodes: ids) }
            for (t, key, itemKey) in keyedLists where t == "*" || t == type {
                if case .list(let xs)? = config[key], let items = keyed(xs, by: itemKey) { config[key] = .items(items) }
            }
            if outputMaps.contains(type), case .map(let outs)? = config["outputs"] {
                config["outputs"] = .items(outs.keys.sorted().map { name in
                    var spec: [String: Value] = { if case .map(let m) = outs[name]! { return m }; return ["value": outs[name]!] }()
                    spec["name"] = .string(name)
                    return Item(id: name, value: .map(spec))
                })
            }
            if !n.isEmpty { config["_dify_node"] = .map(n) }
            nodes.append(CollabCore.Node(id: id, type: type, title: title, x: x, y: y, config: config))
        }

        var edges: [Edge] = []
        var edgeExtras: [String: Value] = [:]
        for raw in rawEdges {
            guard case .map(var e) = raw, case .string(let id)? = e.removeValue(forKey: "id"),
                  case .string(let s)? = e.removeValue(forKey: "source"), case .string(let t)? = e.removeValue(forKey: "target")
            else { throw DSLError("edge without id/source/target") }
            let sh: String = { if case .string(let h)? = e.removeValue(forKey: "sourceHandle") { return h }; return "source" }()
            let th: String = { if case .string(let h)? = e.removeValue(forKey: "targetHandle") { return h }; return "target" }()
            e["selected"] = nil
            edges.append(Edge(id: id, source: s, sourceHandle: sh, target: t, targetHandle: th))
            edgeExtras[id] = .map(e)  // also when empty: then nothing is derived on export
        }

        graph["nodes"] = nil
        graph["edges"] = nil
        workflow["graph"] = .map(graph)
        top["workflow"] = .map(workflow)
        if !edgeExtras.isEmpty { top["_edges"] = .map(edgeExtras) }
        // A reference to an output the target node does not declare (a stale Dify workflow) is imported as an explicit
        // broken marker, exactly what dify-sf writes when an output is removed.
        let declared = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Document.declaredOutputs(of: $0)) })
        func checked(_ v: Value) -> Value {
            switch v {
            case .ref(let r): if let outs = declared[r.node] ?? nil, !outs.contains(r.output) { return .brokenRef(r) }; return v
            case .list(let xs): return .list(xs.map(checked))
            case .items(let xs): return .items(xs.map { Item(id: $0.id, value: checked($0.value)) })
            case .map(let m): return .map(m.mapValues(checked))
            default: return v
            }
        }
        for i in nodes.indices { nodes[i].config = nodes[i].config.mapValues(checked) }
        let doc = Document(nodes: nodes, edges: edges)
        if let p = doc.integrityProblems.first { throw DSLError("imported workflow is inconsistent: \(p)") }
        return Imported(document: doc, metadata: .map(top))
    }

    /// Dify positions may be fractional; the document stores integers and keeps the exact value aside.
    static func position(_ v: Value?) -> (Int, Int, Value?) {
        guard case .map(let p)? = v else { return (0, 0, nil) }
        func num(_ k: String) -> Double {
            switch p[k] { case .int(let i)?: return Double(i); case .double(let d)?: return d; default: return 0 }
        }
        let x = num("x"), y = num("y")
        let exact = x == x.rounded() && y == y.rounded() ? nil : Value.map(p)
        return (Int(x.rounded()), Int(y.rounded()), exact)
    }

    static func keyed(_ xs: [Value], by key: String) -> [Item]? {
        var seen = Set<String>()
        var out: [Item] = []
        for x in xs {
            guard case .map(let m) = x, case .string(let id)? = m[key], !id.isEmpty, seen.insert(id).inserted else { return nil }
            out.append(Item(id: id, value: x))
        }
        return out
    }

    /// `[node, output]` with a node of the graph -> reference; recursively.
    static func refs(in v: Value, nodes: Set<String>) -> Value {
        switch v {
        case .list(let xs):
            if xs.count == 2, case .string(let n) = xs[0], case .string(let o) = xs[1], nodes.contains(n) {
                return .ref(OutputRef(node: n, output: o))
            }
            return .list(xs.map { refs(in: $0, nodes: nodes) })
        case .map(let m): return .map(m.mapValues { refs(in: $0, nodes: nodes) })
        default: return v
        }
    }

    // MARK: - Export

    public static func exportYAML(_ doc: Document, metadata: Value) throws -> String {
        try Yams.serialize(node: yamlNode(exportValue(doc, metadata: metadata)), allowUnicode: true)
    }

    public static func exportValue(_ doc: Document, metadata: Value) throws -> Value {
        guard case .map(var top) = metadata, case .map(var workflow)? = top["workflow"] else { throw DSLError("bad metadata") }
        var graph: [String: Value] = { if case .map(let g)? = workflow["graph"] { return g }; return [:] }()
        let edgeExtras: [String: Value] = { if case .map(let e)? = top.removeValue(forKey: "_edges") { return e }; return [:] }()

        func absolute(_ id: String, depth: Int = 0) -> (Double, Double) {
            guard let n = doc.nodes[id], depth < 16 else { return (0, 0) }
            let (x, y) = exactPosition(n)
            if case .map(let extra)? = n.config["_dify_node"], case .string(let parent)? = extra["parentId"] {
                let (px, py) = absolute(parent, depth: depth + 1)
                return (px + x, py + y)
            }
            return (x, y)
        }

        var nodes: [Value] = []
        for id in doc.nodes.keys.sorted() {
            let n = doc.nodes[id]!
            var config = n.config
            var top: [String: Value] = { if case .map(let m)? = config.removeValue(forKey: "_dify_node") { return m }; return [:] }()
            let (x, y) = exactPosition(n)
            top["position"] = .map(["x": .number(x), "y": .number(y)])
            if top["positionAbsolute"] != nil {
                let (ax, ay) = absolute(id)
                top["positionAbsolute"] = .map(["x": .number(ax), "y": .number(ay)])
            }
            if outputMaps.contains(n.type), case .items(let outs)? = config["outputs"] {
                var m: [String: Value] = [:]
                for i in outs {
                    guard case .map(var spec) = i.value else { continue }
                    let name: String = { if case .string(let s)? = spec.removeValue(forKey: "name") { return s }; return i.id }()
                    m[name] = spec.count == 1 && spec["value"] != nil ? spec["value"]! : .map(spec)
                }
                config["outputs"] = .map(m)
            }
            var data: [String: Value] = [:]
            for (k, v) in config { data[k] = plainLists(v) }
            data["type"] = .string(n.type)
            data["title"] = .string(n.title)
            top["id"] = .string(id)
            top["data"] = .map(data)
            nodes.append(.map(top))
        }
        var edges: [Value] = []
        for id in doc.edges.keys.sorted() {
            let e = doc.edges[id]!
            var m: [String: Value] = { if case .map(let x)? = edgeExtras[id] { return x }; return derivedEdgeFields(e, doc) }()
            m["id"] = .string(id)
            m["source"] = .string(e.source)
            m["sourceHandle"] = .string(e.sourceHandle)
            m["target"] = .string(e.target)
            m["targetHandle"] = .string(e.targetHandle)
            edges.append(.map(m))
        }
        graph["nodes"] = .list(nodes)
        graph["edges"] = .list(edges)
        workflow["graph"] = .map(graph)
        top["workflow"] = .map(workflow)
        return .map(top)
    }

    static func exactPosition(_ n: CollabCore.Node) -> (Double, Double) {
        if case .map(let extra)? = n.config["_dify_node"], case .map(let p)? = extra["position"] {
            func num(_ k: String) -> Double? {
                switch p[k] { case .int(let i)?: return Double(i); case .double(let d)?: return d; default: return nil }
            }
            if let x = num("x"), let y = num("y"), Int(x.rounded()) == n.x, Int(y.rounded()) == n.y { return (x, y) }
        }
        return (Double(n.x), Double(n.y))
    }

    /// Fields Dify expects on an edge created in dify-sf (no stored Dify fields).
    static func derivedEdgeFields(_ e: Edge, _ doc: Document) -> [String: Value] {
        func parent(_ id: String) -> (String, String)? {
            guard case .map(let x)? = doc.nodes[id]?.config["_dify_node"], case .string(let p)? = x["parentId"],
                  let pt = doc.nodes[p]?.type else { return nil }
            return (p, pt)
        }
        var data: [String: Value] = [
            "sourceType": .string(doc.nodes[e.source]?.type ?? ""), "targetType": .string(doc.nodes[e.target]?.type ?? ""),
            "isInIteration": .bool(false), "isInLoop": .bool(false),
        ]
        var z = 0
        if let (p, pt) = parent(e.target) {
            if pt == "iteration" { data["isInIteration"] = .bool(true); data["iteration_id"] = .string(p) }
            if pt == "loop" { data["isInLoop"] = .bool(true); data["loop_id"] = .string(p) }
            z = 1002
        }
        return ["type": .string("custom"), "zIndex": .int(z), "data": .map(data)]
    }

    /// Keyed lists back to arrays, references back to `[node, output]`.
    static func plainLists(_ v: Value) -> Value {
        switch v {
        case .items(let xs): return .list(xs.map { plainLists($0.value) })
        case .ref(let r), .brokenRef(let r): return .list([.string(r.node), .string(r.output)])
        case .list(let xs): return .list(xs.map(plainLists))
        case .map(let m): return .map(m.mapValues(plainLists))
        default: return v
        }
    }

    // MARK: - YAML <-> Value

    /// Scalars by their resolved YAML tag; timestamps and other tags stay strings.
    static func value(of node: Yams.Node) throws -> Value {
        switch node {
        case .scalar(let s):
            // quoted scalars carry the non-specific tag and stay strings; plain ones resolve by pattern
            switch Resolver.default.resolveTag(of: node) {
            case Tag.Name.null: return .null
            case Tag.Name.bool: return .bool(Bool.construct(from: s) ?? false)
            case Tag.Name.int: if let i = Int.construct(from: s) { return .int(i) }; return .string(s.string)
            case Tag.Name.float: if let d = Double.construct(from: s) { return .number(d) }; return .string(s.string)
            default: return .string(s.string)
            }
        case .sequence(let seq): return .list(try seq.map(value(of:)))
        case .mapping(let map):
            var m: [String: Value] = [:]
            for (k, v) in map {
                guard case .scalar(let ks) = k else { throw DSLError("non-scalar map key") }
                m[ks.string] = try value(of: v)
            }
            return .map(m)
        case .alias: throw DSLError("YAML aliases are not supported")
        }
    }

    /// Value -> YAML node, keys sorted. Doubles use Swift's shortest exact representation (Yams' own formatter keeps only
    /// 15 significant digits); strings go through Yams' representer, which quotes what would otherwise read as another type.
    static func yamlNode(_ v: Value) -> Yams.Node {
        switch v {
        case .null: return Yams.Node("null", Tag(.null))
        case .bool(let b): return .scalar(b.represented())
        case .int(let i): return .scalar(i.represented())
        case .double(let d): return Yams.Node("\(d)", Tag(.float))
        case .string(let s): return .scalar(s.represented())
        case .list(let xs): return .sequence(.init(xs.map(yamlNode)))
        case .map(let m): return .mapping(.init(m.keys.sorted().map { (.scalar($0.represented()), yamlNode(m[$0]!)) }))
        case .items(let xs): return .sequence(.init(xs.map { yamlNode($0.value) }))
        case .ref(let r), .brokenRef(let r): return .sequence(.init([.scalar(r.node.represented()), .scalar(r.output.represented())]))
        }
    }
}
