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
    /// Dify's `node_runtime._display_in_ui`: under the debugger a form is always shown; elsewhere the enabled Web App
    /// delivery decides (a published run additionally requires the site to be enabled, which M5 wires).
    public var isDebugger: Bool
    /// The answers **this** resume claimed (`claimResume`'s decisions), by execution id. A resume decides from this fixed
    /// view and nothing else: a submission that arrives after the claim belongs to the next pause, so the node re-pauses
    /// instead of completing on an answer the claim did not take.
    public var decisions: [String: StoredHumanInputForm]

    public init(store: PostgresStore, workflowRunId: String, docId: String, userId: String, pending: PendingHumanInputForms,
                decisions: [String: StoredHumanInputForm] = [:], isDebugger: Bool = true) {
        self.store = store
        self.workflowRunId = workflowRunId
        self.docId = docId
        self.userId = userId
        self.pending = pending
        self.decisions = decisions
        self.isDebugger = isDebugger
    }

    public func decide(form: HumanInputFormConfig, context: HumanInputContext) async throws -> HumanInputDecision {
        // A container round pauses again under its own execution id (`HumanInputContext.executionId`), so two rounds of
        // one node are two forms, which is what the store's (run, execution) key means.
        let executionId = context.executionId ?? context.nodeId
        // The claim's decisions are the whole view of this resume.
        if let decided = decisions[executionId] {
            switch decided.status {
            case .submitted:
                let values = (try? JSONValue.parse(decided.submittedInputs ?? "{}"))?.object ?? [:]
                return .completed(try form.completion(action: decided.submittedAction ?? "", values: values,
                                                      renderedContent: decided.renderedContent))
            case .timedOut:
                return .expired(form.timeoutResult(renderedContent: decided.renderedContent))
            case .expired:
                // The global deadline ended the run; the engine must not continue through the timeout branch here.
                throw NodeError("HumanInputExpired", "the form expired and the run was stopped")
            case .waiting:
                pending.add(decided)
                return .pause(sessionId: decided.id)
            }
        }
        // Not this resume's decision: a form of this execution that is still waiting (a re-entered node) keeps its id and
        // token; one answered after the claim leaves the node paused, so the next pause carries that answer.
        if let existing = try await store.humanInputForm(workflowRunId: workflowRunId, executionId: executionId) {
            pending.add(existing)
            return .pause(sessionId: existing.id)
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
            actions: try Self.jsonText(form.actions),
            displayInUi: Self.displayInUi(isDebugger: isDebugger, webappDeliveryEnabled: form.webappDeliveryEnabled),
            // The deadline counts from when this form is created, not from when the adapter was built.
            expirationTime: Int(form.expirationTime(from: now).timeIntervalSince1970), createdAt: now)
        pending.add(created)
        return .pause(sessionId: id)
    }

    /// `node_runtime._display_in_ui` (`human_input_adapter.is_human_input_webapp_enabled`): the debugger always shows the
    /// form; any other invocation source shows it only when an enabled **webapp** delivery exists. The node's bare
    /// `display_in_ui` boolean is not what decides this.
    static func displayInUi(isDebugger: Bool, webappDeliveryEnabled: Bool) -> Bool {
        isDebugger || webappDeliveryEnabled
    }

    static func jsonText(_ values: [JSONObject]) throws -> String {
        String(decoding: try WireJSON.encode(JSONValue.array(values.map { .object($0) })), as: UTF8.self)
    }

    static func jsonTextObject(_ values: JSONObject) -> String? {
        (try? WireJSON.encode(JSONValue.object(values))).map { String(decoding: $0, as: UTF8.self) }
    }
}
