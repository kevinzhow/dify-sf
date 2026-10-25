// Dify 1.17.1 services/agent/dsl_entities.py and dsl_service.py: portable inline Agent packages.
import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation

struct AgentPackagePlan: Sendable {
    var configurations: [String: JSONObject] = [:]
    var changes: [AgentConfigCommit] = []
    var metadata: Value

    func initialDocument(_ source: Document) throws -> Document {
        let nodes = try source.nodes.values.map { value -> CollabCore.Node in
            var node = value
            if let config = configurations[node.id] {
                for (key, value) in config { node.config[key] = try Routes.agentCoreValue(value) }
                node.config["agent_job"] = nil
            }
            return node
        }
        return Document(nodes: nodes, edges: Array(source.edges.values), app: source.app)
    }

    func bindingOps() throws -> [Op] {
        try configurations.keys.sorted().flatMap { id -> [Op] in
            var operations = try configurations[id]!.keys.sorted().map { key in
                Op.setField(id, .config([key]), try Routes.agentCoreValue(configurations[id]![key]!))
            }
            operations.append(.setField(id, .config(["agent_job"]), .null))
            return operations
        }
    }
}

extension Routes {
    /// Packages never include workspace credential/secret/file locators, even for include_secret exports.
    /// Missing file and secret definitions remain visible so an import cannot silently become a complete runnable agent.
    static func portableAgentSoul(_ raw: JSONObject) -> JSONObject {
        var soul = raw
        if var model = soul["model"]?.object { model["credential_ref"] = .null; soul["model"] = .object(model) }
        soul["config_files"] = .array((soul["config_files"]?.array ?? []).map { entry in
            var file = entry.object ?? [:]; file["file_id"] = ""; file["is_missing"] = true
            return .object(file)
        })
        var env = soul["env"]?.object ?? [:]
        env["secret_refs"] = .array((env["secret_refs"]?.array ?? []).map { entry in
            ["name": .string(AgentInlineConfig.environmentName(entry.object ?? [:]))]
        })
        soul["env"] = .object(env)
        var human = soul["human"]?.object ?? [:]
        human["contacts"] = .array((human["contacts"]?.array ?? []).map { entry -> JSONValue in
            var contact = entry.object ?? [:]
            for key in ["id", "contact_id", "human_id", "tenant_id"] { contact[key] = .null }
            return .object(contact)
        })
        soul["human"] = .object(human)
        return soul
    }

    /// Canonical omitted-file marker remains an editable declared default but carries no source locator.
    static let omittedAgentFile: JSONValue = ["transfer_method": "tool_file", "reference": "dify-file-ref:eyJyZWNvcmRfaWQiOiJvbWl0dGVkIn0="]

    static func portableDefault(_ value: JSONValue, definition: JSONObject) -> JSONValue {
        if definition["type"] == "file" { return omittedAgentFile }
        if definition["type"] == "array", let items = value.array {
            return .array(items.map { portableDefault($0, definition: definition["array_item"]?.object ?? [:]) })
        }
        if definition["type"] == "object", var object = value.object {
            for child in definition["children"]?.array ?? [] {
                if let shape = child.object, let name = shape["name"]?.string, let item = object[name] {
                    object[name] = portableDefault(item, definition: shape)
                }
            }
            return .object(object)
        }
        return value
    }

    static func portableAgentJob(_ source: JSONObject) -> JSONObject {
        var job = source
        job["declared_outputs"] = .array((source["declared_outputs"]?.array ?? []).map { value in
            guard var definition = value.object else { return value }
            if var strategy = definition["failure_strategy"]?.object, let fallback = strategy["default_value"], fallback != .null {
                strategy["default_value"] = portableDefault(fallback, definition: definition)
                definition["failure_strategy"] = .object(strategy)
            }
            return .object(definition)
        })
        var metadata = source["metadata"]?.object ?? [:]
        metadata["file_refs"] = .array((metadata["file_refs"]?.array ?? []).enumerated().map { index, value in
            ["name": .string(value["name"]?.string ?? value["filename"]?.string ?? "Task file " + String(index + 1)), "is_missing": true]
        })
        job["metadata"] = .object(metadata)
        return job
    }

