import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Dify's console human-input form API (protocol 1.16).
///
/// `GET /v1/form/human_input/{token}` returns the form's definition exactly as Dify's console does (`_jsonify_form_definition`
/// in `controllers/console/human_input_form.py`: the FormDefinition fields, then `expiration_time` as Unix seconds).
/// `POST` submits one: Dify's `HumanInputFormSubmitPayload` is `{inputs, action}`, and the answer is `{}`.
///
/// The token is the capability Dify hands a recipient; an unknown token is 404, a closed form is 412 with Dify's code.
/// Field validation is the engine's own (`HumanInputFormConfig.validateSubmission`), rebuilt from the persisted
/// definition — a second implementation in the route would drift from what the node enforces when it resumes.
extension Routes {
    func registerHumanInput(on r: any RoutesBuilder) {
        r.get("v1", "form", "human_input", ":token") { req in
            await handle(req) { try await humanInputFormDefinition(req) }
        }
        r.post("v1", "form", "human_input", ":token") { req in
            await handle(req) { try await submitHumanInputForm(req) }
        }
    }

    /// Dify's FormDefinition, in the order its API emits it, plus `expiration_time` as Unix seconds. [inputs] are the
    /// resolved inputs when the form's pause still has its pool (Dify's `resolve_form_inputs`), else the stored ones.
    static func formDefinitionJSON(_ f: StoredHumanInputForm, inputs: [JSONObject]? = nil) throws -> JSONValue {
        let formInputs: JSONValue = inputs.map { list in .array(list.map(JSONValue.object)) }
            ?? ((try? JSONValue.parse(f.inputs)) ?? .array([]))
        return .object([
            "form_content": .string(f.formContent),
            "inputs": formInputs,
            "user_actions": (try? JSONValue.parse(f.userActions)) ?? .array([]),
            "rendered_content": .string(f.renderedContent),
            "expiration_time": .int(f.expirationTime ?? 0),
            "default_values": f.defaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
            "node_title": f.nodeTitle.isEmpty ? .null : .string(f.nodeTitle),
            "display_in_ui": .bool(f.displayInUi),
        ])
    }

    /// The inputs a client should see: a variable-backed select's options resolved against the pause's own pool
    /// (`human_input_policy.resolve_variable_select_input_options`); nil when there is no pool to resolve against, in
    /// which case the stored definition is served as it is.
    static func resolvedInputs(_ form: StoredHumanInputForm, pauseSnapshot: String?) -> [JSONObject]? {
        guard let pauseSnapshot, let snapshot = try? GraphEngineSnapshot(data: Data(pauseSnapshot.utf8)),
              // The form's own execution, not the root: inside an iteration the item's pool holds its options.
              let pool = snapshot.variablePool(forExecution: form.executionId), let config = try? formConfig(form) else { return nil }
        return config.inputsResolved(pool: pool)
    }

    /// The engine's form config, rebuilt from what was persisted: the field types, their option sources and defaults and
    /// the action list must be the ones the node will enforce on resume, so nothing is reconstructed from guesses.
    static func formConfig(_ f: StoredHumanInputForm) throws -> HumanInputFormConfig {
        var node: JSONObject = [
            "type": .string("human-input"),
            "title": .string(f.nodeTitle),
            "form_content": .string(f.formContent),
            "inputs": try JSONValue.parse(f.inputs),
            "user_actions": try JSONValue.parse(f.userActions),
            "timeout_unit": .string("hour"),
        ]
        if let defaults = f.defaultValues, case .object(let values) = try JSONValue.parse(defaults) {
            node["default_value"] = .object(values)
        }
        return try HumanInputFormConfig(node)
    }

    private func humanInputToken(_ req: Request) throws -> String {
        guard let token = req.parameters.get("token"), !token.isEmpty, token.count <= 128 else {
            throw ServerError.notFound
        }
        return token
    }

    /// Dify's console access check (`_ensure_console_access`, `_ensure_console_recipient_type`): the token resolves only
    /// inside this workspace and only for a surface the console API serves. `human_input_policy.py` allows console **and
    /// backstage** there (only the service-API and openapi surfaces are narrowed to web apps), so both are accepted and a
    /// webapp token answers 404 exactly as a foreign one does. This server keeps one workspace per process (protocol 1.8),
    /// which is why the tenant half is structural rather than a column.
    private func consoleForm(_ req: Request) async throws -> StoredHumanInputForm {
        _ = try await authenticate(req)
        guard let form = try await store.humanInputForm(token: try humanInputToken(req)),
              Self.consoleSurfaceRecipients.contains(form.recipientType) else {
            throw ServerError.notFound
        }
        return form
    }

