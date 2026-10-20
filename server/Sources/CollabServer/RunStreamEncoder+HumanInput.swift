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
