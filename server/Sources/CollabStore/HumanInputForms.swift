import Foundation
import PostgresNIO

/// A paused run waiting for human input (protocol 1.16). The snapshot is the exact JSON text the engine produced, so a
/// restart resumes from the same bytes the pause wrote (`graphon` encoding: key order, number kinds, segment types).
public struct StoredWorkflowPause: Sendable, Equatable {
    public var workflowRunId: String
    /// The engine's execution identity of the paused node. A loop's second round through the same node is another
    /// execution, which is why this — not the node id — keys the pause and its form.
    public var executionId: String
    public var docId: String
    public var nodeId: String
    public var snapshot: String
    public var totalTokens: Int
    public var totalSteps: Int
    public var elapsedTime: Double
    public var createdAt: Date
    public var resumedAt: Date?
    /// A submission that arrived before this row existed (a form persisted first): the pause is already answerable.
    public var resumeRequested: Bool

    public init(workflowRunId: String, executionId: String, docId: String, nodeId: String, snapshot: String,
                totalTokens: Int = 0, totalSteps: Int = 0, elapsedTime: Double = 0, createdAt: Date, resumedAt: Date? = nil,
                resumeRequested: Bool = false) {
        self.workflowRunId = workflowRunId
        self.executionId = executionId
        self.docId = docId
        self.nodeId = nodeId
        self.snapshot = snapshot
        self.totalTokens = totalTokens
        self.totalSteps = totalSteps
        self.elapsedTime = elapsedTime
        self.createdAt = createdAt
        self.resumedAt = resumedAt
        self.resumeRequested = resumeRequested
    }
}

public enum HumanInputFormStatus: String, Sendable {
    case waiting
    case submitted
    case expired
}

/// One human-input form (protocol 1.16, Dify's FormDefinition + its delivery state). Every JSON member is the exact text
/// the runtime rendered, never re-encoded here: the client compares field order and number kinds with Dify's.
public struct StoredHumanInputForm: Sendable, Equatable {
    public var id: String
    public var workflowRunId: String
    public var executionId: String
    public var docId: String
    public var nodeId: String
    public var nodeTitle: String
    public var token: String
    public var formContent: String
    public var inputs: String
    public var userActions: String
    public var renderedContent: String
    public var defaultValues: String?
    public var resolvedDefaultValues: String?
    public var actions: String
    public var displayInUi: Bool
    /// Dify's `expiration_time`: Unix seconds, nil when the form does not expire.
    public var expirationTime: Int?
    public var status: HumanInputFormStatus
    public var submittedInputs: String?
    public var submittedAction: String?
    public var submittedBy: String?
    public var submittedAt: Date?
    public var consumedAt: Date?
    public var createdAt: Date

    public init(id: String, workflowRunId: String, executionId: String, docId: String, nodeId: String, nodeTitle: String,
                token: String, formContent: String, inputs: String, userActions: String, renderedContent: String,
                defaultValues: String? = nil, resolvedDefaultValues: String? = nil, actions: String, displayInUi: Bool,
                expirationTime: Int? = nil, status: HumanInputFormStatus = .waiting, submittedInputs: String? = nil,
                submittedAction: String? = nil, submittedBy: String? = nil, submittedAt: Date? = nil, consumedAt: Date? = nil,
                createdAt: Date) {
        self.id = id
        self.workflowRunId = workflowRunId
        self.executionId = executionId
        self.docId = docId
        self.nodeId = nodeId
        self.nodeTitle = nodeTitle
        self.token = token
        self.formContent = formContent
        self.inputs = inputs
        self.userActions = userActions
        self.renderedContent = renderedContent
        self.defaultValues = defaultValues
        self.resolvedDefaultValues = resolvedDefaultValues
        self.actions = actions
        self.displayInUi = displayInUi
        self.expirationTime = expirationTime
        self.status = status
        self.submittedInputs = submittedInputs
        self.submittedAction = submittedAction
        self.submittedBy = submittedBy
        self.submittedAt = submittedAt
        self.consumedAt = consumedAt
        self.createdAt = createdAt
    }
}

