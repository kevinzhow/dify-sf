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
            "form_content": .string(form.formContent),
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

    func humanInputRequired(_ form: StoredHumanInputForm) -> JSONValue {
        envelope("human_input_required", [
            "form_id": .string(form.id),
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            "form_content": .string(form.formContent),
            "inputs": (try? JSONValue.parse(form.inputs)) ?? .array([]),
            "actions": (try? JSONValue.parse(form.actions)) ?? .array([]),
            "display_in_ui": .bool(form.displayInUi),
            "form_token": .string(form.token),
            "approval_channels": .array([]),
            "resolved_default_values": form.resolvedDefaultValues.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
            "expiration_time": form.expirationTime.map { .int($0) } ?? .null,
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
        let pausedNodes = forms.map { JSONValue.string($0.nodeId) }
        return envelope("workflow_paused", [
            "workflow_run_id": .string(runId),
            "paused_nodes": .array(pausedNodes),
            // Dify's public reasons carry the human-input type and the form, not the engine's internal `hitl_required`
            // session id: `human_input_policy.enrich_human_input_pause_reasons` adds the token, channels and deadline.
            "reasons": .array(forms.map { Self.reasonJSON($0) }),
            "outputs": .object(stats.outputs),
            "status": "paused",
            "created_at": .int(Int(at.timeIntervalSince1970)),
            "elapsed_time": .double(at.timeIntervalSince(startedAt)),
            "total_tokens": .int(stats.totalTokens),
            "total_steps": .int(stats.totalSteps),
        ])
    }
}
