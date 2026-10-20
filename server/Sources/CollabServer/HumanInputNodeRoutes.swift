import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// A human-input node's own form in the console (protocol 1.16): Dify's `WorkflowService.get_human_input_form_preview`
/// and `submit_human_input_form_preview` over `controllers/console/app/workflow.py`'s
/// `/apps/{app}/{advanced-chat/}workflows/draft/human-input/nodes/{node}/form/{preview,run}`.
///
/// The node's panel "runs" a human-input node by showing the form it would render and recording the answers as the
/// node's draft variables — no workflow run happens. The form is built from the node's config at the document's current
/// seq (`HumanInputFormConfig`, the same parser a real pause uses), its content rendered against the values the panel
/// supplies plus the account's draft variables, and the submission validated by the engine's own rules
/// (`validateSubmission`), so the panel cannot accept what a resumed run would refuse.
extension Routes {
    func registerHumanInputNode(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.post(":app", "workflows", "draft", "human-input", "nodes", ":node", "form", "preview") { req in
            await handle(req) { try await humanInputFormPreview(req, mode: "workflow") }
        }
        apps.post(":app", "workflows", "draft", "human-input", "nodes", ":node", "form", "run") { req in
            await handle(req) { try await submitHumanInputFormPreview(req, mode: "workflow") }
        }
        apps.post(":app", "advanced-chat", "workflows", "draft", "human-input", "nodes", ":node", "form", "preview") { req in
            await handle(req) { try await humanInputFormPreview(req, mode: "advanced-chat") }
        }
        apps.post(":app", "advanced-chat", "workflows", "draft", "human-input", "nodes", ":node", "form", "run") { req in
            await handle(req) { try await submitHumanInputFormPreview(req, mode: "advanced-chat") }
        }
    }

    /// The node's config, its latest seq and the export the run routes read (one consistent read).
    private func humanInputNode(_ req: Request, mode: String) async throws -> (a: StoredApp, p: Principal, nodeId: String,
                                                                            data: JSONObject, exported: JSONValue, seq: Int) {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, [mode])
        let nodeId = try nodeId(req)
        let snapshot = try await registry.sequencer(a.id).currentSnapshot()
        let metadata = try await currentMetadata(a.id, viewer: p.id)
        let secrets: [String: String]
        do { secrets = try await store.secrets(a.id) } catch { throw ServerError.unavailable("\(error)") }
        let exported = try JSONValue.parse(try WireJSON.encode(try DifyDSL.exportValue(snapshot.doc, metadata: metadata, secrets: secrets)))
        let graph = try GraphConfig(json: exported["workflow"]?["graph"] ?? .null)
        guard let node = graph.node(nodeId) else { throw ServerError.missing("Node \(nodeId) not found") }
        guard node.type == NodeType.humanInput else {
            throw ServerError.badRequest("Node type must be human-input.")
        }
        return (a, p, nodeId, node.data, exported, snapshot.seq)
    }

    /// The pool a preview renders against: the system and environment values, the account's draft variables for what the
    /// node reads, then the values the request supplies (`WorkflowService._build_human_input_variable_pool`).
    private func humanInputPool(appId: String, userId: String, nodeId: String, form: HumanInputFormConfig,
                                inputs: JSONObject, exported: JSONValue) async throws -> VariablePool {
        var pool = VariablePool()
        try pool.add([VariablePool.systemNodeId, "workflow_run_id"], .string(UUID().uuidString.lowercased()))
        try pool.add([VariablePool.systemNodeId, "files"], .array([]))
        for v in exported["workflow"]?["environment_variables"]?.array ?? [] {
            guard let name = v["name"]?.string else { continue }
            try pool.add([VariablePool.environmentNodeId, name], v["value"] ?? .null)
        }
        let mapping = form.variableMapping(nodeId: nodeId)
        let missing = try DraftVariableRules.selectorsToLoad(mapping: mapping, userInputs: inputs, pool: pool)
        if !missing.isEmpty {
            for (selector, segment) in try await loadDraftVariables(appId: appId, userId: userId, selectors: missing)
            where selector.count == VariablePool.selectorsLength {
                try pool.add(selector, segment)
            }
        }
        do { try SingleStepRun.mapUserInputs(mapping, inputs, &pool) } catch let e as SingleStepRun.InvalidInput {
            throw Self.invalidParam(e.description)
        }
        return pool
    }

    private func objectBody(_ req: Request) async throws -> JSONObject {
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw ServerError.badRequest("the body must be a JSON object")
        }
        return b
    }

    /// Dify's `HumanInputFormPreviewResponse`: the form as the node would show it.
    private func humanInputFormPreview(_ req: Request, mode: String) async throws -> Response {
        let (a, p, nodeId, data, exported, _) = try await humanInputNode(req, mode: mode)
        let inputs = try await objectBody(req)["inputs"]?.object ?? [:]
        let form: HumanInputFormConfig
        do { form = try HumanInputFormConfig(data) } catch let e as NodeDataError { throw Self.invalidParam(e.description) }
        let pool = try await humanInputPool(appId: a.id, userId: p.id, nodeId: nodeId, form: form, inputs: inputs, exported: exported)
        return rawJSON(.object([
            "form_id": .string(nodeId),
            "node_id": .string(nodeId),
            "node_title": .string(form.base.title),
            "form_content": .string(form.renderedContent(pool: pool)),
            "inputs": .array(form.inputs.map(JSONValue.object)),
            "actions": .array(form.actions.map(JSONValue.object)),
            "display_in_ui": .null,
            "form_token": .null,
            "resolved_default_values": .object(form.resolvedDefaults(pool: pool)),
            "expiration_time": .null,
        ]))
    }

    /// Dify's `HumanInputFormSubmitResponse`: the outputs the answers make (`__action_id`, `__action_value` and the
    /// rendered content included), recorded as the node's draft variables.
    private func submitHumanInputFormPreview(_ req: Request, mode: String) async throws -> Response {
        let (a, p, nodeId, data, exported, seq) = try await humanInputNode(req, mode: mode)
        let b = try await objectBody(req)
        guard let formInputs = b["form_inputs"]?.object else { throw Self.invalidParam("missing form_inputs") }
        guard let action = b["action"]?.string else { throw Self.invalidParam("missing action") }
        let inputs = b["inputs"]?.object ?? [:]
        let form: HumanInputFormConfig
        do { form = try HumanInputFormConfig(data) } catch let e as NodeDataError { throw Self.invalidParam(e.description) }
        let pool = try await humanInputPool(appId: a.id, userId: p.id, nodeId: nodeId, form: form, inputs: inputs, exported: exported)
        let result: NodeRunResult
        do {
            result = try form.completion(action: action, values: formInputs, renderedContent: form.renderedContent(pool: pool))
        } catch let e as HumanInputFormConfig.InvalidSubmission {
            throw Self.invalidFormData(e.description)
        }
        let outputs = result.outputs ?? [:]
        do {
            try await saveDraftVariables(appId: a.id, userId: p.id, docSeq: seq, nodeId: nodeId, nodeType: NodeType.humanInput,
                                         executionId: UUID().uuidString.lowercased(), processData: nil, outputs: outputs)
        } catch {
            logger.error("saving the draft variables of human input node \(nodeId) failed: \(error)")
        }
        return rawJSON(.object(outputs))
    }
}