/// What a `POST /form/human_input/{token}` did. The route maps these to Dify's answers: `accepted` → `{}`,
/// `alreadySubmitted` → 412 `human_input_form_submitted`, `expired` → 412 `human_input_form_expired`,
/// `notFound` → 404.
public enum HumanInputSubmitOutcome: Sendable, Equatable {
    case accepted(StoredHumanInputForm)
    case alreadySubmitted
    case expired
    case notFound
}

extension PostgresStore {
    static let formColumns = """
        id, workflow_run_id, execution_id, doc_id, node_id, node_title, token, form_content, inputs, user_actions,
        rendered_content, default_values, resolved_default_values, actions, display_in_ui, expiration_time, status,
        submitted_inputs, submitted_action, submitted_by, submitted_at, consumed_at, created_at
        """

    static func decodeForm(_ row: PostgresRow) throws -> StoredHumanInputForm {
        let r = row.makeRandomAccess()
        return StoredHumanInputForm(
            id: try r[0].decode(String.self), workflowRunId: try r[1].decode(String.self),
            executionId: try r[2].decode(String.self), docId: try r[3].decode(String.self),
            nodeId: try r[4].decode(String.self), nodeTitle: try r[5].decode(String.self),
            token: try r[6].decode(String.self), formContent: try r[7].decode(String.self),
            inputs: try r[8].decode(String.self), userActions: try r[9].decode(String.self),
            renderedContent: try r[10].decode(String.self), defaultValues: try r[11].decode(String?.self),
            resolvedDefaultValues: try r[12].decode(String?.self), actions: try r[13].decode(String.self),
            displayInUi: try r[14].decode(Bool.self),
            expirationTime: try r[15].decode(Int64?.self).map { Int($0) },
            status: HumanInputFormStatus(rawValue: try r[16].decode(String.self)) ?? .waiting,
            submittedInputs: try r[17].decode(String?.self), submittedAction: try r[18].decode(String?.self),
            submittedBy: try r[19].decode(String?.self), submittedAt: try r[20].decode(Date?.self),
            consumedAt: try r[21].decode(Date?.self), createdAt: try r[22].decode(Date.self))
    }

