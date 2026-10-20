import CollabCore
import CollabRuntime
import CollabStore
import Foundation

/// The two frames a pause publishes, and only after the pause and its forms are durable
/// (`WorkflowResponseConverter`'s `human_input_required` and `workflow_paused`).
extension RunStreamEncoder {
    /// Dify's `HumanInputRequired` reason, as `human_input_policy` enriches it for the stream.
    static func reasonJSON(_ form: StoredHumanInputForm, inputs: [JSONObject]? = nil) -> JSONValue {
        let formInputs: JSONValue = inputs.map { list in .array(list.map(JSONValue.object)) }
            ?? ((try? JSONValue.parse(form.inputs)) ?? .array([]))
        return .object([
            "TYPE": .string("human_input_required"),
            "form_id": .string(form.id),
            // Dify's `_enrich_hitl_required` sends the form's **rendered** content (the `$output` placeholders stay); the
            // raw template is what the definition API's `form_content` keeps.
            "form_content": .string(form.renderedContent),
            "inputs": formInputs,
            "actions": (try? JSONValue.parse(form.actions)) ?? .array([]),
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            "resolved_default_values": form.resolvedDefaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
            "form_token": .string(form.token),
            "approval_channels": .array([]),
            "expiration_time": form.expirationTime.map { .int($0) } ?? .null,
        ])
    }

    /// The `human_input_required` data, shared by the live stream and the reconnect snapshot so the two cannot drift.
    /// [inputs] overrides the stored definition's inputs: a variable-backed select's options are resolved against the
    /// pause's variable pool (`resolve_variable_select_input_options`), so the client receives concrete options.
    static func humanInputRequiredData(_ form: StoredHumanInputForm, inputs: [JSONObject]? = nil) -> JSONValue {
        let formInputs: JSONValue = inputs.map { list in .array(list.map(JSONValue.object)) }
            ?? ((try? JSONValue.parse(form.inputs)) ?? .array([]))
        return .object([
            "form_id": .string(form.id),
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            // Dify's `_enrich_hitl_required` sends the form's **rendered** content (the `$output` placeholders stay); the
            // raw template is what the definition API's `form_content` keeps.
            "form_content": .string(form.renderedContent),
            "inputs": formInputs,
            "actions": (try? JSONValue.parse(form.actions)) ?? .array([]),
            "display_in_ui": .bool(form.displayInUi),
            "form_token": .string(form.token),
            "approval_channels": .array([]),
            "resolved_default_values": form.resolvedDefaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
            "expiration_time": form.expirationTime.map { .int($0) } ?? .null,
        ])
    }

    func humanInputRequired(_ form: StoredHumanInputForm, inputs: [JSONObject]? = nil) -> JSONValue {
        envelope("human_input_required", Self.humanInputRequiredData(form, inputs: inputs))
    }

    /// The `workflow_paused` data, shared by the live stream and the snapshot.
    /// `created_at` is the **round's** start and `elapsed_time` the round's time so far, as Dify's
    /// `workflow_pause_to_stream_response` (`started_at` = the converter's, i.e. this round's `workflow_started`).
    static func workflowPausedData(runId: String, forms: [StoredHumanInputForm], stats: GraphRunStats, createdAt: Date,
                                   elapsed: Double, inputs: [[JSONObject]?] = []) -> JSONValue {
        .object([
            "workflow_run_id": .string(runId),
            "paused_nodes": .array(forms.map { JSONValue.string($0.nodeId) }),
            "outputs": .object(stats.outputs),
            "reasons": .array(forms.enumerated().map { i, f in reasonJSON(f, inputs: i < inputs.count ? inputs[i] : nil) }),
            "status": "paused",
            "created_at": .int(Int(createdAt.timeIntervalSince1970)),
            "elapsed_time": .double(elapsed),
            "total_tokens": .int(stats.totalTokens),
            "total_steps": .int(stats.totalSteps),
        ])
    }

    /// `human_input_form_filled`: the answer the resume took (Dify's payload keeps the rendered content and the action's
    /// id, title and submitted data).
    func humanInputFormFilled(nodeId: String, nodeTitle: String, renderedContent: String, actionId: String,
                              actionText: String, submittedData: JSONObject) -> JSONValue {
        envelope("human_input_form_filled", [
            "node_id": .string(nodeId),
            "node_title": .string(nodeTitle),
            "rendered_content": .string(renderedContent),
            "action_id": .string(actionId),
            "action_text": .string(actionText),
            "submitted_data": .object(submittedData),
        ])
    }

    /// `human_input_form_timeout`: the node's own deadline ended its form; the run resumes through `__timeout`, so this is
    /// not a filled answer.
    func humanInputFormTimeout(_ form: StoredHumanInputForm) -> JSONValue {
        envelope("human_input_form_timeout", [
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            "expiration_time": form.expirationTime.map { .int($0) } ?? .null,
        ])
    }

    func workflowPaused(_ forms: [StoredHumanInputForm], reasons: [PauseReason], stats: GraphRunStats, at: Date,
                        inputs: [[JSONObject]?] = []) -> JSONValue {
        envelope("workflow_paused", Self.workflowPausedData(runId: runId, forms: forms, stats: stats, createdAt: roundStartedAt,
                                                           elapsed: at.timeIntervalSince(roundStartedAt), inputs: inputs))
    }
}
