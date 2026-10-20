import CollabCore
import CollabRuntime
import CollabStore
import Foundation

/// The two frames a pause publishes, and only after the pause and its forms are durable
/// (`WorkflowResponseConverter`'s `human_input_required` and `workflow_paused`).
extension RunStreamEncoder {
    /// Dify's `HumanInputRequired` reason, as `human_input_policy` enriches it for the stream.
    static func reasonJSON(_ form: StoredHumanInputForm) -> JSONValue {
        .object([
            "TYPE": .string("human_input_required"),
            "form_id": .string(form.id),
            // Dify's `_enrich_hitl_required` sends the form's **rendered** content (the `$output` placeholders stay); the
            // raw template is what the definition API's `form_content` keeps.
            "form_content": .string(form.renderedContent),
            "inputs": (try? JSONValue.parse(form.inputs)) ?? .array([]),
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
    static func humanInputRequiredData(_ form: StoredHumanInputForm) -> JSONValue {
        .object([
            "form_id": .string(form.id),
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            // Dify's `_enrich_hitl_required` sends the form's **rendered** content (the `$output` placeholders stay); the
            // raw template is what the definition API's `form_content` keeps.
            "form_content": .string(form.renderedContent),
            "inputs": (try? JSONValue.parse(form.inputs)) ?? .array([]),
            "actions": (try? JSONValue.parse(form.actions)) ?? .array([]),
            "display_in_ui": .bool(form.displayInUi),
            "form_token": .string(form.token),
            "approval_channels": .array([]),
            "resolved_default_values": form.resolvedDefaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
            "expiration_time": form.expirationTime.map { .int($0) } ?? .null,
        ])
    }

    func humanInputRequired(_ form: StoredHumanInputForm) -> JSONValue {
        envelope("human_input_required", Self.humanInputRequiredData(form))
    }

    /// The `workflow_paused` data, shared by the live stream and the snapshot.
    static func workflowPausedData(runId: String, forms: [StoredHumanInputForm], stats: GraphRunStats, at: Date,
                                   elapsed: Double) -> JSONValue {
        .object([
            "workflow_run_id": .string(runId),
            "paused_nodes": .array(forms.map { JSONValue.string($0.nodeId) }),
            "outputs": .object(stats.outputs),
            "reasons": .array(forms.map { reasonJSON($0) }),
            "status": "paused",
            "created_at": .int(Int(at.timeIntervalSince1970)),
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

    func workflowPaused(_ forms: [StoredHumanInputForm], reasons: [PauseReason], stats: GraphRunStats, at: Date) -> JSONValue {
        envelope("workflow_paused", Self.workflowPausedData(runId: runId, forms: forms, stats: stats, at: at,
                                                           elapsed: at.timeIntervalSince(startedAt)))
    }
}
