import CollabCore
import Foundation
import Yams

/// Replacing an open document from a Dify workflow file (`POST /v1/docs/{doc}/replace`), Dify 1.17.1's "Import DSL" in the
/// editor, which overwrites the current app's draft. The file is imported like `importYAML` (same mapping, same secret
/// handling); `CollabCore.Replacement` then computes the ops that turn the document at head into it.
extension DifyDSL {
    /// A YAML document as a `Value` (the same reading as `importYAML`).
    public static func parseYAML(_ yaml: String) throws -> Value {
        guard let node = try Yams.compose(yaml: yaml) else { throw DSLError("empty document") }
        return try value(of: node)
    }

    /// Dify 1.17.1's `CURRENT_APP_DSL_VERSION`.
    public static let currentDSLVersion = "0.7.0"

    /// Dify's `ImportStatus` for a file's DSL version (`check_version_compatibility`).
    public enum VersionStatus: String, Sendable {
        case completed
        /// An older minor version: imported, with Dify's warning ("DSL version difference may affect certain features").
        case completedWithWarnings = "completed-with-warnings"
        /// A newer version, or an older major version: Dify asks the user to confirm first.
        case pending
        case failed
    }

    /// Dify's `check_version_compatibility(imported, current)`.
    public static func versionStatus(_ imported: String, current: String = currentDSLVersion) -> VersionStatus {
        guard let i = releaseNumbers(imported), let c = releaseNumbers(current) else { return .failed }
        func cmp(_ a: [Int], _ b: [Int]) -> Int {
            for k in 0..<max(a.count, b.count) {
                let x = k < a.count ? a[k] : 0, y = k < b.count ? b[k] : 0
                if x != y { return x < y ? -1 : 1 }
            }
            return 0
        }
        if cmp(i, c) > 0 { return .pending }
        if i[0] < c[0] { return .pending }
        if (i.count > 1 ? i[1] : 0) < (c.count > 1 ? c[1] : 0) { return .completedWithWarnings }
        return .completed
    }

