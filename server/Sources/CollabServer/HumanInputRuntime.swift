import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Synchronization

/// The forms one run has decided to create, in the order the engine paused on them. They are **not** durable yet: the run
/// persists them together with its pause, and only then publishes `human_input_required` / `workflow_paused`. A form that
/// a node asked for in a run that then fails leaves no token behind.
public final class PendingHumanInputForms: Sendable {
    private let forms = Mutex<[String: StoredHumanInputForm]>([:])

    func add(_ form: StoredHumanInputForm) {
        forms.withLock { $0[form.id] = form }
    }

    /// The forms behind these pause sessions (the engine's `session_id` is the form id), in the reasons' order.
    func take(_ sessionIds: [String]) -> [StoredHumanInputForm] {
        let all = forms.withLock { $0 }
        return sessionIds.compactMap { all[$0] }
    }
}

/// The server's `HumanInputRuntime` (protocol 1.16): Dify's form service on the engine's side of the decision.
///
/// On a pause it creates the form (id, token, deadline, rendered content, resolved defaults) and hands the node a session
/// id; the run persists it with the pause. On resume the node runs again with the same execution id, so a form that is
/// already answered is returned as a completion and one that timed out as the `__timeout` branch — the engine then carries
/// on through the normal path, and no node is re-executed on the way.
public struct ServerHumanInputRuntime: HumanInputRuntime {
    public var store: PostgresStore
    public var workflowRunId: String
    public var docId: String
    public var userId: String
    public var pending: PendingHumanInputForms
    public var startedAt: Date

    public init(store: PostgresStore, workflowRunId: String, docId: String, userId: String, pending: PendingHumanInputForms,
                startedAt: Date = Date()) {
        self.store = store
        self.workflowRunId = workflowRunId
        self.docId = docId
        self.userId = userId
        self.pending = pending
        self.startedAt = startedAt
    }

    public func decide(form: HumanInputFormConfig, context: HumanInputContext) async throws -> HumanInputDecision {
        // A container round pauses again under its own execution id (`HumanInputContext.executionId`), so two rounds of
        // one node are two forms, which is what the store's (run, execution) key means.
        let executionId = context.executionId ?? context.nodeId
        if let existing = try await store.humanInputForm(workflowRunId: workflowRunId, executionId: executionId) {
            switch existing.status {
            case .submitted:
                let values = (try? JSONValue.parse(existing.submittedInputs ?? "{}"))?.object ?? [:]
                let result = try form.completion(action: existing.submittedAction ?? "", values: values,
                                                renderedContent: existing.renderedContent)
                return .completed(result)
            case .timedOut:
                return .expired(form.timeoutResult(renderedContent: existing.renderedContent))
            case .expired:
                // The global deadline ended the run; the engine must not continue through the timeout branch here.
                throw NodeError("HumanInputExpired", "the form expired and the run was stopped")
            case .waiting:
                // A pause that was decided before (a re-entered node) keeps its form and token.
                pending.add(existing)
                return .pause(sessionId: existing.id)
            }
        }

        let now = Date()
        let rendered = form.renderedContent(pool: context.pool)
        let defaults = form.resolvedDefaults(pool: context.pool)
        let id = UUID().uuidString.lowercased()
        let created = StoredHumanInputForm(
            id: id, workflowRunId: workflowRunId, generation: 0, executionId: executionId, docId: docId, nodeId: context.nodeId,
            nodeTitle: context.nodeTitle, token: UUID().uuidString.lowercased(), formContent: form.content,
            inputs: try Self.jsonText(form.inputs), userActions: try Self.jsonText(form.actions), renderedContent: rendered,
            defaultValues: Self.jsonTextObject(defaults), resolvedDefaultValues: Self.jsonTextObject(defaults),
            actions: try Self.jsonText(form.actions), displayInUi: defaults["display_in_ui"]?.bool ?? true,
            expirationTime: Int(form.expirationTime(from: startedAt).timeIntervalSince1970), createdAt: now)
        pending.add(created)
        return .pause(sessionId: id)
    }

    static func jsonText(_ values: [JSONObject]) throws -> String {
        String(decoding: try WireJSON.encode(JSONValue.array(values.map { .object($0) })), as: UTF8.self)
    }

    static func jsonTextObject(_ values: JSONObject) -> String? {
        (try? WireJSON.encode(JSONValue.object(values))).map { String(decoding: $0, as: UTF8.self) }
    }
}
