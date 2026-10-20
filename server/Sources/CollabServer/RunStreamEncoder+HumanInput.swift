import CollabCore
import CollabRuntime
import CollabStore
import Foundation

/// The two frames a pause publishes, and only after the pause and its forms are durable
/// (`WorkflowResponseConverter`'s `human_input_required` and `workflow_paused`).
extension RunStreamEncoder {
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
    func humanInputFormFilled(_ form: StoredHumanInputForm) -> JSONValue {
        let actions = (try? JSONValue.parse(form.actions))?.array ?? []
        let action = actions.first { $0["id"]?.string == form.submittedAction }
        return envelope("human_input_form_filled", [
            "form_id": .string(form.id),
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            "action_id": form.submittedAction.map(JSONValue.string) ?? .null,
            "action_text": action?["title"] ?? .null,
            "rendered_content": .string(form.renderedContent),
            "submitted_data": form.submittedInputs.flatMap { try? JSONValue.parse($0) } ?? .object([:]),
        ])
    }

    /// `human_input_form_timeout`: the node's own deadline ended its form; the run resumes through `__timeout`, so this is
    /// not a filled answer.
    func humanInputFormTimeout(_ form: StoredHumanInputForm) -> JSONValue {
        envelope("human_input_form_timeout", [
            "form_id": .string(form.id),
            "node_id": .string(form.nodeId),
            "node_title": .string(form.nodeTitle),
            "rendered_content": .string(form.renderedContent),
        ])
    }

    func workflowPaused(_ forms: [StoredHumanInputForm], reasons: [PauseReason], stats: GraphRunStats, at: Date) -> JSONValue {
        let pausedNodes = forms.map { form -> JSONValue in
            .object(["node_id": .string(form.nodeId), "node_title": .string(form.nodeTitle), "form_id": .string(form.id)])
        }
        return envelope("workflow_paused", [
            "workflow_run_id": .string(runId),
            "paused_nodes": .array(pausedNodes),
            // Dify's public reasons carry the human-input type, not the engine's internal `hitl_required`/session id.
            "reasons": .array(reasons.map { reason -> JSONValue in
                if case .hitlRequired(_, let nodeId, _) = reason { return .object(["TYPE": .string("human_input_required"), "node_id": .string(nodeId)]) }
                return reason.json
            }),
            "outputs": .object(stats.outputs),
            "status": "paused",
            "created_at": .double(at.timeIntervalSince1970),
            "elapsed_time": .double(at.timeIntervalSince(startedAt)),
            "total_tokens": .int(stats.totalTokens),
            "total_steps": .int(stats.totalSteps),
        ])
    }
}