    /// The release segment of a version (`1.2.3`, optionally `v1.2.3`); nil if it does not parse.
    static func releaseNumbers(_ s: String) -> [Int]? {
        var t = Substring(s.trimmingCharacters(in: .whitespaces))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// A file refused before anything is computed: Dify's message, and for `pending` the two versions.
    public struct ReplaceRefusal: Error, CustomStringConvertible, Sendable {
        public var message: String
        /// Set when the file's version needs the user's confirmation (Dify's `pending`; repeat with `confirm`).
        public var pendingVersion: String?
        public var description: String { message }
        init(_ m: String, pendingVersion: String? = nil) {
            message = m
            self.pendingVersion = pendingVersion
        }
    }

    /// Dify's checks of a file that overwrites an app (`AppDslService.import_app` with `app_id`, and the editor's
    /// `validateDSLContent` for the app's mode), in Dify's order. `root` is the parsed file; `appMode` the open app's mode.
    /// Returns the file's version and its status (`completed` or `completed-with-warnings`). `pending` versions are
    /// refused unless `confirm` (Dify's confirmation step).
    public static func checkReplacement(_ root: Value, appMode: String, confirm: Bool) throws(ReplaceRefusal)
        -> (version: String, status: VersionStatus) {
        guard case .map(let top) = root else { throw ReplaceRefusal("Invalid YAML format: content must be a mapping") }
        var version = "0.1.0"
        switch top["version"] {
        case nil, .null?: break
        case .string(let s)?: version = s.isEmpty ? "0.1.0" : s
        case let v?: throw ReplaceRefusal("Invalid version type, expected str, got <class '\(pythonType(v))'>")
        }
        let status = versionStatus(version)
        if status == .failed { throw ReplaceRefusal("Invalid DSL version: \(version)") }
        guard case .map(let app)? = top["app"], !app.isEmpty else { throw ReplaceRefusal("Missing app data in YAML content") }
        if status == .pending && !confirm {
            throw ReplaceRefusal("The DSL version \(version) differs from the current version \(currentDSLVersion): confirm to import",
                                 pendingVersion: version)
        }
        guard case .string(let mode)? = app["mode"], !mode.isEmpty else { throw ReplaceRefusal("loss app mode") }
        let known = ["completion", "workflow", "chat", "advanced-chat", "agent-chat", "agent", "channel", "rag-pipeline"]
        guard known.contains(mode) else { throw ReplaceRefusal("'\(mode)' is not a valid AppMode") }
        guard mode == "workflow" || mode == "advanced-chat" else {
            throw ReplaceRefusal("Only workflow or advanced chat apps can be overwritten (the file is a \(mode) app)")
        }
        guard case .map(let workflow)? = top["workflow"] else { throw ReplaceRefusal("Missing workflow data for workflow/advanced chat app") }
        // The editor's `validateDSLContent`: node types the open app's mode cannot run. Dify keeps the app's mode.
        let invalid: Set<String> = appMode == "advanced-chat"
            ? ["end", "trigger-webhook", "trigger-schedule", "trigger-plugin"] : ["answer"]
        if case .map(let graph)? = workflow["graph"], case .list(let nodes)? = graph["nodes"] {
            var found = Set<String>()
            for case .map(let n) in nodes {
                if case .map(let d)? = n["data"], case .string(let t)? = d["type"], invalid.contains(t) { found.insert(t) }
            }
            if !found.isEmpty {
                let what = appMode == "advanced-chat" ? "a chatflow (advanced-chat)" : "a workflow"
                throw ReplaceRefusal("Import Failed: \(found.sorted().joined(separator: ", ")) nodes are not supported in \(what) app")
            }
        }
        return (version, status)
    }

    static func pythonType(_ v: Value) -> String {
        switch v {
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .list, .items: return "list"
        case .map: return "dict"
        case .null: return "NoneType"
        default: return "str"
        }
    }

    /// What replacing a document with a file amounts to.
    public struct ReplacementPlan: Sendable {
        /// The ops, to be committed in this order with `base` = the head they were computed at.
        public var ops: [Op]
        /// The document the ops lead to (as imported, after the id rules).
        public var document: Document
        /// The new import metadata (the file's app-level parts; the app keeps its mode, as in Dify).
        public var metadata: Value
        /// Plaintext of secret environment variables to store, by reference (only new ones: a secret whose plaintext is
        /// unchanged keeps its reference).
        public var secrets: [String: String]
        /// File ids that could not be kept (tombstoned, or a live node of another type / with a config key the file's node
        /// lacks, a live edge with other endpoints): file id -> id in the document.
        public var renamedNodes: [String: String]
        public var renamedEdges: [String: String]
    }

    /// Plans the replacement of `current` (the document at `base`, with stored `metadata` and `storedSecrets`) by the file
    /// `root`, as ops of `client`. `newNodeId` proposes fresh node ids (Dify's style: the time in milliseconds; it is asked
    /// again until the id is free); `metadata`'s app mode is kept. Throws `DSLError` for a file that is not an importable
    /// workflow, `Replacement.Failure` if the result cannot be written with ops.
    public static func planReplacement(_ root: Value, current: Document, metadata: Value?, storedSecrets: [String: String],
                                       client: ClientID, base: Int,
                                       newNodeId: () -> String = { String(Int(Date().timeIntervalSince1970 * 1000)) },
                                       newSecretRef: () -> String = newSecretRef) throws -> ReplacementPlan {
        let first = try importValue(root, newSecretRef: newSecretRef)
        let fresh = Replacement.freshIdsNeeded(current: current, target: first.document)
        var renamedNodes: [String: String] = [:]
        var renamedEdges: [String: String] = [:]
        var file = root
        var imported = first
        if !fresh.nodes.isEmpty || !fresh.edges.isEmpty {
            var taken = Set<String>()
            for id in fresh.nodes.sorted() {
                var n = newNodeId()
                var bump = Int(n) ?? 0
                while Replacement.nodeIdTaken(n, current: current, target: first.document) || taken.contains(n) {
                    bump += 1
                    n = Int(n) != nil ? String(bump) : newNodeId() + "_\(bump)"
                }
                taken.insert(n)
                renamedNodes[id] = n
            }
            // Edges that cannot keep their id, and every edge of a renamed node: Dify's id format with the new endpoints.
            var usedEdges = Set<String>()
            for id in first.document.edges.keys.sorted() {
                let e = first.document.edges[id]!
                guard fresh.edges.contains(id) || renamedNodes[e.source] != nil || renamedNodes[e.target] != nil else { continue }
                let s = renamedNodes[e.source] ?? e.source, t = renamedNodes[e.target] ?? e.target
                let stem = "\(s)-\(e.sourceHandle)-\(t)-\(e.targetHandle)"
                var candidate = stem
                var k = 0
                while Replacement.edgeIdTaken(candidate, current: current, target: first.document) || usedEdges.contains(candidate) {
                    k += 1
                    candidate = "\(stem)-\(k)"
                }
                usedEdges.insert(candidate)
                renamedEdges[id] = candidate
            }
            file = renaming(root, nodes: renamedNodes, edges: renamedEdges)
            imported = try importValue(file, newSecretRef: newSecretRef)
            let left = Replacement.freshIdsNeeded(current: current, target: imported.document)
            guard left.nodes.isEmpty, left.edges.isEmpty else { throw DSLError("renaming ids did not free them: \(left)") }
        }
        // A secret whose plaintext is already stored under the reference the document has keeps that reference.
        var target = imported.document
        var secrets = imported.secrets
        if case .items(var items)? = target.app[environmentVariables] {
            var currentRefs: [String: String] = [:]
            if case .items(let cur)? = current.app[environmentVariables] {
                for i in cur { if case .map(let m) = i.value, case .string(let r)? = m[secretRefKey] { currentRefs[i.id] = r } }
            }
            for k in items.indices {
                guard case .map(var m) = items[k].value, case .string(let ref)? = m[secretRefKey], let plain = secrets[ref],
                      let old = currentRefs[items[k].id], storedSecrets[old] == plain else { continue }
                m[secretRefKey] = .string(old)
                items[k].value = .map(m)
                secrets[ref] = nil
            }
            target = Document(nodes: Array(target.nodes.values), edges: Array(target.edges.values),
                              app: target.app.merging([environmentVariables: .items(items)]) { $1 })
        }
        let ops = try Replacement.ops(from: current, to: target, client: client, base: base)
        // The app keeps its mode (Dify updates name, description and icon from the file, never the mode); `kind` and
        // `version` get Dify's defaults.
        guard case .map(var top) = imported.metadata else { throw DSLError("bad metadata") }
        let mode = appMode(metadata)
        if case .map(var app)? = top["app"] { app["mode"] = .string(mode); top["app"] = .map(app) }
        if top["kind"] != .string("app") { top["kind"] = .string("app") }
        if case .string(let v)? = top["version"], !v.isEmpty {} else { top["version"] = .string("0.1.0") }
        return ReplacementPlan(ops: ops, document: target, metadata: .map(top), secrets: secrets,
                               renamedNodes: renamedNodes, renamedEdges: renamedEdges)
    }

    /// The app mode of stored import metadata (`workflow` for a document that was not imported).
    public static func appMode(_ metadata: Value?) -> String {
        if case .map(let top)? = metadata, case .map(let app)? = top["app"], case .string(let m)? = app["mode"] { return m }
        return "workflow"
    }

    /// Node fields of a Dify file that hold a node id (besides `id`, edge `source`/`target` and `[node, output]` selectors).
    static let nodeIdFields: Set<String> = ["parentId", "iteration_id", "loop_id", "start_node_id"]

    /// The file with node and edge ids renamed: node and edge `id`s, edge endpoints, the node id fields above, selectors
    /// (`[node, output, ...]` lists of strings whose first element is a renamed node) and `{{#node.output#}}` templates in
    /// every string.
    static func renaming(_ root: Value, nodes: [String: String], edges: [String: String]) -> Value {
        guard !nodes.isEmpty || !edges.isEmpty else { return root }
        let templates = nodes.map { ("{{#\($0.key).", "{{#\($0.value).") }
        func walk(_ v: Value, key: String?) -> Value {
            switch v {
            case .string(let s):
                if let key, nodeIdFields.contains(key), let n = nodes[s] { return .string(n) }
                guard s.contains("{{#") else { return v }
                var out = s
                for (a, b) in templates where out.contains(a) { out = out.replacingOccurrences(of: a, with: b) }
                return .string(out)
            case .list(let xs):
                if xs.count >= 2, case .string(let first) = xs[0], let n = nodes[first],
                   xs.allSatisfy({ if case .string = $0 { return true }; return false }) {
                    return .list([.string(n)] + xs.dropFirst())
                }
                return .list(xs.map { walk($0, key: nil) })
            case .map(let m):
                var out: [String: Value] = [:]
                for (k, x) in m { out[k] = walk(x, key: k) }
                return .map(out)
            default: return v
            }
        }
        guard case .map(var top) = root, case .map(var workflow)? = top["workflow"], case .map(var graph)? = workflow["graph"]
        else { return root }
        if case .list(let ns)? = graph["nodes"] {
            graph["nodes"] = .list(ns.map { raw in
                guard case .map(var n) = walk(raw, key: nil) else { return raw }
                if case .string(let id)? = n["id"], let r = nodes[id] { n["id"] = .string(r) }
                return .map(n)
            })
        }
        if case .list(let es)? = graph["edges"] {
            graph["edges"] = .list(es.map { raw in
                guard case .map(var e) = walk(raw, key: nil) else { return raw }
                if case .string(let id)? = e["id"], let r = edges[id] { e["id"] = .string(r) }
                for k in ["source", "target"] { if case .string(let s)? = e[k], let r = nodes[s] { e[k] = .string(r) } }
                return .map(e)
            })
        }
        workflow["graph"] = .map(graph)
        top["workflow"] = .map(workflow)
        return .map(top)
    }
}
