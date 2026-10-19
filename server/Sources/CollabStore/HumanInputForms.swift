import Foundation
import PostgresNIO

/// A paused run waiting for human input (protocol 1.16). The pause belongs to the run, not to one node: `generation`
/// counts the run's pauses, the snapshot is the whole engine state, and resuming is claimed once per generation.
public struct StoredWorkflowPause: Sendable, Equatable {
    public var workflowRunId: String
    public var generation: Int
    public var docId: String
    /// The node whose pause produced this generation (the one that stopped the dispatcher first).
    public var nodeId: String
    public var snapshot: String
    public var totalTokens: Int
    public var totalSteps: Int
    public var elapsedTime: Double
    public var createdAt: Date
    public var resumedAt: Date?
    /// Every form of this generation is answered (submitted, expired or timed out) and the run may resume.
    public var resumeRequested: Bool

    public init(workflowRunId: String, generation: Int, docId: String, nodeId: String = "", snapshot: String,
                totalTokens: Int = 0, totalSteps: Int = 0, elapsedTime: Double = 0, createdAt: Date,
                resumedAt: Date? = nil, resumeRequested: Bool = false) {
        self.workflowRunId = workflowRunId
        self.generation = generation
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

/// The state of one form. `submitted`, `expired` (the form's own deadline) and `timedOut` (the node's deadline) are
/// terminal, and they mean different things to the run: an expired form makes the resume invalid, a timed-out node
/// fails that node and lets the run continue through its `__timeout` branch.
public enum HumanInputFormStatus: String, Sendable {
    case waiting
    case submitted
    case expired
    case timedOut = "timed_out"

    public var isTerminal: Bool { self != .waiting }
}

/// One human-input form (protocol 1.16, Dify's FormDefinition + its delivery state). Every JSON member is the exact text
/// the runtime rendered, never re-encoded here: the client compares field order and number kinds with Dify's.
public struct StoredHumanInputForm: Sendable, Equatable {
    public var id: String
    public var workflowRunId: String
    /// The pause this form currently belongs to.
    public var generation: Int
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

    public init(id: String, workflowRunId: String, generation: Int = 1, executionId: String, docId: String, nodeId: String,
                nodeTitle: String, token: String, formContent: String, inputs: String, userActions: String,
                renderedContent: String, defaultValues: String? = nil, resolvedDefaultValues: String? = nil,
                actions: String, displayInUi: Bool, expirationTime: Int? = nil, status: HumanInputFormStatus = .waiting,
                submittedInputs: String? = nil, submittedAction: String? = nil, submittedBy: String? = nil,
                submittedAt: Date? = nil, consumedAt: Date? = nil, createdAt: Date) {
        self.id = id
        self.workflowRunId = workflowRunId
        self.generation = generation
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

public enum HumanInputStoreError: Error, Equatable {
    /// A status value the schema does not define: never guessed (guessing `waiting` would reopen a closed form).
    case unknownStatus(String)
    /// `createPause` could not write the pause. The caller must stop the run and report the failure — the pause may not
    /// be skipped, or the run would continue past human input, and it may not be replayed, or finished nodes would run
    /// again.
    case pauseNotPersisted(String)
}

extension PostgresStore {
    static let formColumns = """
        id, workflow_run_id, generation, execution_id, doc_id, node_id, node_title, token, form_content, inputs,
        user_actions, rendered_content, default_values, resolved_default_values, actions, display_in_ui, expiration_time,
        status, submitted_inputs, submitted_action, submitted_by, submitted_at, consumed_at, created_at
        """

    static func decodeForm(_ row: PostgresRow) throws -> StoredHumanInputForm {
        let r = row.makeRandomAccess()
        let rawStatus = try r[17].decode(String.self)
        guard let status = HumanInputFormStatus(rawValue: rawStatus) else {
            throw HumanInputStoreError.unknownStatus(rawStatus)
        }
        return StoredHumanInputForm(
            id: try r[0].decode(String.self), workflowRunId: try r[1].decode(String.self),
            generation: Int(try r[2].decode(Int32.self)), executionId: try r[3].decode(String.self),
            docId: try r[4].decode(String.self), nodeId: try r[5].decode(String.self),
            nodeTitle: try r[6].decode(String.self), token: try r[7].decode(String.self),
            formContent: try r[8].decode(String.self), inputs: try r[9].decode(String.self),
            userActions: try r[10].decode(String.self), renderedContent: try r[11].decode(String.self),
            defaultValues: try r[12].decode(String?.self), resolvedDefaultValues: try r[13].decode(String?.self),
            actions: try r[14].decode(String.self), displayInUi: try r[15].decode(Bool.self),
            expirationTime: try r[16].decode(Int64?.self).map { Int($0) }, status: status,
            submittedInputs: try r[18].decode(String?.self), submittedAction: try r[19].decode(String?.self),
            submittedBy: try r[20].decode(String?.self), submittedAt: try r[21].decode(Date?.self),
            consumedAt: try r[22].decode(Date?.self), createdAt: try r[23].decode(Date.self))
    }

    static let pauseColumns = """
        workflow_run_id, generation, doc_id, node_id, snapshot, total_tokens, total_steps, elapsed_time, created_at,
        resumed_at, resume_requested
        """

    static func decodePause(_ row: PostgresRow) throws -> StoredWorkflowPause {
        let r = row.makeRandomAccess()
        return StoredWorkflowPause(
            workflowRunId: try r[0].decode(String.self), generation: Int(try r[1].decode(Int32.self)),
            docId: try r[2].decode(String.self), nodeId: try r[3].decode(String.self),
            snapshot: try r[4].decode(String.self), totalTokens: Int(try r[5].decode(Int64.self)),
            totalSteps: Int(try r[6].decode(Int32.self)), elapsedTime: try r[7].decode(Double.self),
            createdAt: try r[8].decode(Date.self), resumedAt: try r[9].decode(Date?.self),
            resumeRequested: try r[10].decode(Bool.self))
    }

    /// Serializes every writer of one run's pause and forms on the run's own row, in the order run → forms. Two
    /// submissions arriving together, and a submission racing a pause that is still being written, all queue here; that
    /// is what makes the wake flag below exact instead of a snapshot read before the lock.
    private func lockRun(_ run: String, _ c: PostgresConnection) async throws {
        let rows = try await c.query("SELECT id FROM workflow_runs WHERE id = \(run) FOR UPDATE", logger: self.logger)
        var found = false
        for try await _ in rows { found = true }
        if !found { throw HumanInputStoreError.pauseNotPersisted("workflow run \(run) does not exist") }
    }

    /// Recomputes the run's wake flag from its forms, inside the caller's transaction and after the run row is locked.
    /// The run resumes when no form of the generation is still waiting — A finished and B still waiting must not wake
    /// it, and B's submission must wake it even though B is not the node whose pause was recorded.
    private func refreshWake(_ run: String, _ generation: Int, _ c: PostgresConnection) async throws {
        _ = try await c.query("""
            UPDATE workflow_pauses p SET resume_requested = NOT EXISTS (
                SELECT 1 FROM human_input_forms f
                WHERE f.workflow_run_id = p.workflow_run_id AND f.generation = p.generation AND f.status = 'waiting')
            WHERE p.workflow_run_id = \(run) AND p.generation = \(generation) AND p.resumed_at IS NULL
            """, logger: self.logger)
    }

    /// Writes a pause and its forms in one transaction, under the run's lock: generation = the run's next pause count.
    /// A form that is already waiting for its execution is adopted (same id, same token — the recipient keeps the link),
    /// so a second pause of the same run does not mint a new one. Returns the generation written.
    ///
    /// If this throws, the pause is not durable: the caller must stop the run and report the failure. Continuing would
    /// pass human input, and replaying would run finished nodes again.
    @discardableResult
    public func createPause(workflowRunId: String, docId: String, nodeId: String = "", snapshot: String, totalTokens: Int = 0,
                            totalSteps: Int = 0, elapsedTime: Double = 0, forms: [StoredHumanInputForm],
                            at: Date) async throws -> Int {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(workflowRunId, c)
                let next = try await c.query("""
                    SELECT coalesce(max(generation), 0) + 1 FROM workflow_pauses WHERE workflow_run_id = \(workflowRunId)
                    """, logger: self.logger)
                var generation = 1
                for try await (g,) in next { generation = Int(try g.decode(Int32.self)) }
                _ = try await c.query("""
                    INSERT INTO workflow_pauses (workflow_run_id, generation, doc_id, node_id, snapshot, total_tokens,
                        total_steps, elapsed_time, created_at)
                    VALUES (\(workflowRunId), \(generation), \(docId), \(nodeId), \(snapshot), \(totalTokens), \(totalSteps),
                        \(elapsedTime), \(at))
                    """, logger: self.logger)
                for f in forms {
                    // `ON CONFLICT` on (run, execution): a form still waiting keeps its id and token and simply moves to
                    // this generation; a terminal one stays where it is (that execution is not waiting again).
                    _ = try await c.query("""
                        INSERT INTO human_input_forms (id, workflow_run_id, generation, execution_id, doc_id, node_id,
                            node_title, token, form_content, inputs, user_actions, rendered_content, default_values,
                            resolved_default_values, actions, display_in_ui, expiration_time, status, created_at)
                        VALUES (\(f.id), \(workflowRunId), \(generation), \(f.executionId), \(docId), \(f.nodeId),
                            \(f.nodeTitle), \(f.token), \(f.formContent), \(f.inputs), \(f.userActions), \(f.renderedContent),
                            \(f.defaultValues), \(f.resolvedDefaultValues), \(f.actions), \(f.displayInUi),
                            \(f.expirationTime.map { Int64($0) }), \(f.status.rawValue), \(f.createdAt))
                        ON CONFLICT (workflow_run_id, execution_id) DO UPDATE
                            SET generation = EXCLUDED.generation
                            WHERE human_input_forms.status = 'waiting'
                        """, logger: self.logger)
                }
                try await self.refreshWake(workflowRunId, generation, c)
                return generation
            }
        }
    }

    /// The pauses of a run that were not resumed yet, oldest first: what a restarted server re-attaches to.
    public func openPauses(workflowRunId: String) async throws -> [StoredWorkflowPause] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.pauseColumns) FROM workflow_pauses
                WHERE workflow_run_id = \(workflowRunId) AND resumed_at IS NULL ORDER BY generation
                """, logger: self.logger)
            var out: [StoredWorkflowPause] = []
            for try await row in rows { out.append(try Self.decodePause(row)) }
            return out
        }
    }

    public func pause(workflowRunId: String, generation: Int) async throws -> StoredWorkflowPause? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.pauseColumns) FROM workflow_pauses
                WHERE workflow_run_id = \(workflowRunId) AND generation = \(generation)
                """, logger: self.logger)
            for try await row in rows { return try Self.decodePause(row) }
            return nil
        }
    }

    /// Claims a generation for resumption: exactly one caller wins, whatever the number of waiting nodes, because the
    /// claim is the run's generation and not one node execution. True when this call claimed it.
    public func claimResume(workflowRunId: String, generation: Int, at: Date) async throws -> Bool {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(workflowRunId, c)
                let rows = try await c.query("""
                    UPDATE workflow_pauses SET resumed_at = \(at)
                    WHERE workflow_run_id = \(workflowRunId) AND generation = \(generation) AND resumed_at IS NULL
                    RETURNING generation
                    """, logger: self.logger)
                for try await _ in rows { return true }
                return false
            }
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
    /// once, whatever the number of callers. Runs under the run's lock and recomputes the run's wake flag over the whole
    /// generation — answering the last waiting form wakes the run, answering one of two does not.
    public func submitHumanInputForm(token: String, inputs: String, action: String, userId: String, at: Date,
                                     now: Int) async throws -> HumanInputSubmitOutcome {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                // The run to lock first comes from the token; only after the lock do we read the form's state, so a
                // pause being written concurrently cannot slip between the read and the update.
                let owner = try await c.query("SELECT workflow_run_id FROM human_input_forms WHERE token = \(token)",
                                              logger: self.logger)
                var run: String?
                for try await (id,) in owner { run = try id.decode(String.self) }
                guard let workflowRunId = run else { return .notFound }
                try await self.lockRun(workflowRunId, c)

                let claimed = try await c.query("""
                    UPDATE human_input_forms SET status = 'submitted', submitted_inputs = \(inputs),
                        submitted_action = \(action), submitted_by = \(userId), submitted_at = \(at)
                    WHERE token = \(token) AND workflow_run_id = \(workflowRunId) AND status = 'waiting'
                      AND (expiration_time IS NULL OR expiration_time > \(Int64(now)))
                    RETURNING \(unescaped: Self.formColumns)
                    """, logger: self.logger)
                for try await row in claimed {
                    let form = try Self.decodeForm(row)
                    try await self.refreshWake(workflowRunId, form.generation, c)
                    return .accepted(form)
                }

                // Nothing was claimed: say why, from a read taken after the lock. A form still `waiting` was inside its
                // deadline at the update, so this is the expired case; recording it keeps later answers the same.
                let read = try await c.query("""
                    SELECT \(unescaped: Self.formColumns) FROM human_input_forms WHERE token = \(token)
                    """, logger: self.logger)
                for try await row in read {
                    let form = try Self.decodeForm(row)
                    switch form.status {
                    case .submitted: return .alreadySubmitted
                    case .expired, .timedOut: return .expired
                    case .waiting:
                        _ = try await c.query("""
                            UPDATE human_input_forms SET status = 'expired' WHERE token = \(token) AND status = 'waiting'
                            """, logger: self.logger)
                        try await self.refreshWake(workflowRunId, form.generation, c)
                        return .expired
                    }
                }
                return .notFound
            }
        }
    }

    /// The form's own deadline passed while it waited (`expired`, the resume becomes invalid) or the node's deadline did
    /// (`timedOut`, that node fails and the run continues through `__timeout`). Both leave the run answerable only if
    /// every other form of the generation is already terminal.
    public func endHumanInputForm(token: String, status: HumanInputFormStatus, at: Date) async throws -> Bool {
        precondition(status.isTerminal, "only a terminal status ends a form")
        return try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                let owner = try await c.query("SELECT workflow_run_id FROM human_input_forms WHERE token = \(token)",
                                              logger: self.logger)
                var run: String?
                for try await (id,) in owner { run = try id.decode(String.self) }
                guard let workflowRunId = run else { return false }
                try await self.lockRun(workflowRunId, c)
                let rows = try await c.query("""
                    UPDATE human_input_forms SET status = \(status.rawValue)
                    WHERE token = \(token) AND workflow_run_id = \(workflowRunId) AND status = 'waiting'
                    RETURNING generation
                    """, logger: self.logger)
                var generation: Int?
                for try await (g,) in rows { generation = Int(try g.decode(Int32.self)) }
                guard let generation else { return false }
                try await self.refreshWake(workflowRunId, generation, c)
                return true
            }
        }
    }

    /// Marks a submitted form as read by the resumed run, so a rebuilt pause cannot wake the run again. Idempotent.
    public func consumeHumanInputForm(token: String, at: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE human_input_forms SET consumed_at = coalesce(consumed_at, \(at))
                WHERE token = \(token) AND status = 'submitted'
                """, logger: self.logger)
        }
    }
}

extension PostgresStore {
    /// Test-only escape hatch (`@testable import CollabStore`) for states the API never writes: an unknown status, to
    /// prove the decoder refuses it instead of reading a closed form as waiting.
    func executeForTest(_ sql: String) async throws {
        try await bounded {
            _ = try await self.client.query(PostgresQuery(unsafeSQL: sql), logger: self.logger)
        }
    }
}
