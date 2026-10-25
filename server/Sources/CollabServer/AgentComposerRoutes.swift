// Dify's inline workflow composer, with document revision and idempotency extensions for collaboration.
import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Vapor

extension Routes {
    func registerAgentComposer(on r: any RoutesBuilder) {
        let path = r.grouped("v1", "apps", ":app", "workflows", "draft", "nodes", ":node", "agent-composer")
        path.get { req in await handle(req) { try await self.readAgentComposer(req) } }
        path.put { req in await handle(req) { try await self.saveAgentComposer(req) } }
    }

    static func agentCoreValue(_ json: JSONValue) throws -> Value {
        try WireJSON.decode(Value.self, from: Data(json.compactJSON().utf8))
    }

    static func agentNodeConfig(_ node: CollabCore.Node) throws -> JSONObject {
        guard node.type == "agent", node.config["version"] == .string("2"),
              node.config["agent_node_kind"] == .string("dify_agent") else {
            throw ServerError.badRequest("Only inline Agent v2 workflow nodes have a composer")
        }
        let parsed = try JSONValue.parse(try WireJSON.encode(Value.map(node.config)))
        let binding = parsed["agent_binding"]
        guard binding == nil || binding == .null || binding?["binding_type"] == "inline_agent" else {
            throw ServerError.badRequest("Roster bindings are not supported")
        }
        return parsed.object ?? [:]
    }

    func pinnedAgentConfig(app: String, node: String, graph: JSONObject, snapshotOverride: String? = nil) async throws -> StoredAgentConfig? {
        guard let binding = graph["agent_binding"]?.object,
              let agent = binding["agent_id"]?.string, let snapshot = snapshotOverride ?? binding["current_snapshot_id"]?.string else {
            if snapshotOverride != nil { throw ServerError.missing("Agent config not found") }
            return nil
        }
        guard let found = try await store.agentConfig(doc: app, node: node, agent: agent, snapshot: snapshot) else {
            throw ServerError.missing("Agent config not found in this workflow node")
        }
        return found
    }

    static func agentNodeJob(graph: JSONObject, stored: StoredAgentConfig?) throws -> JSONObject {
        var job = try stored.map { try JSONValue.parse($0.nodeJob).object ?? [:] } ?? [:]
        // Shared graph state owns task and declarations, including edits outside the composer and restored versions.
        job["schema_version"] = 1
        job["mode"] = "tell_agent_what_to_do"
        job["workflow_prompt"] = graph["agent_task"] ?? ""
        job["declared_outputs"] = graph["agent_declared_outputs"] ?? []
        job["previous_node_output_refs"] = job["previous_node_output_refs"] ?? []
        job["human_contacts"] = job["human_contacts"] ?? []
        job["metadata"] = job["metadata"] ?? [:]
        return job
    }

    static func maskedAgentSoul(_ soul: JSONObject) -> JSONObject {
        var soul = soul
        var env = soul["env"]?.object ?? [:]
        env["secret_refs"] = .array((env["secret_refs"]?.array ?? []).map { entry in
            guard var entry = entry.object else { return .null }
            entry["value"] = "********"
            return .object(entry)
        })
        soul["env"] = .object(env)
        return soul
    }

    static func agentComposerResponse(app: String, node: String, title: String, head: Int,
                                      config: StoredAgentConfig?, soul: JSONObject, job: JSONObject) -> JSONValue {
        let binding: JSONValue = config.map {
            ["id": .string($0.bindingId), "binding_type": "inline_agent", "agent_id": .string($0.agentId),
             "current_snapshot_id": .string($0.id), "workflow_id": "draft", "node_id": .string(node)]
        } ?? .null
        let summary: JSONValue = config.map {
            ["id": .string($0.id), "agent_id": .string($0.agentId), "version": .int($0.displayVersion),
             "display_version": .int($0.displayVersion), "snapshot_version": .int($0.revision),
             "version_note": .string($0.versionNote), "created_by": .string($0.createdBy), "created_at": .int(Int($0.createdAt.timeIntervalSince1970))]
        } ?? .null
        let agent: JSONValue = config.map {
            ["id": .string($0.agentId), "name": .string(title), "description": "", "scope": "workflow_only",
             "source": "workflow", "status": "active", "active_config_snapshot_id": .string($0.id)]
        } ?? .null
        let effective: [JSONValue] = [["name": "text", "type": "string", "required": false, "description": "Free-form text answer."]]
            + (job["declared_outputs"]?.array ?? [])
        return ["variant": "workflow", "app_id": .string(app), "workflow_id": "draft", "node_id": .string(node),
            "agent": agent, "active_config_snapshot": summary, "binding": binding,
            "soul_lock": ["locked": false, "can_unlock": true, "reason": .null],
            "agent_soul": .object(maskedAgentSoul(soul)), "node_job": .object(job),
            "effective_declared_outputs": .array(effective),
            "save_options": ["node_job_only", "save_to_current_version", "save_as_new_version"],
            "impact_summary": .null, "validation": ["warnings": [], "knowledge_retrieval_placeholder": []],
            "document_seq": .int(head)]
    }