    func agentExportValue(_ document: Document, metadata: Value, secrets: [String: String]?, app: String, allowClipboardPlaceholders: Bool = false) async throws -> Value {
        let exported = try DifyDSL.exportValue(document, metadata: metadata, secrets: secrets)
        if !document.nodes.values.contains(where: { $0.type == "agent" && $0.config["version"] == .string("2") }) { return exported }
        var root = try JSONValue.parse(try WireJSON.encode(exported)).object ?? [:]
        var workflow = root["workflow"]?.object ?? [:], graph = workflow["graph"]?.object ?? [:]
        var nodes = graph["nodes"]?.array ?? []
        var packages = JSONObject(), references: [String: String] = [:]
        for index in nodes.indices {
            guard var node = nodes[index].object, let id = node["id"]?.string,
                  let source = document.nodes[id], source.type == "agent", source.config["version"] == .string("2") else { continue }
            var data = node["data"]?.object ?? [:]
            if allowClipboardPlaceholders, data["agent_binding"]?["binding_type"] == "roster_agent" {
                data["agent_binding"] = ["binding_type": "roster_agent"]
                data["agent_job"] = nil
                node["data"] = .object(data); nodes[index] = .object(node)
                continue
            }
            let config = try Self.agentNodeConfig(source)
            guard let stored = try await pinnedAgentConfig(app: app, node: id, graph: config) else { continue }
            let key: String
            if let existing = references[stored.id] { key = existing }
            else {
                key = "agent_" + String(packages.count + 1); references[stored.id] = key
                let original = try JSONValue.parse(stored.soul).object ?? [:]
                let hints: [JSONValue] = (original["config_files"]?.array ?? []).map { file in
                    var hint = file.object ?? [:]
                    for field in ["file_id", "file_kind", "is_missing"] { hint[field] = nil }
                    hint["kind"] = "file"
                    return .object(hint)
                }
                packages[key] = ["schema_version": 1, "metadata": ["name": .string(source.title.isEmpty ? "Agent" : source.title),
                    "description": "", "role": ""], "soul": .object(Self.portableAgentSoul(original)),
                    "omitted_assets": .array(hints), "workspace_skills": []]
            }
            data["agent_binding"] = ["binding_type": "inline_agent", "package_ref": .string(key)]
            let job = Self.portableAgentJob(try Self.agentNodeJob(graph: config, stored: stored))
            data["agent_job"] = .object(job)
            data["agent_declared_outputs"] = job["declared_outputs"]
            node["data"] = .object(data); nodes[index] = .object(node)
        }
        graph["nodes"] = .array(nodes); workflow["graph"] = .object(graph); root["workflow"] = .object(workflow)
        root["agent_packages"] = packages.isEmpty ? nil : .object(packages)
        return try Self.agentCoreValue(.object(root))
    }

    static func validateAgentPackage(_ value: JSONValue) throws {
        guard let package = value.object, package["schema_version"] == 1,
              Set(package.keys).isSubset(of: ["schema_version", "metadata", "soul", "omitted_assets", "workspace_skills"]),
              let meta = package["metadata"]?.object,
              Set(meta.keys).isSubset(of: ["name", "description", "role", "icon_type", "icon", "icon_background"]),
              let name = meta["name"]?.string, !name.isEmpty, name.count <= 255,
              let soul = package["soul"]?.object,
              package["workspace_skills"] == nil || package["workspace_skills"]?.array != nil,
              (package["workspace_skills"]?.array ?? []).isEmpty,
              package["omitted_assets"] == nil || package["omitted_assets"]?.array != nil,
              (package["omitted_assets"]?.array ?? []).count <= 256 else { throw Self.invalidParam("Invalid Agent package") }
        for (key, value) in meta where key != "name" {
            guard value.string != nil || (["icon_type", "icon", "icon_background"].contains(key) && value == .null) else { throw Self.invalidParam("Invalid Agent package metadata") }
        }
        for value in package["omitted_assets"]?.array ?? [] {
            guard let asset = value.object, Set(asset.keys).isSubset(of: ["kind", "name", "size", "hash", "mime_type"]),
                  ["file", "skill"].contains(asset["kind"]?.string ?? ""), asset["name"]?.string != nil else { throw Self.invalidParam("Invalid omitted Agent asset") }
            if let size = asset["size"], size != .null { guard case .int(let number) = size, number >= 0 else { throw Self.invalidParam("Invalid omitted asset size") } }
            for key in ["hash", "mime_type"] { if let entry = asset[key], entry != .null, entry.string == nil { throw Self.invalidParam("Invalid omitted asset metadata") } }
        }
        do { _ = try AgentInlineConfig(soul) } catch { throw Self.invalidParam("Invalid Agent package configuration") }
    }

