// dify-sf clipboard extension: private resources and graph additions commit together.
import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import Vapor

extension Routes {
    func registerAgentClipboard(on r: any RoutesBuilder) {
        let path = r.grouped("v1", "apps", ":app", "workflows", "draft", "agent-clipboard")
        path.post("export") { req in await handle(req) { try await self.exportAgentClipboard(req) } }
        path.post("paste") { req in await handle(req) { try await self.pasteAgentClipboard(req) } }
    }

    private func exportAgentClipboard(_ req: Request) async throws -> Response {
        let user = try await authenticate(req, .edit)
        let app = try await appOfMode(req, user, ["workflow"])
        let payload = try JSONValue.parse(try await body(req))
        guard case .int(let expected)? = payload["expected_seq"], let rawIDs = payload["node_ids"]?.array,
              !rawIDs.isEmpty, rawIDs.count <= 200, rawIDs.allSatisfy({ $0.string != nil }) else { throw Self.invalidParam("Invalid Agent clipboard selection") }
        let ids = Set(rawIDs.compactMap(\.string))
        let snapshot = try await registry.sequencer(app.id).currentSnapshot()
        let baseline = payload["expected_nodes"]?.object
        let matches = try ids.allSatisfy { id in
            guard let node = snapshot.doc.nodes[id] else { return false }
            guard let baseline else { return snapshot.seq == expected }
            let actual = try JSONValue.parse(try WireJSON.encode(node))
            guard let before = baseline[id]?.object else { return false }
            return ["type", "title", "config"].allSatisfy { (before[$0] ?? .null) == (actual[$0] ?? .null) }
        }
        guard expected <= snapshot.seq, matches else {
            throw ServerError.http(status: 409, code: "agent_document_changed", message: "The clipboard selection changed")
        }
        let selected = Document(nodes: ids.sorted().compactMap { snapshot.doc.nodes[$0] },
            edges: snapshot.doc.edges.values.filter { ids.contains($0.source) && ids.contains($0.target) })
        let exported = try JSONValue.parse(try WireJSON.encode(try await agentExportValue(selected,
            metadata: DifyDSL.defaultMetadata(name: "Clipboard"), secrets: nil, app: app.id, allowClipboardPlaceholders: true)))
        return rawJSON(["document_seq": .int(snapshot.seq), "nodes": exported["workflow"]?["graph"]?["nodes"] ?? [],
            "edges": exported["workflow"]?["graph"]?["edges"] ?? [], "agent_packages": exported["agent_packages"] ?? [:]])
    }

    /// Rewrite task selectors and known reference arrays using the full clipboard ID map, including private job refs.
    static func remapAgentJob(_ value: JSONValue, ids: [String: String]) -> JSONValue {
        if let text = value.string {
            return .string(ids.reduce(text) { $0.replacingOccurrences(of: "{{#" + $1.key + ".", with: "{{#" + $1.value + ".") })
        }
        if let items = value.array {
            if items.count >= 2, let source = items.first?.string, let target = ids[source], items.allSatisfy({ $0.string != nil }) {
                return .array([.string(target)] + items.dropFirst())
            }
            return .array(items.map { remapAgentJob($0, ids: ids) })
        }
        if let object = value.object { return .object(JSONObject(object.map { ($0.key, remapAgentJob($0.value, ids: ids)) })) }
        return value
    }