    /// Writes the pause and its forms in one transaction: the run may only show a pause, and a form may only be
    /// answerable, once both are durable. A caller that throws here leaves neither row behind, so the run resumes
    /// instead of waiting on a form nobody can answer.
    public func createPause(_ pause: StoredWorkflowPause, forms: [StoredHumanInputForm]) async throws {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                // A form may already be persisted and answered (the other ordering): that submission is the resume
                // request, and it is folded in here rather than lost. `EXISTS` inside this transaction sees it.
                _ = try await c.query("""
                    INSERT INTO workflow_pauses (workflow_run_id, execution_id, doc_id, node_id, snapshot, total_tokens,
                        total_steps, elapsed_time, created_at, resumed_at, resume_requested)
                    VALUES (\(pause.workflowRunId), \(pause.executionId), \(pause.docId), \(pause.nodeId), \(pause.snapshot),
                        \(pause.totalTokens), \(pause.totalSteps), \(pause.elapsedTime), \(pause.createdAt), \(pause.resumedAt),
                        \(pause.resumeRequested) OR EXISTS (
                            SELECT 1 FROM human_input_forms f
                            WHERE f.workflow_run_id = \(pause.workflowRunId) AND f.execution_id = \(pause.executionId)
                              AND f.status = 'submitted'))
                    """, logger: self.logger)
                for f in forms {
                    _ = try await c.query("""
                        INSERT INTO human_input_forms (id, workflow_run_id, execution_id, doc_id, node_id, node_title, token,
                            form_content, inputs, user_actions, rendered_content, default_values, resolved_default_values, actions,
                            display_in_ui, expiration_time, status, created_at)
                        VALUES (\(f.id), \(f.workflowRunId), \(f.executionId), \(f.docId), \(f.nodeId), \(f.nodeTitle), \(f.token),
                            \(f.formContent), \(f.inputs), \(f.userActions), \(f.renderedContent), \(f.defaultValues),
                            \(f.resolvedDefaultValues), \(f.actions), \(f.displayInUi),
                            \(f.expirationTime.map { Int64($0) }), \(f.status.rawValue), \(f.createdAt))
                        """, logger: self.logger)
                }
            }
        }
    }

    /// Writes one form on its own: the ordering where the form is durable before the pause (the engine may still be
    /// draining). A submission that arrives in between becomes the pause's `resume_requested` when `createPause` runs.
    /// Idempotent for the same (run, execution): a retried insert leaves the existing row.
    public func insertHumanInputForm(_ f: StoredHumanInputForm) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO human_input_forms (id, workflow_run_id, execution_id, doc_id, node_id, node_title, token,
                    form_content, inputs, user_actions, rendered_content, default_values, resolved_default_values, actions,
                    display_in_ui, expiration_time, status, created_at)
                VALUES (\(f.id), \(f.workflowRunId), \(f.executionId), \(f.docId), \(f.nodeId), \(f.nodeTitle), \(f.token),
                    \(f.formContent), \(f.inputs), \(f.userActions), \(f.renderedContent), \(f.defaultValues),
                    \(f.resolvedDefaultValues), \(f.actions), \(f.displayInUi), \(f.expirationTime.map { Int64($0) }),
                    \(f.status.rawValue), \(f.createdAt))
                ON CONFLICT (workflow_run_id, execution_id) DO NOTHING
                """, logger: self.logger)
        }
    }

    /// The pauses of a run that were not resumed yet, oldest first: what a restarted server re-attaches to.
    public func openPauses(workflowRunId: String) async throws -> [StoredWorkflowPause] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT workflow_run_id, execution_id, doc_id, node_id, snapshot, total_tokens, total_steps, elapsed_time,
                    created_at, resumed_at, resume_requested
                FROM workflow_pauses WHERE workflow_run_id = \(workflowRunId) AND resumed_at IS NULL
                ORDER BY created_at
                """, logger: self.logger)
            var out: [StoredWorkflowPause] = []
            for try await row in rows {
                let r = row.makeRandomAccess()
                out.append(StoredWorkflowPause(
                    workflowRunId: try r[0].decode(String.self), executionId: try r[1].decode(String.self),
                    docId: try r[2].decode(String.self), nodeId: try r[3].decode(String.self),
                    snapshot: try r[4].decode(String.self), totalTokens: Int(try r[5].decode(Int64.self)),
                    totalSteps: Int(try r[6].decode(Int32.self)), elapsedTime: try r[7].decode(Double.self),
                    createdAt: try r[8].decode(Date.self), resumedAt: try r[9].decode(Date?.self),
                    resumeRequested: try r[10].decode(Bool.self)))
            }
            return out
        }
    }

    /// One pause by its run and execution (the pair the resume path knows).
    public func pause(workflowRunId: String, executionId: String) async throws -> StoredWorkflowPause? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT workflow_run_id, execution_id, doc_id, node_id, snapshot, total_tokens, total_steps, elapsed_time,
                    created_at, resumed_at, resume_requested
                FROM workflow_pauses WHERE workflow_run_id = \(workflowRunId) AND execution_id = \(executionId)
                """, logger: self.logger)
            for try await row in rows {
                let r = row.makeRandomAccess()
                return StoredWorkflowPause(
                    workflowRunId: try r[0].decode(String.self), executionId: try r[1].decode(String.self),
                    docId: try r[2].decode(String.self), nodeId: try r[3].decode(String.self),
                    snapshot: try r[4].decode(String.self), totalTokens: Int(try r[5].decode(Int64.self)),
                    totalSteps: Int(try r[6].decode(Int32.self)), elapsedTime: try r[7].decode(Double.self),
                    createdAt: try r[8].decode(Date.self), resumedAt: try r[9].decode(Date?.self),
                    resumeRequested: try r[10].decode(Bool.self))
            }
            return nil
        }
    }

    /// Claims a pause for resumption: exactly one caller wins (two submissions arriving together must not start two
    /// engines). True when this call claimed it.
    public func claimPause(workflowRunId: String, executionId: String, at: Date) async throws -> Bool {
        try await bounded {
            let rows = try await self.client.query("""
                UPDATE workflow_pauses SET resumed_at = \(at)
                WHERE workflow_run_id = \(workflowRunId) AND execution_id = \(executionId) AND resumed_at IS NULL
                RETURNING execution_id
                """, logger: self.logger)
            for try await _ in rows { return true }
            return false
        }
    }

    /// The form behind a token (the recipient's view). nil when the token does not exist.
    public func humanInputForm(token: String) async throws -> StoredHumanInputForm? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.formColumns) FROM human_input_forms WHERE token = \(token)
                """, logger: self.logger)
            for try await row in rows { return try Self.decodeForm(row) }
            return nil
        }
    }

    /// The forms a resumed run reads back, oldest first.
    public func humanInputForms(workflowRunId: String) async throws -> [StoredHumanInputForm] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.formColumns) FROM human_input_forms
                WHERE workflow_run_id = \(workflowRunId) ORDER BY created_at
                """, logger: self.logger)
            var out: [StoredHumanInputForm] = []
            for try await row in rows { out.append(try Self.decodeForm(row)) }
            return out
        }
    }

    /// Dify's `POST /form/human_input/{token}`: one conditional update from `waiting`, so a form is answered at most
    /// once, whatever the number of callers. An expired form is recorded as expired and answered 412
    /// `human_input_form_expired`; a second submission gets 412 `human_input_form_submitted`; an unknown token is 404.
    public func submitHumanInputForm(token: String, inputs: String, action: String, userId: String, at: Date,
                                     now: Int) async throws -> HumanInputSubmitOutcome {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                let claimed = try await c.query("""
                    UPDATE human_input_forms SET status = 'submitted', submitted_inputs = \(inputs),
                        submitted_action = \(action), submitted_by = \(userId), submitted_at = \(at)
                    WHERE token = \(token) AND status = 'waiting'
                      AND (expiration_time IS NULL OR expiration_time > \(Int64(now)))
                    RETURNING \(unescaped: Self.formColumns)
                    """, logger: self.logger)
                for try await row in claimed {
                    let form = try Self.decodeForm(row)
                    // The pause may not exist yet (a form persisted first): 0 rows then, and `createPause` folds this
                    // submission in. Either ordering leaves a durable resume request.
                    _ = try await c.query("""
                        UPDATE workflow_pauses SET resume_requested = true
                        WHERE workflow_run_id = \(form.workflowRunId) AND execution_id = \(form.executionId)
                          AND resumed_at IS NULL
                        """, logger: self.logger)
                    return .accepted(form)
                }

                // Nothing was claimed: say why. A form still `waiting` was inside its deadline at the update, so this
                // is the expired case; recording it keeps the state the next caller reads the same as this answer.
                let read = try await c.query("""
                    SELECT \(unescaped: Self.formColumns) FROM human_input_forms WHERE token = \(token)
                    """, logger: self.logger)
                for try await row in read {
                    let form = try Self.decodeForm(row)
                    switch form.status {
                    case .submitted: return .alreadySubmitted
                    case .expired: return .expired
                    case .waiting:
                        _ = try await c.query("""
                            UPDATE human_input_forms SET status = 'expired'
                            WHERE token = \(token) AND status = 'waiting'
                            """, logger: self.logger)
                        return .expired
                    }
                }
                return .notFound
            }
        }
    }

    /// Marks a submitted form as read by the resumed run, so a pause that is rebuilt cannot wake the run again.
    /// Idempotent.
    public func consumeHumanInputForm(token: String, at: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE human_input_forms SET consumed_at = coalesce(consumed_at, \(at))
                WHERE token = \(token) AND status = 'submitted'
                """, logger: self.logger)
        }
    }
}