    /// Materialize node-owned identities before the existing create/replace transaction. Its rollback also rolls back
    /// the private snapshots. Same-app restores may explicitly preserve their already-owned immutable bindings.
    func agentImportPlan(_ document: Document, metadata: Value, app: String, user: String,
                         preserveLocalBindings: Bool = false, allowClipboardPlaceholders: Bool = false) async throws -> AgentPackagePlan {
        if !document.nodes.values.contains(where: { $0.type == "agent" && $0.config["version"] == .string("2") }),
           case .map(let top) = metadata, top["agent_packages"] == nil { return AgentPackagePlan(metadata: metadata) }
        var meta = try JSONValue.parse(try WireJSON.encode(metadata)).object ?? [:]
        let raw = meta["agent_packages"]; meta["agent_packages"] = nil
        guard raw == nil || raw?.object != nil else { throw Self.invalidParam("agent_packages must be an object") }
        let packages = raw?.object ?? [:]
        guard packages.count <= 128 else { throw Self.invalidParam("Too many Agent packages") }
        for (_, value) in packages { try Self.validateAgentPackage(value) }
        var plan = AgentPackagePlan(metadata: try Self.agentCoreValue(.object(meta)))
        for node in document.nodes.values.sorted(by: { $0.id < $1.id }) where node.type == "agent" && node.config["version"] == .string("2") {
            if allowClipboardPlaceholders, node.config["agent_binding"] == .map(["binding_type": .string("roster_agent")]) { continue }
            let graph = try Self.agentNodeConfig(node)
            let binding = graph["agent_binding"]?.object ?? [:]
            guard let reference = binding["package_ref"]?.string else {
                if binding["agent_id"]?.string != nil || binding["current_snapshot_id"]?.string != nil {
                    guard preserveLocalBindings,
                          try await pinnedAgentConfig(app: app, node: node.id, graph: graph) != nil else {
                        throw Self.invalidParam("Inline Agents must be imported with their portable packages")
                    }
                }
                continue
            }
            guard let package = packages[reference]?.object, package["schema_version"] == 1,
                  Set(package.keys).isSubset(of: ["schema_version", "metadata", "soul", "omitted_assets", "workspace_skills"]),
                  let metadata = package["metadata"]?.object,
                  Set(metadata.keys).isSubset(of: ["name", "description", "role", "icon_type", "icon", "icon_background"]),
                  let name = metadata["name"]?.string, !name.isEmpty, name.count <= 255,
                  let rawSoul = package["soul"]?.object,
                  (package["workspace_skills"] == nil || package["workspace_skills"]?.array != nil),
                  (package["workspace_skills"]?.array ?? []).isEmpty,
                  (package["omitted_assets"] == nil || package["omitted_assets"]?.array != nil) else {
                throw Self.invalidParam("Invalid or unsupported inline Agent package")
            }
            do { _ = try AgentInlineConfig(rawSoul) } catch { throw Self.invalidParam("Invalid inline Agent package configuration") }
            var portable: JSONObject = Self.portableAgentSoul(rawSoul)
            var human: JSONObject = portable["human"]?.object ?? [:]
            human["contacts"] = .array((human["contacts"]?.array ?? []).map { entry -> JSONValue in
                var contact = entry.object ?? [:]; contact["id"] = .string(UUID().uuidString.lowercased()); return .object(contact)
            })
            portable["human"] = .object(human)
            let soul: AgentInlineConfig
            do { soul = try AgentInlineConfig(portable) } catch { throw Self.invalidParam("Invalid or unsupported inline Agent package configuration") }
            var job = try Self.agentNodeJob(graph: graph, stored: nil)
            if let imported = graph["agent_job"] {
                guard let value = imported.object, Set(value.keys).isSubset(of: ["schema_version", "mode", "workflow_prompt", "declared_outputs", "previous_node_output_refs", "human_contacts", "metadata"]),
                      value["schema_version"] == nil || value["schema_version"] == 1,
                      value["mode"] == nil || value["mode"] == "tell_agent_what_to_do" else { throw Self.invalidParam("Invalid Agent node job") }
                job = job.merging(value)
            }
            guard let originalMetadata = job["metadata"]?.object,
                  Set(originalMetadata.keys).isSubset(of: ["file_refs"]),
                  originalMetadata["file_refs"] == nil || originalMetadata["file_refs"]?.array != nil,
                  (originalMetadata["file_refs"]?.array ?? []).count <= 128,
                  (originalMetadata["file_refs"]?.array ?? []).allSatisfy({ $0.object != nil }),
                  let originalDeclarations = job["declared_outputs"]?.array else { throw Self.invalidParam("Invalid Agent node job") }
            do { _ = try AgentDeclaredOutput.parse(originalDeclarations) } catch { throw Self.invalidParam("Invalid Agent output declarations") }
            job = Self.portableAgentJob(job)
            guard let task = job["workflow_prompt"]?.string, task.utf8.count <= 256 << 10,
                  let declarations = job["declared_outputs"]?.array,
                  job["previous_node_output_refs"]?.array != nil, job["human_contacts"]?.array != nil,
                  let jobMetadata = job["metadata"]?.object,
                  Set(jobMetadata.keys).isSubset(of: ["file_refs"]) else { throw Self.invalidParam("Invalid Agent node job") }
            do { _ = try AgentDeclaredOutput.parse(declarations) } catch { throw Self.invalidParam("Invalid Agent output declarations") }
            let old = try await store.currentAgentConfig(doc: app, node: node.id)
            let config = StoredAgentConfig(id: UUID().uuidString.lowercased(), agentId: old?.agentId ?? UUID().uuidString.lowercased(),
                bindingId: old?.bindingId ?? UUID().uuidString.lowercased(), docId: app, nodeId: node.id, revision: (old?.revision ?? 0) + 1,
                soul: JSONValue.object(soul.json).compactJSON(), createdBy: user, createdAt: Date(), nodeJob: JSONValue.object(job).compactJSON())
            let receipt = AgentComposerReceipt(requestID: UUID().uuidString.lowercased(), userID: user, nodeID: node.id,
                digest: "portable-agent-import-v1", response: "{}")
            plan.changes.append(.init(snapshot: config, expectedSnapshotId: old?.id, receipt: receipt))
            plan.configurations[node.id] = ["agent_binding": ["binding_type": "inline_agent", "agent_id": .string(config.agentId),
                "current_snapshot_id": .string(config.id)], "agent_task": .string(task), "agent_declared_outputs": .array(declarations)]
        }
        return plan
    }
}


extension Routes {
    func createAgentAwareDocument(id: String, imported: DifyDSL.Imported, app: NewApp, user: String) async throws -> Bool {
        let plan = try await agentImportPlan(imported.document, metadata: imported.metadata, app: id, user: user)
        return try await store.createDocument(id: id, initial: plan.initialDocument(imported.document), metadata: plan.metadata,
            secrets: imported.secrets, app: app, agentConfigs: plan.changes)
    }
}