    private func pasteAgentClipboard(_ req: Request) async throws -> Response {
        let user = try await authenticate(req, .edit)
        let app = try await appOfMode(req, user, ["workflow"])
        let bytes = try await body(req)
        guard let payload = try JSONValue.parse(bytes).object, case .int(let expected)? = payload["expected_seq"], expected >= 0,
              let key = payload["idempotency_key"]?.string, UUID(uuidString: key) != nil,
              let nodes = payload["nodes"]?.array, !nodes.isEmpty, nodes.count <= 200,
              let edges = payload["edges"]?.array, edges.count <= 1000,
              let packages = payload["agent_packages"]?.object,
              let mapping = payload["id_mapping"]?.object, mapping.count <= 200,
              mapping.values.allSatisfy({ $0.string != nil }),
              payload["local_sources"] == nil || payload["local_sources"]?.object != nil else { throw Self.invalidParam("Invalid Agent clipboard payload") }
        let requestID = key.lowercased()
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.sortedKeys])
        let digest = Tokens.sha256(String(decoding: canonical, as: UTF8.self))
        func response(_ receipt: AgentComposerReceipt) throws -> Response {
            guard receipt.digest == digest else { throw ServerError.http(status: 409, code: "agent_idempotency_conflict", message: "This clipboard request has another payload") }
            return rawJSON(try JSONValue.parse(receipt.response))
        }
        if let receipt = try await store.agentComposerReceipt(doc: app.id, user: user.id, request: requestID) { return try response(receipt) }
        let ids = Dictionary(uniqueKeysWithValues: mapping.map { ($0.key, $0.value.string!) })
        var root: JSONObject = ["kind": "app", "version": "0.3.1", "app": ["mode": "workflow", "name": "Clipboard"],
            "agent_packages": .object(packages), "workflow": ["graph": ["nodes": .array(nodes), "edges": .array(edges)],
                "environment_variables": [], "conversation_variables": [], "features": [:]]]
        root = Self.remapAgentJob(.object(root), ids: ids).object ?? root
        let imported: DifyDSL.Imported
        do { imported = try DifyDSL.importValue(Self.agentCoreValue(.object(root))) }
        catch { throw Self.invalidParam("Invalid clipboard graph") }
        guard imported.document.nodes.count == nodes.count, imported.document.edges.count == edges.count,
              nodes.allSatisfy({ $0["id"]?.string != nil }), Set(nodes.compactMap { $0["id"]?.string }).count == nodes.count else {
            throw Self.invalidParam("Clipboard contains duplicate or invalid graph elements")
        }
        let routes = self
        _ = try await registry.sequencer(app.id).replace(client: "agent-" + user.id + "-" + requestID, cseq: 1) { current, head -> (DocumentSequencer.ReplaceWork, Bool) in
            guard head == expected else { throw ServerError.http(status: 409, code: "agent_document_changed", message: "The workflow changed before paste") }
            guard imported.document.nodes.keys.allSatisfy({ current.nodes[$0] == nil && current.deletedNodes[$0] == nil }),
                  imported.document.edges.keys.allSatisfy({ current.edges[$0] == nil && current.deletedEdges[$0] == nil }) else { throw Self.invalidParam("Clipboard target IDs are already used") }
            var plan = try await routes.agentImportPlan(imported.document, metadata: imported.metadata, app: app.id, user: user.id, allowClipboardPlaceholders: true)
            for (target, rawSource) in payload["local_sources"]?.object ?? [:] {
                guard imported.document.nodes[target] != nil, let source = rawSource["node_id"]?.string,
                      ids[source] == target, let node = current.nodes[source],
                      let stored = try await routes.pinnedAgentConfig(app: app.id, node: source, graph: Self.agentNodeConfig(node)),
                      rawSource["agent_id"] == .string(stored.agentId), rawSource["current_snapshot_id"] == .string(stored.id) else {
                    throw ServerError.http(status: 409, code: "agent_binding_changed", message: "The source Agent configuration changed")
                }
                var config = stored
                config.id = UUID().uuidString.lowercased(); config.agentId = UUID().uuidString.lowercased(); config.bindingId = UUID().uuidString.lowercased()
                config.nodeId = target; config.revision = 1; config.createdBy = user.id; config.createdAt = Date()
                var shared = try Self.agentNodeConfig(imported.document.nodes[target]!)
                shared["agent_declared_outputs"] = try Self.agentNodeConfig(node)["agent_declared_outputs"] ?? []
                config.nodeJob = Self.remapAgentJob(.object(try Self.agentNodeJob(graph: shared, stored: stored)), ids: ids).compactJSON()
                let receipt = AgentComposerReceipt(requestID: UUID().uuidString.lowercased(), userID: user.id, nodeID: target, digest: "local-agent-clone-v1", response: "{}")
                plan.changes.removeAll { $0.snapshot.nodeId == target }
                plan.changes.append(.init(snapshot: config, expectedSnapshotId: nil, receipt: receipt))
                plan.configurations[target] = ["agent_binding": ["binding_type": "inline_agent", "agent_id": .string(config.agentId), "current_snapshot_id": .string(config.id)],
                    "agent_declared_outputs": shared["agent_declared_outputs"] ?? [], "agent_task": shared["agent_task"] ?? ""]
            }
            guard !plan.changes.isEmpty else { throw Self.invalidParam("Agent clipboard paste requires a bound inline Agent") }
            let materialized = try plan.initialDocument(imported.document)
            let combined = Document(nodes: Array(current.nodes.values) + Array(materialized.nodes.values),
                edges: Array(current.edges.values) + Array(materialized.edges.values), app: current.app)
            let operations = try Replacement.ops(from: current, to: combined, client: "agent-" + user.id + "-" + requestID, base: head)
            let reply: JSONValue = ["document_seq": .int(head + operations.count),
                "node_ids": .array(materialized.nodes.keys.sorted().map(JSONValue.string)),
                "edge_ids": .array(materialized.edges.keys.sorted().map(JSONValue.string))]
            plan.changes[0].receipt = AgentComposerReceipt(requestID: requestID, userID: user.id, nodeID: plan.changes[0].snapshot.nodeId,
                digest: digest, response: reply.compactJSON())
            return (.init(ops: operations, metadata: nil, secrets: [:], agentConfigs: plan.changes), true)
        }
        guard let receipt = try await store.agentComposerReceipt(doc: app.id, user: user.id, request: requestID) else { throw ServerError.unavailable("Clipboard receipt unavailable") }
        return try response(receipt)
    }
}
