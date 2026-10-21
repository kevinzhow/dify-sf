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
        // The panel's test mail: Dify's `.../delivery-test`, both app modes on the workflow path.
        apps.post(":app", "workflows", "draft", "human-input", "nodes", ":node", "delivery-test") { req in
            await handle(req) { try await sendDeliveryTest(req) }
        }
        apps.post(":app", "advanced-chat", "workflows", "draft", "human-input", "nodes", ":node", "delivery-test") { req in
            await handle(req) { try await sendDeliveryTest(req) }
        }
    }

    /// The node's config, its latest seq and the export the run routes read (one consistent read).
    private func humanInputNode(_ req: Request, mode: String) async throws -> (a: StoredApp, p: Principal, nodeId: String,
                                                                            data: JSONObject, exported: JSONValue, seq: Int) {
        let p = try await authenticate(req, .edit)
        guard config.humanInputWebEnabled else {
            throw ServerError.http(status: 501, code: "human_input_disabled", message: "Human input web forms are not enabled")
        }
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

    /// Dify's `test_human_input_delivery`: one message of the chosen delivery method, about a **delivery-test form** — a
    /// form of its own (no run, `form_kind: delivery_test`) whose link opens and validates the real form, and whose answer
    /// resumes nothing. In debug mode the message goes to the signed-in account, as Dify's recipient override does.
    private func sendDeliveryTest(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        guard config.humanInputWebEnabled && config.humanInputEmailEnabled else {
            throw ServerError.http(status: 501, code: "human_input_email_disabled", message: "Human input email delivery is not enabled")
        }
        let a = try await appOfMode(req, p, Self.workflowModes)
        let nodeId = try nodeId(req)
        let b = try await objectBody(req)
        guard let methodId = b["delivery_method_id"]?.string else { throw Self.invalidParam("missing delivery_method_id") }
        let inputs = b["inputs"]?.object ?? [:]
        let snapshot = try await registry.sequencer(a.id).currentSnapshot()
        let metadata = try await currentMetadata(a.id, viewer: p.id)
        let secrets: [String: String]
        do { secrets = try await store.secrets(a.id) } catch { throw ServerError.unavailable("\(error)") }
        let exported = try JSONValue.parse(try WireJSON.encode(try DifyDSL.exportValue(snapshot.doc, metadata: metadata, secrets: secrets)))
        let graph = try GraphConfig(json: exported["workflow"]?["graph"] ?? .null)
        guard let node = graph.node(nodeId) else { throw ServerError.missing("Node \(nodeId) not found") }
        guard node.type == NodeType.humanInput else { throw ServerError.badRequest("Node type must be human-input.") }
        let form: HumanInputFormConfig
        do { form = try HumanInputFormConfig(node.data) } catch let e as NodeDataError { throw Self.invalidParam(e.description) }
        guard let index = form.deliveryMethods.firstIndex(where: { $0["id"]?.string == methodId }) else {
            throw Self.invalidParam("Delivery method not found.")
        }
        let method = form.deliveryMethods[index]
        guard method["type"]?.string == "email" else {
            throw Self.invalidParam("Delivery method does not support test send.")
        }
        let pool = try await humanInputPool(appId: a.id, userId: p.id, nodeId: nodeId, form: form, inputs: inputs, exported: exported)
        // Debug mode addresses the signed-in account; otherwise the method's own recipients (members and addresses).
        var members: [String: String] = [:]
        do { members = Dictionary(uniqueKeysWithValues: try await store.members().map { ($0.id, $0.email) }) } catch {}
        var recipients = HumanInputMail.recipients([method], members: members)
        if method["config"]?["debug_mode"]?.bool ?? false {
            recipients = [HumanInputMail.Recipient(email: p.account.email, method: 0, type: "member", referenceId: p.id)]
        }
        guard !recipients.isEmpty else { throw ServerError.badRequest("Delivery method has no recipients.") }
        let now = Date()
        let rendered = form.renderedContent(pool: pool)
        let defaults = form.resolvedDefaults(pool: pool)
        let testForm = StoredHumanInputForm(
            id: UUID().uuidString.lowercased(), workflowRunId: nil, executionId: UUID().uuidString.lowercased(), docId: a.id,
            nodeId: nodeId, nodeTitle: form.base.title, token: UUID().uuidString.lowercased(), formContent: form.content,
            inputs: JSONValue.array(form.inputs.map(JSONValue.object)).compactJSON(),
            userActions: JSONValue.array(form.actions.map(JSONValue.object)).compactJSON(), renderedContent: rendered,
            resolvedDefaultValues: JSONValue.object(defaults).compactJSON(),
            actions: JSONValue.array(form.actions.map(JSONValue.object)).compactJSON(), displayInUi: false,
            createdAt: now, recipientType: .webapp, kind: .deliveryTest)
        do { try await store.insertForm(testForm) } catch { throw ServerError.unavailable("\(error)") }
        let rows = recipients.map {
            StoredFormRecipient(token: UUID().uuidString.lowercased(), formId: testForm.id, workflowRunId: nil,
                                methodIndex: index, type: $0.type, referenceId: $0.referenceId, email: $0.email, createdAt: now)
        }
        do { try await store.addFormRecipients(rows) } catch { throw ServerError.unavailable("\(error)") }
        let outbox = MailOutbox(sender: SMTPMailSender(config: config.mail), logger: logger)
        guard outbox.isEnabled, let base = Optional(config.webAppBaseURL), !base.isEmpty else {
            throw ServerError.badRequest("Mail is not configured (no SMTP, no COLLAB_WEBAPP_BASE_URL).")
        }
        // A test mail that did not go out is not a success: the panel shows Dify's error instead of claiming the mail was
        // sent. (The delivery-test form and its recipient rows stay; they simply never become "mailed".)
        var sent = 0
        var firstFailure: String?
        for row in rows {
            guard let link = HumanInputMail.link(base: base, token: row.token),
                  let message = HumanInputMail.message(form.deliveryMethods, methodIndex: index, to: row.email, link: link, pool: pool) else {
                firstFailure = firstFailure ?? "the delivery method's message could not be rendered"
                continue
            }
            if await outbox.send(message, kind: "human input test") {
                sent += 1
                try? await store.markFormRecipientMailed(token: row.token, at: Date())
            } else {
                firstFailure = firstFailure ?? "the mail could not be sent"
            }
        }
        guard sent > 0 else {
            throw ServerError.http(status: 502, code: "email_send_failed",
                                   message: firstFailure ?? "the test mail could not be sent")
        }
        struct Empty: Encodable {}
        return try json(Empty())
    }

    private func objectBody(_ req: Request) async throws -> JSONObject {
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(var b) = parsed else {
            throw ServerError.badRequest("the body must be a JSON object")
        }
        // The method id is a string in Dify's model, whatever the document wrote it as. (The decoder's message for a
        // numeric id is "the body must be a JSON object", because the struct's `delivery_method_id` is a `String`.)
        if let id = b["delivery_method_id"], id.string == nil {
            if let n = id.int { b["delivery_method_id"] = .string(String(n)) }
            else if let d = id.double { b["delivery_method_id"] = .string(d == d.rounded() ? String(Int(d)) : String(d)) }
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