    /// The form a token names, on the surface the request belongs to. An **email link** carries a recipient token
    /// (`human_input_form_recipients`), which is served without an account — that is what a recipient of the mail has —
    /// while a console token still needs one (`consoleForm`). A console form's token without a session is therefore 404,
    /// not an anonymous form: the console boundary stays where Dify keeps it.
    private func formAndRecipient(_ req: Request, user: String? = nil) async throws -> (form: StoredHumanInputForm, recipient: StoredFormRecipient?) {
        if req.headers[.authorization] != nil {
            if let form = try await store.humanInputForm(token: try humanInputToken(req)), form.recipientType == .webapp,
               let runId = form.workflowRunId, let run = try await store.workflowRun(id: runId), run.endUserId != nil {
                let caller: PublicCaller
                do { caller = try await publicCaller(req, user:user) }
                catch ServerError.unauthorized(_) { throw ServerError.notFound }
                guard run.docId == caller.app.id, run.endUserId == caller.endUser.id, form.displayInUi else { throw ServerError.notFound }
                return (form, nil)
            }
            return (try await consoleForm(req), nil)
        }
        guard let found = try? await store.formRecipient(token: try humanInputToken(req)) else {
            throw ServerError.notFound
        }
        return (found.form, found.recipient)
    }

    /// `ALLOWED_RECIPIENT_TYPES_BY_SURFACE[HumanInputSurface.CONSOLE]`.
    static let consoleSurfaceRecipients: Set<HumanInputRecipient> = [.console, .backstage]

    /// Dify's `ensure_form_active`, in the order its submit path uses it: an answered or closed form answers 412 **before**
    /// the field-level validation runs, so a repeated submission with an unknown action (or an expired form with a value
    /// outside its options) is 412, not 400. The store repeats the check under the run's lock.
    static func ensureFormActive(_ form: StoredHumanInputForm, now: Date, globalTimeoutSeconds: Int) throws {
        switch form.status {
        case .submitted:
            throw ServerError.http(status: 412, code: "human_input_form_submitted", message: "this form has been submitted")
        case .expired, .timedOut:
            throw ServerError.http(status: 412, code: "human_input_form_expired", message: "this form has expired")
        case .waiting: break
        }
        if let expiration = form.expirationTime, Int64(now.timeIntervalSince1970) >= Int64(expiration) {
            throw ServerError.http(status: 412, code: "human_input_form_expired", message: "this form has expired")
        }
        if globalTimeoutSeconds > 0, now.timeIntervalSince(form.createdAt) >= Double(globalTimeoutSeconds) {
            throw ServerError.http(status: 412, code: "human_input_form_expired", message: "this form has expired")
        }
    }

    private func humanInputFormDefinition(_ req: Request) async throws -> Response {
        let (form, recipient) = try await formAndRecipient(req)
        // `get_form_definition_by_token_for_console` → `_ensure_not_submitted`.
        if form.status == .submitted {
            throw ServerError.http(status: 412, code: "human_input_form_submitted", message: "this form has been submitted")
        }
        // Dify reads the definition through `HumanInputService.resolve_form_inputs`: the pool comes from the run's open
        // pause, so an already resumed form keeps its unresolved definition (there is no pool any more).
        // A delivery test has no run and therefore no pool to resolve against: its definition is served as it was stored.
        let pause = if let runId = form.workflowRunId { (try? await store.openPauses(workflowRunId: runId))?.first } else { nil }
            as StoredWorkflowPause?
        // Dify's `_ensure_not_expired`: a link whose deadline has passed does not open the form. The deadline is the
        // node's own `expiration_time` (a delivery-test form expires with the definition that produced it).
        try Self.ensureNotExpired(form, now: Date())
        // The **anonymous recipient** surface, on top of the deadline: a form the run no longer waits on — answered, or
        // closed by a stop, a global expiry or the app's deletion — does not open either (Dify's web
        // `HumanInputFormApi.get` runs `ensure_form_active`, the same rule its submit path applies). The console surface
        // keeps the console's own rule (submitted is 412 above; the rest is the console's to check on submit), so this
        // branch is the recipient's only.
        if recipient != nil || form.recipientType == .webapp {
            try Self.ensureFormActive(form, now: Date(), globalTimeoutSeconds: config.humanInputGlobalTimeoutSeconds)
        }
        return try json(Self.formDefinitionJSON(form, inputs: Self.resolvedInputs(form, pauseSnapshot: pause?.snapshot)))
    }

