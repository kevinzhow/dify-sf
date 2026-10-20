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

    /// Dify's FormDefinition, in the order its API emits it, plus `expiration_time` as Unix seconds.
    static func formDefinitionJSON(_ f: StoredHumanInputForm) throws -> JSONValue {
        .object([
            "form_content": .string(f.formContent),
            "inputs": (try? JSONValue.parse(f.inputs)) ?? .array([]),
            "user_actions": (try? JSONValue.parse(f.userActions)) ?? .array([]),
            "rendered_content": .string(f.renderedContent),
            "expiration_time": .int(f.expirationTime ?? 0),
            "default_values": f.defaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
            "node_title": f.nodeTitle.isEmpty ? .null : .string(f.nodeTitle),
            "display_in_ui": .bool(f.displayInUi),
        ])
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
    /// inside this workspace, and only for a form delivered to the console. This server keeps one workspace per process
    /// (protocol 1.8), so the tenant half is structural; the recipient half is enforced here, and a webapp or backstage
    /// token answers 404 exactly as a foreign one does.
    private func consoleForm(_ req: Request) async throws -> StoredHumanInputForm {
        _ = try await authenticate(req)
        guard let form = try await store.humanInputForm(token: try humanInputToken(req)),
              form.recipientType == .console else {
            throw ServerError.notFound
        }
        return form
    }

    private func humanInputFormDefinition(_ req: Request) async throws -> Response {
        let form = try await consoleForm(req)
        return try json(Self.formDefinitionJSON(form))
    }

    static func invalidFormData(_ message: String) -> ServerError {
        .http(status: 400, code: "invalid_form_data", message: message)
    }

    private func submitHumanInputForm(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        let token = try humanInputToken(req)
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw Self.invalidFormData("the body must be a JSON object")
        }
        guard case .object(let values)? = b["inputs"] else {
            throw Self.invalidFormData("inputs must be an object")
        }
        guard case .string(let action)? = b["action"], !action.isEmpty else {
            throw Self.invalidFormData("action is required")
        }
        let form = try await consoleForm(req)
        // Dify validates against the form's own definition before the row is touched (`submit_form_by_token`), so an
        // invalid value answers 400 and leaves the form waiting.
        do {
            try Self.formConfig(form).validateSubmission(action: action, values: values)
        } catch {
            throw Self.invalidFormData("\(error)")
        }

        let inputsText = String(decoding: try WireJSON.encode(JSONValue.object(values)), as: UTF8.self)
        // The store re-checks the deadlines after taking the run's lock; the config value is the global one.
        switch try await store.submitHumanInputForm(token: token, inputs: inputsText, action: action, userId: p.id,
                                                    globalTimeoutSeconds: config.humanInputGlobalTimeoutSeconds) {
        case .accepted:
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
