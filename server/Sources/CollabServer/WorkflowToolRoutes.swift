import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import Vapor

extension Routes {
    func publishedWorkflow(_ appId: String, versionId: String? = nil, viewer: String) async throws -> (StoredVersion, JSONValue) {
        guard let app = try await store.app(appId, viewer: viewer), !app.deleted, app.mode == "workflow" else { throw ServerError.notFound }
        let version: StoredVersion?
        if let versionId { version = try await store.version(appId, id: versionId) }
        else { version = try await store.latestVersion(appId) }
        guard let version else { throw Self.invalidParam("Publish the workflow first") }
        let secrets = try await store.secrets(appId)
        let root = try DifyDSL.exportValue(WireJSON.decode(Document.self, from: version.state), metadata: WireJSON.decode(Value.self, from: version.dsl), secrets: secrets)
        return (version, try JSONValue.parse(WireJSON.encode(root))["workflow"] ?? .null)
    }
    func registerWorkflowTools(on r: any RoutesBuilder) {
        let w = r.grouped("v1", "workspaces", "current")
        w.get("tools", "workflow") { req in await handle(req) {
            _ = try await authenticate(req)
            return try json(JSONValue.array(try await store.workflowTools().map { try workflowToolProjection($0) }))
        } }
        let p = w.grouped("tool-provider", "workflow")
        p.get("preview") { req in await handle(req) {
            let user = try await authenticate(req, .edit)
            guard let appId = req.query[String.self, at: "workflow_app_id"] else { throw Self.invalidParam("workflow_app_id is required") }
            let (version, workflow) = try await publishedWorkflow(appId, viewer: user.id)
            return try json(try workflowToolSchema(workflow, versionId: version.id))
        } }
        p.get("get") { req in await handle(req) {
            _ = try await authenticate(req)
            let id = req.query[String.self, at: "workflow_tool_id"], app = req.query[String.self, at: "workflow_app_id"]
            guard let value = try await store.workflowTools().first(where: { id != nil ? $0.id == id : $0.appId == app }) else { throw ServerError.notFound }
            return try json(try workflowToolProjection(value))
        } }
        p.get("tools") { req in await handle(req) {
            _ = try await authenticate(req)
            let id = req.query[String.self, at: "workflow_tool_id"]
            guard let value = try await store.workflowTools().first(where: { $0.id == id }) else { throw ServerError.notFound }
            return try json(try workflowToolProjection(value)["tools"] ?? .array([]))
        } }
        p.post("create") { req in await handle(req) { try await saveWorkflowTool(req, update: false) } }
        p.post("update") { req in await handle(req) { try await saveWorkflowTool(req, update: true) } }
        p.post("delete") { req in await handle(req) {
            let user = try await authenticate(req, .edit), body = try await toolBody(req)
            guard let id = body["workflow_tool_id"]?.string else { throw Self.invalidParam("workflow_tool_id is required") }
            try await modelStoreCall { try await store.deleteWorkflowTool(id: id, userId: user.id, privileged: user.role.isPrivileged) }
            return try ok()
        } }
    }
    func workflowToolProjection(_ tool: StoredWorkflowTool) throws -> JSONValue {
        var definition = try JSONValue.parse(Array(tool.definition.utf8)).object ?? [:]
        definition["name"] = .string(tool.name)
        return ["id": .string(tool.id), "name": .string(tool.name), "type": "workflow", "author": .string(tool.createdBy),
                "label": definition["label"] ?? ["en_US": .string(tool.name)], "description": definition["description"] ?? .object([:]),
                "icon": definition["icon"] ?? .null, "is_team_authorization": true,
                "workflow_app_id": .string(tool.appId), "workflow_tool_id": .string(tool.id), "version_id": .string(tool.versionId),
                "tools": [.object(definition)]]
    }
    func workflowToolSchema(_ workflow: JSONValue, versionId: String) throws -> JSONValue {
        let graph = try GraphConfig(json: workflow["graph"] ?? .null)
        let root = try RuntimeGraph.defaultRootId(graph)
        guard let node = graph.nodes.first(where: { $0.id == root }), node.type == "start",
              !graph.nodes.contains(where: { $0.type == "human-input" || $0.type.hasPrefix("trigger-") }) else {
            throw Self.invalidParam("Workflow tools need a Start node and cannot contain triggers or human input")
        }
        let start = try StartNode(id: root, data: node.data)
        let parameters: [JSONValue] = start.variables.map { variable in
            let type: String
            switch variable.type { case "number": type = "number"; case "checkbox": type = "boolean"; case "file": type = "file"; case "file-list": type = "files"; case "json_object": type = "object"; default: type = "string" }
            return ["name": .string(variable.variable), "label": ["en_US": .string(variable.variable)], "type": .string(type), "form": "llm", "required": .bool(variable.required), "default": variable.defaultValue ?? .null]
        }
        var outputs: [JSONValue] = [], properties = JSONObject()
        for node in graph.nodes where node.type == "end" {
            for output in node.data["outputs"]?.array ?? [] {
                guard let name = output["variable"]?.string, !name.isEmpty,
                      !["text", "json", "files"].contains(name), properties[name] == nil else {
                    throw Self.invalidParam("Workflow tool outputs must have unique names other than text, json and files")
                }
                let type = output["value_type"]?.string ?? "string"
                outputs.append(["name": .string(name), "type": .string(type)])
                properties[name] = ["type": .string(type == "number" ? "number" : type == "boolean" ? "boolean" : type.hasPrefix("array") ? "array" : type == "object" ? "object" : "string")]
            }
        }
        return ["version_id": .string(versionId), "parameters": .array(parameters), "outputs": .array(outputs), "output_schema": ["type": "object", "properties": .object(properties)]]
    }
    func saveWorkflowTool(_ req: Request, update: Bool) async throws -> Response {
        let user = try await authenticate(req, .edit), body = try await toolBody(req)
        let old = update ? try await store.workflowTools().first(where: { $0.id == body["workflow_tool_id"]?.string }) : nil
        if update && old == nil { throw ServerError.notFound }
        guard let appId = old?.appId ?? body["workflow_app_id"]?.string,
              let name = body["name"]?.string, !name.isEmpty, name.count <= 64,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { throw Self.invalidParam("workflow_app_id and an alphanumeric tool name are required") }
        let (version, workflow) = try await publishedWorkflow(appId, viewer: user.id)
        let schema = try workflowToolSchema(workflow, versionId: version.id)
        let custom = body["parameters"]?.array ?? []
        let derived = schema["parameters"]?.array ?? []
        guard custom.allSatisfy({ p in derived.contains { $0["name"] == p["name"] } }),
              Set(custom.compactMap { $0["name"]?.string }).count == custom.count else { throw Self.invalidParam("Unknown or duplicate tool input") }
        var definition = body
        definition["parameters"] = .array(derived.map { parameter in
            var value = parameter.object ?? [:]
            if let input = custom.first(where: { $0["name"] == parameter["name"] }) {
                value["llm_description"] = input["description"] ?? ""
                value["form"] = input["form"] == "form" ? "form" : "llm"
            }
            return .object(value)
        })
        definition["output_schema"] = schema["output_schema"]
        definition["name"] = .string(name)
        if definition["label"]?.object == nil { definition["label"] = ["en_US": body["label"]?.string.map(JSONValue.string) ?? .string(name)] }
        if definition["description"]?.object == nil { definition["description"] = ["en_US": body["description"] ?? ""] }
        let saved = try await modelStoreCall { try await store.saveWorkflowTool(id: old?.id, appId: appId, versionId: version.id,
            name: name, definition: JSONValue.object(definition).compactJSON(), userId: user.id, privileged: user.role.isPrivileged) }
        return try json(JSONValue.object(["result": "success", "workflow_tool_id": .string(saved), "id": .string(saved)]))
    }
}