    static func invalidFormData(_ message: String) -> ServerError {
        .http(status: 400, code: "invalid_form_data", message: message)
    }

    /// Dify's `_ensure_not_expired` (a link whose deadline passed answers 412 `human_input_form_expired`, on the read and
    /// on the submission alike). The deadline is the node's own `expiration_time` as the timeout scan compares it, so a
    /// form the scan is about to end cannot be answered in between.
    static func ensureNotExpired(_ form: StoredHumanInputForm, now: Date) throws {
        if let deadline = form.expirationTime, deadline > 0, now.timeIntervalSince1970 >= Double(deadline) {
            throw ServerError.http(status: 412, code: "human_input_form_expired", message: "this form has expired")
        }
    }

    private func submitHumanInputForm(_ req: Request) async throws -> Response {
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw Self.invalidFormData("the body must be a JSON object")
        }
        let (form0, recipient) = try await formAndRecipient(req, user: b["user"]?.string)
        let publicIdentity: PublicCaller? = form0.recipientType == .webapp && form0.workflowRunId != nil
            ? try await publicCaller(req, user: b["user"]?.string) : nil
        let p: Principal?
        if let publicIdentity { p = publicIdentity.executor }
        else if req.headers[.authorization] != nil { p = try await authenticate(req) }
        else { p = nil }
        let token = form0.token
        guard case .object(let values)? = b["inputs"] else {
            throw Self.invalidFormData("inputs must be an object")
        }
        guard case .string(let action)? = b["action"], !action.isEmpty else {
            throw Self.invalidFormData("action is required")
        }
        let form = form0
        var normalizedValues = values
        // `submit_form_by_token`: `ensure_form_active` first, then the field validation.
        try Self.ensureFormActive(form, now: Date(), globalTimeoutSeconds: config.humanInputGlobalTimeoutSeconds)
        // Dify validates against the form's own definition before the row is touched, so an invalid value answers 400
        // and leaves the form waiting.
        do {
            let formConfig = try Self.formConfig(form)
            // Anonymous recipient upload scopes belong to email delivery; never let a token borrow console files.
            if formConfig.requiresFileStorage && p == nil { throw RuntimeFileError("File inputs require an authenticated console account") }
            normalizedValues = try await formConfig.normalizedFiles(values, using: p.map { ServerWorkflowFiles(routes: self, userId: $0.id, endUserId: publicIdentity?.endUser.id) })
            try formConfig.validateSubmission(action: action, values: normalizedValues)
        } catch {
            throw Self.invalidFormData("\(error)")
        }

        let inputsText = String(decoding: try WireJSON.encode(JSONValue.object(normalizedValues)), as: UTF8.self)
        // The store re-checks the deadlines after taking the run's lock; the config value is the global one.
        // Who answered: the account, or the member a recipient row names; an external recipient has none.
        let answeredBy = p?.id ?? recipient?.referenceId ?? ""
        switch try await store.submitHumanInputForm(token: token, inputs: inputsText, action: action, userId: answeredBy,
                                                    globalTimeoutSeconds: config.humanInputGlobalTimeoutSeconds) {
        case .accepted(let answered):
            if let recipient { try? await store.markFormRecipientUsed(token: recipient.token, at: Date()) }
            // Dify's `enqueue_resume`: the answer asks for a resume; it runs in the background so the caller is answered
            // immediately, and the claim inside makes a second answer harmless.
            // A delivery test belongs to no run: its answer proves the form and resumes nothing.
            if let runId = answered.workflowRunId {
                let routes = self
                let docId = answered.docId
                Task.detached { await routes.resumeRun(appId: docId, runId: runId) }
            }
            struct Empty: Encodable {}
            return try json(Empty())
        case .alreadySubmitted:
            throw ServerError.http(status: 412, code: "human_input_form_submitted", message: "this form has been submitted")
        case .expired:
            throw ServerError.http(status: 412, code: "human_input_form_expired", message: "this form has expired")
        case .notFound:
            throw ServerError.notFound
        }
    }
}