    private func readAgentComposer(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let app = try await appOfMode(req, p, ["workflow"])
        let id = try nodeId(req)
        let snapshot = try await registry.sequencer(app.id).currentSnapshot()
        guard let node = snapshot.doc.nodes[id] else { throw ServerError.missing("Node not found") }
        let graph = try Self.agentNodeConfig(node)
        let stored = try await pinnedAgentConfig(app: app.id, node: id, graph: graph, snapshotOverride: query(req)["snapshot_id"])
        let soul = try stored.map { try JSONValue.parse($0.soul).object ?? [:] } ?? AgentInlineConfig.empty
        return rawJSON(Self.agentComposerResponse(app: app.id, node: id, title: node.title, head: snapshot.seq,
            config: stored, soul: soul, job: try Self.agentNodeJob(graph: graph, stored: stored)))
    }

    private func saveAgentComposer(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let app = try await appOfMode(req, p, ["workflow"])
        let id = try nodeId(req)
        let bytes = try await body(req)
        guard let payload = try JSONValue.parse(bytes).object, payload["variant"] == "workflow",
              case .int(let expected)? = payload["expected_seq"], expected >= 0,
              let key = payload["idempotency_key"]?.string, UUID(uuidString: key) != nil,
              let strategy = payload["save_strategy"]?.string,
              ["node_job_only", "save_to_current_version", "save_as_new_version"].contains(strategy) else {
            throw Self.invalidParam("Inline composer requires variant, save_strategy, expected_seq and a UUID idempotency_key")
        }
        let allowed: Set<String> = ["variant", "binding", "soul_lock", "agent_soul", "node_job", "save_strategy",
            "version_note", "idempotency_key", "client_revision_id", "expected_seq"]
        guard Set(payload.keys).isSubset(of: allowed), payload["binding"]?["binding_type"] == nil || payload["binding"]?["binding_type"] == "inline_agent" else {
            throw Self.invalidParam("Unsupported inline composer field or binding")
        }
        // Keys sorted recursively: insignificant JSON object ordering must not turn an identical retry into a conflict.
        let object = try JSONSerialization.jsonObject(with: bytes)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let digest = Tokens.sha256(String(decoding: canonical, as: UTF8.self))
        let requestID = key.lowercased()
        func response(_ receipt: AgentComposerReceipt) throws -> Response {
            guard receipt.nodeID == id, receipt.digest == digest else {
                throw ServerError.http(status: 409, code: "agent_idempotency_conflict", message: "This request ID has another payload")
            }
            return rawJSON(try JSONValue.parse(receipt.response))
        }
        if let receipt = try await store.agentComposerReceipt(doc: app.id, user: p.id, request: requestID) { return try response(receipt) }
        let store = store
        let routes = self
        _ = try await registry.sequencer(app.id).replace(client: "agent-" + p.id + "-" + requestID, cseq: 1) { doc, head -> (DocumentSequencer.ReplaceWork, Bool) in
            guard head == expected else {
                throw ServerError.http(status: 409, code: "agent_document_changed", message: "Reload the current workflow before saving this agent")
            }
            guard let node = doc.nodes[id] else { throw ServerError.missing("Node not found") }
            let graph = try Self.agentNodeConfig(node)
            let pinned = try await routes.pinnedAgentConfig(app: app.id, node: id, graph: graph)
            if let binding = payload["binding"]?.object {
                guard (binding["agent_id"] == .null ? nil : binding["agent_id"]) == pinned.map({ .string($0.agentId) }),
                      (binding["current_snapshot_id"] == .null ? nil : binding["current_snapshot_id"]) == pinned.map({ .string($0.id) }) else {
                    throw ServerError.http(status: 409, code: "agent_binding_changed", message: "The agent binding changed")
                }
            }
            let pointer = try await store.currentAgentConfig(doc: app.id, node: id)
            var oldSoul = try pinned.map { try JSONValue.parse($0.soul).object ?? [:] } ?? AgentInlineConfig.empty
            if strategy != "node_job_only", let value = payload["agent_soul"] {
                guard let soul = value.object else { throw Self.invalidParam("agent_soul must be an object") }
                oldSoul = soul
            } else if strategy == "node_job_only", let proposed = payload["agent_soul"], proposed != .object(Self.maskedAgentSoul(oldSoul)) {
                throw Self.invalidParam("node_job_only cannot modify agent_soul")
            }
            var soul: AgentInlineConfig
            do { soul = try AgentInlineConfig(oldSoul) } catch { throw Self.invalidParam("Invalid or unsupported agent_soul") }
            var job = try Self.agentNodeJob(graph: graph, stored: pinned)
            if let value = payload["node_job"] {
                guard let proposed = value.object, Set(proposed.keys).isSubset(of: ["schema_version", "mode", "workflow_prompt", "previous_node_output_refs", "declared_outputs", "human_contacts", "metadata"]),
                      proposed["mode"] == nil || proposed["mode"] == "tell_agent_what_to_do", proposed["schema_version"] == nil || proposed["schema_version"] == 1 else {
                    throw Self.invalidParam("Invalid workflow node job")
                }
                job = job.merging(proposed)
            }
            guard let task = job["workflow_prompt"]?.string, task.utf8.count <= 256 << 10,
                  let declarations = job["declared_outputs"]?.array else { throw Self.invalidParam("Invalid task or output declarations") }
            do { _ = try AgentDeclaredOutput.parse(declarations) } catch { throw Self.invalidParam("Invalid or unsupported output declarations") }
            for field in ["previous_node_output_refs", "human_contacts"] {
                guard job[field]?.array != nil else { throw Self.invalidParam("Invalid workflow node job list") }
            }
            if let metadata = job["metadata"], metadata.object == nil || !Set(metadata.object?.keys ?? []).isSubset(of: ["file_refs", "agent_soul"]) || (metadata["agent_soul"] != nil && metadata["agent_soul"] != .null) {
                throw Self.invalidParam("Invalid workflow node job metadata")
            }
            if var metadata = job["metadata"]?.object { metadata["agent_soul"] = nil; job["metadata"] = .object(metadata) }
            let snapshotID = UUID().uuidString.lowercased()
            var sealed: [String: String] = [:]
            let priorSoul = try pinned.map { try JSONValue.parse($0.soul).object ?? [:] } ?? [:]
            let prior = priorSoul["env"]?["secret_refs"]?.array ?? []
            var references: [JSONValue] = []
            for secret in soul.secretReferences {
                let name = AgentInlineConfig.environmentName(secret)
                let allowedSecret: Set<String> = ["name", "key", "env_name", "variable", "type", "value", "ref"]
                guard Set(secret.keys).isSubset(of: allowedSecret) else { throw Self.invalidParam("Unsupported secret reference") }
                var ref: String
                if let value = secret["value"]?.string, value != "********" {
                    ref = "agent-" + snapshotID + "-" + UUID().uuidString.lowercased()
                    sealed[ref] = value
                } else {
                    guard let existing = prior.first(where: { AgentInlineConfig.environmentName($0.object ?? [:]) == name }),
                          let old = existing["ref"]?.string, secret["ref"] == .string(old) else {
                        throw Self.invalidParam("An agent secret needs a new value or its existing reference")
                    }
                    ref = old
                }
                references.append(["name": .string(name), "ref": .string(ref)])
            }
            guard sealed.isEmpty || store.cipher != nil else { throw SecretsKeyMissing() }
            var environment = soul.json["env"]?.object ?? [:]
            environment["secret_refs"] = .array(references); soul.json["env"] = .object(environment)
            let config = StoredAgentConfig(id: snapshotID, agentId: pointer?.agentId ?? UUID().uuidString.lowercased(),
                bindingId: pointer?.bindingId ?? UUID().uuidString.lowercased(), docId: app.id, nodeId: id,
                revision: (pointer?.revision ?? 0) + 1, soul: JSONValue.object(soul.json).compactJSON(), createdBy: p.id,
                createdAt: Date(), nodeJob: JSONValue.object(job).compactJSON(),
                displayVersion: (pointer?.displayVersion ?? 1) + (strategy == "save_as_new_version" && pointer != nil ? 1 : 0),
                versionNote: payload["version_note"]?.string ?? pinned?.versionNote ?? "")
            let binding: JSONValue = ["id": .string(config.bindingId), "binding_type": "inline_agent", "agent_id": .string(config.agentId),
                "current_snapshot_id": .string(config.id)]
            let ops: [Op] = [
                .setField(id, .config(["agent_binding"]), try Self.agentCoreValue(binding)),
                .setField(id, .config(["agent_task"]), .string(task)),
                .setField(id, .config(["agent_declared_outputs"]), try Self.agentCoreValue(.array(declarations))),
            ]
            let reply = Self.agentComposerResponse(app: app.id, node: id, title: node.title, head: head + ops.count,
                config: config, soul: soul.json, job: job)
            let receipt = AgentComposerReceipt(requestID: requestID, userID: p.id, nodeID: id, digest: digest, response: reply.compactJSON())
            return (.init(ops: ops, metadata: nil, secrets: sealed,
                agentConfig: .init(snapshot: config, expectedSnapshotId: pointer?.id, receipt: receipt)), true)
        }
        guard let receipt = try await store.agentComposerReceipt(doc: app.id, user: p.id, request: requestID) else {
            throw ServerError.unavailable("The agent config commit could not be confirmed")
        }
        return try response(receipt)
    }
}
