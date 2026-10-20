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
    /// The node executions this pause's snapshot still has to decide on: the resume consumes exactly their forms.
    public var executionIds: [String]
    public var totalTokens: Int
    public var totalSteps: Int
    public var elapsedTime: Double
    public var createdAt: Date
    public var resumedAt: Date?
    /// Every form of this generation is answered (submitted, expired or timed out) and the run may resume.
    public var resumeRequested: Bool

    public init(workflowRunId: String, generation: Int, docId: String, nodeId: String = "", snapshot: String,
                executionIds: [String] = [], totalTokens: Int = 0, totalSteps: Int = 0, elapsedTime: Double = 0,
                createdAt: Date, resumedAt: Date? = nil, resumeRequested: Bool = false) {
        self.workflowRunId = workflowRunId
        self.generation = generation
        self.docId = docId
        self.nodeId = nodeId
        self.snapshot = snapshot
        self.executionIds = executionIds
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
/// Dify's `HumanInputFormRecipientType`: the surface a form was delivered to. The console API serves `console`; a token
/// addressed elsewhere answers 404 there, as Dify does (`is_recipient_type_allowed_for_surface`).
public enum HumanInputRecipient: String, Sendable {
    case console
    case backstage
    case webapp
}

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
    public var recipientType: HumanInputRecipient

    public init(id: String, workflowRunId: String, generation: Int = 1, executionId: String, docId: String, nodeId: String,
                nodeTitle: String, token: String, formContent: String, inputs: String, userActions: String,
                renderedContent: String, defaultValues: String? = nil, resolvedDefaultValues: String? = nil,
                actions: String, displayInUi: Bool, expirationTime: Int? = nil, status: HumanInputFormStatus = .waiting,
                submittedInputs: String? = nil, submittedAction: String? = nil, submittedBy: String? = nil,
                submittedAt: Date? = nil, consumedAt: Date? = nil, createdAt: Date,
                recipientType: HumanInputRecipient = .console) {
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
        self.recipientType = recipientType
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

/// What a resume took from a pause: the generation it closed and the decisions it must apply. `decisions` are the forms
/// that were already terminal for the executions this pause covers; `consumed_at` only says a resume took them, never
/// that the engine is done with them — the inputs are still there to read, and a submission that arrives afterwards is
/// not in this list: it is left for the next pause.
public struct HumanInputResumeClaim: Sendable, Equatable {
    public var generation: Int
    public var pause: StoredWorkflowPause
    public var decisions: [StoredHumanInputForm]
}

public enum HumanInputStoreError: Error, Equatable {
    /// A delivery surface the schema does not define: never read as `console` (that would open a form to a surface it
    /// was not delivered to).
    case unknownRecipient(String)
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
        status, submitted_inputs, submitted_action, submitted_by, submitted_at, consumed_at, created_at, recipient_type
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
            consumedAt: try r[22].decode(Date?.self), createdAt: try r[23].decode(Date.self),
            recipientType: try Self.decodeRecipient(try r[24].decode(String.self)))
    }

    static let pauseColumns = """
        workflow_run_id, generation, doc_id, node_id, snapshot, execution_ids, total_tokens, total_steps, elapsed_time,
        created_at, resumed_at, resume_requested
        """

    /// An unknown recipient is refused like an unknown status: reading it as `console` would hand a form to a surface it
    /// was never delivered to.
    static func decodeRecipient(_ raw: String) throws -> HumanInputRecipient {
        guard let value = HumanInputRecipient(rawValue: raw) else {
            throw HumanInputStoreError.unknownRecipient(raw)
        }
        return value
    }

    static func decodePause(_ row: PostgresRow) throws -> StoredWorkflowPause {
        let r = row.makeRandomAccess()
        return StoredWorkflowPause(
            workflowRunId: try r[0].decode(String.self), generation: Int(try r[1].decode(Int32.self)),
            docId: try r[2].decode(String.self), nodeId: try r[3].decode(String.self),
            snapshot: try r[4].decode(String.self), executionIds: try r[5].decode([String].self),
            totalTokens: Int(try r[6].decode(Int64.self)), totalSteps: Int(try r[7].decode(Int32.self)),
            elapsedTime: try r[8].decode(Double.self), createdAt: try r[9].decode(Date.self),
            resumedAt: try r[10].decode(Date?.self), resumeRequested: try r[11].decode(Bool.self))
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

    /// Dify's wake rule (`services/human_input_service.py` `enqueue_resume`, `callback.py`): **every** submission or node
    /// timeout asks for a resume; the engine decides on resume whether another form still waits and pauses again. So the
    /// flag is "this run has a terminal form that no resume has consumed yet", never "nothing is waiting" — A's answer
    /// must resume the run while B still waits, and a submitted B that no resume has seen must wake the next pause too.
    private func refreshWake(_ run: String, _ c: PostgresConnection) async throws {
        _ = try await c.query("""
            UPDATE workflow_pauses p SET resume_requested = EXISTS (
                SELECT 1 FROM human_input_forms f
                WHERE f.workflow_run_id = p.workflow_run_id AND f.execution_id = ANY(p.execution_ids)
                  AND f.status IN ('submitted', 'timed_out') AND f.consumed_at IS NULL)
            WHERE p.workflow_run_id = \(run) AND p.resumed_at IS NULL
            """, logger: self.logger)
    }

    /// Writes a pause and its forms in one transaction, under the run's lock: the run becomes `paused` and gets its next
    /// generation. A form already waiting for its execution is adopted (same id, same token — the recipient keeps the
    /// link), and a form that was answered or timed out since the last resume but not yet consumed keeps the new pause
    /// awake: the pause must see the executions its snapshot still has to handle, not only the ones still `waiting`.
    /// Returns the generation written.
    ///
    /// If this throws, the pause is not durable: the caller must stop the run and report the failure. Continuing would
    /// pass human input, and replaying would run finished nodes again.
    /// Why a pause was refused although the run is still alive: the app was deleted while the round ran, so there is
    /// nobody to answer it and the run must stop instead of waiting.
    public enum PauseRefused: Error, Equatable { case appDeleted }

    @discardableResult
    public func createPause(workflowRunId: String, docId: String, nodeId: String = "", snapshot: String, totalTokens: Int = 0,
                            totalSteps: Int = 0, elapsedTime: Double = 0, forms: [StoredHumanInputForm],
                            at: Date) async throws -> Int {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(workflowRunId, c)
                // One open pause per run (Dify's `UniqueConstraint workflow_run_id`): a pause that was not resumed yet is
                // the run's only one, so two generations cannot both be claimed.
                // A deleted app's engine can still be mid-round (deletion closes the pauses that exist, not the engine):
                // writing a new pause would leave a run nobody can see, and no one to answer it.
                let gone = try await c.query("SELECT 1 FROM apps WHERE doc_id = \(docId) AND deleted_at IS NOT NULL",
                                             logger: self.logger)
                for try await _ in gone { throw PauseRefused.appDeleted }
                let status = try await c.query("SELECT status FROM workflow_runs WHERE id = \(workflowRunId) FOR UPDATE",
                                               logger: self.logger)
                var runStatus = ""
                for try await (st,) in status { runStatus = try st.decode(String.self) }
                // Only a running run pauses. A stop or a global expiry that committed first must stay terminal: a pause
                // that arrives late may not resurrect it.
                guard runStatus == "running" else {
                    throw HumanInputStoreError.pauseNotPersisted("workflow run \(workflowRunId) is \(runStatus), not running")
                }
                let open = try await c.query("""
                    SELECT generation FROM workflow_pauses WHERE workflow_run_id = \(workflowRunId) AND resumed_at IS NULL
                    """, logger: self.logger)
                for try await _ in open {
                    throw HumanInputStoreError.pauseNotPersisted("workflow run \(workflowRunId) already has an open pause")
                }
                let next = try await c.query("""
                    SELECT coalesce(max(generation), 0) + 1 FROM workflow_pauses WHERE workflow_run_id = \(workflowRunId)
                    """, logger: self.logger)
                var generation = 1
                for try await (g,) in next { generation = Int(try g.decode(Int32.self)) }
                // The executions this pause has to decide on: the forms written with it, plus any execution whose answer
                // (or node timeout) is already terminal but no resume has consumed — those are decisions this snapshot
                // still carries, so the flag and the claim agree instead of a flag set by a form the claim cannot take.
                let covered = try await c.query("""
                    SELECT \(forms.map(\.executionId)) || coalesce(array_agg(DISTINCT execution_id)
                        FILTER (WHERE status IN ('submitted', 'timed_out') AND consumed_at IS NULL), '{}')
                    FROM human_input_forms WHERE workflow_run_id = \(workflowRunId)
                    """, logger: self.logger)
                var executionIds = forms.map(\.executionId)
                for try await (ids,) in covered { executionIds = try ids.decode([String].self) }
                _ = try await c.query("""
                    UPDATE workflow_runs SET status = 'paused' WHERE id = \(workflowRunId)
                    """, logger: self.logger)
                _ = try await c.query("""
                    INSERT INTO workflow_pauses (workflow_run_id, generation, doc_id, node_id, snapshot, execution_ids,
                        total_tokens, total_steps, elapsed_time, created_at)
                    VALUES (\(workflowRunId), \(generation), \(docId), \(nodeId), \(snapshot), \(executionIds),
                        \(totalTokens), \(totalSteps), \(elapsedTime), \(at))
                    """, logger: self.logger)
                for f in forms {
                    // `ON CONFLICT` on (run, execution): a form still waiting keeps its id and token and moves to this
                    // generation. A terminal one keeps its generation and its `consumed_at`; the wake calculation below
                    // still counts it while no resume has seen it.
                    _ = try await c.query("""
                        INSERT INTO human_input_forms (id, workflow_run_id, generation, execution_id, doc_id, node_id,
                            node_title, token, form_content, inputs, user_actions, rendered_content, default_values,
                            resolved_default_values, actions, display_in_ui, expiration_time, status, created_at, recipient_type)
                        VALUES (\(f.id), \(workflowRunId), \(generation), \(f.executionId), \(docId), \(f.nodeId),
                            \(f.nodeTitle), \(f.token), \(f.formContent), \(f.inputs), \(f.userActions), \(f.renderedContent),
                            \(f.defaultValues), \(f.resolvedDefaultValues), \(f.actions), \(f.displayInUi),
                            \(f.expirationTime.map { Int64($0) }), \(f.status.rawValue), \(f.createdAt), \(f.recipientType.rawValue))
                        ON CONFLICT (workflow_run_id, execution_id) DO UPDATE
                            SET generation = EXCLUDED.generation
                            WHERE human_input_forms.status = 'waiting'
                        """, logger: self.logger)
                }
                try await self.refreshWake(workflowRunId, c)
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

    /// The runs a restarted server has to resume: a pause that is still open and already asked for (its answer was taken
    /// before the process stopped). `docId` is the run's document, i.e. what `resumeRun` needs beside the id.
    public func runsAwaitingResume() async throws -> [(runId: String, docId: String)] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT p.workflow_run_id, p.doc_id FROM workflow_pauses p
                JOIN workflow_runs r ON r.id = p.workflow_run_id
                WHERE p.resumed_at IS NULL AND p.resume_requested AND r.status = 'paused'
                ORDER BY p.created_at
                """, logger: self.logger)
            var out: [(String, String)] = []
            for try await row in rows {
                let r = row.makeRandomAccess()
                out.append((try r[0].decode(String.self), try r[1].decode(String.self)))
            }
            return out
        }
    }

    /// Claims the run's resumption: one atomic `paused → running` on the run row, allowed only when the run is paused and
    /// its single open pause has an unconsumed answer. The pause is closed, and **only the forms of the executions this
    /// pause covers** are marked consumed and handed back as `decisions` — a submission that arrives afterwards belongs to
    /// the next pause, and an answer this resume already took does not wake again. Old generations, a waiting run and a
    /// stopped or failed run are all refused.
    public func claimResume(workflowRunId: String, at: Date) async throws -> HumanInputResumeClaim? {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(workflowRunId, c)
                let won = try await c.query("""
                    UPDATE workflow_runs SET status = 'running'
                    WHERE id = \(workflowRunId) AND status = 'paused'
                      AND EXISTS (SELECT 1 FROM workflow_pauses p
                                  WHERE p.workflow_run_id = \(workflowRunId) AND p.resumed_at IS NULL AND p.resume_requested)
                    RETURNING id
                    """, logger: self.logger)
                var claimed = false
                for try await _ in won { claimed = true }
                guard claimed else { return nil }
                let closed = try await c.query("""
                    UPDATE workflow_pauses SET resumed_at = \(at)
                    WHERE workflow_run_id = \(workflowRunId) AND resumed_at IS NULL
                    RETURNING \(unescaped: Self.pauseColumns)
                    """, logger: self.logger)
                var pause: StoredWorkflowPause?
                for try await row in closed { pause = try Self.decodePause(row) }
                guard let pause else { return nil }
                let taken = try await c.query("""
                    UPDATE human_input_forms SET consumed_at = \(at)
                    WHERE workflow_run_id = \(workflowRunId) AND execution_id = ANY(\(pause.executionIds))
                      AND status IN ('submitted', 'timed_out') AND consumed_at IS NULL
                    RETURNING \(unescaped: Self.formColumns)
                    """, logger: self.logger)
                var decisions: [StoredHumanInputForm] = []
                for try await row in taken { decisions.append(try Self.decodeForm(row)) }
                return HumanInputResumeClaim(generation: pause.generation, pause: pause, decisions: decisions)
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

    /// The form of one node execution (the pair a resume or a re-decision asks about), nil when it does not exist.
    public func humanInputForm(workflowRunId: String, executionId: String) async throws -> StoredHumanInputForm? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.formColumns) FROM human_input_forms
                WHERE workflow_run_id = \(workflowRunId) AND execution_id = \(executionId)
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

    /// Dify's `POST /form/human_input/{token}`: `ensure_form_active` first (already submitted, a terminal status, the node's
    /// `expiration_time`, the global deadline), then one conditional update from `waiting`, so a form is answered at most
    /// once whatever the number of callers. Runs under the run's lock and asks for a resume — Dify's `enqueue_resume` runs
    /// on every submission, and the engine pauses again for whichever other form still waits.
    ///
    /// The deadlines are checked here, not left to the timeout scanner: a submission that arrives after one must be 412
    /// even if the scan has not run yet. The clock is taken after the lock, so a wait that carries the request past a
    /// deadline is refused rather than admitted with a stale `now`. A node deadline answers as expired but leaves the row `waiting` for the scanner to mark `timed_out`.
    public func submitHumanInputForm(token: String, inputs: String, action: String, userId: String,
                                     globalTimeoutSeconds: Int = 0) async throws -> HumanInputSubmitOutcome {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                let owner = try await c.query("SELECT workflow_run_id FROM human_input_forms WHERE token = \(token)",
                                              logger: self.logger)
                var run: String?
                for try await (id,) in owner { run = try id.decode(String.self) }
                guard let workflowRunId = run else { return .notFound }
                try await self.lockRun(workflowRunId, c)

                let read = try await c.query("""
                    SELECT status, expiration_time, created_at FROM human_input_forms
                    WHERE token = \(token) AND workflow_run_id = \(workflowRunId) FOR UPDATE
                    """, logger: self.logger)
                var status: String?
                var expiration: Int64?
                var createdAt: Date?
                for try await row in read {
                    let r = row.makeRandomAccess()
                    status = try r[0].decode(String.self)
                    expiration = try r[1].decode(Int64?.self)
                    createdAt = try r[2].decode(Date.self)
                }
                guard let status else { return .notFound }
                switch HumanInputFormStatus(rawValue: status) {
                case .submitted: return .alreadySubmitted
                case .expired, .timedOut: return .expired
                case .waiting: break
                case nil: throw HumanInputStoreError.unknownStatus(status)
                }
                // The clock is read **after** the lock: waiting for it may have carried the submission past a deadline.
                let at = Date()
                if let expiration, Int64(at.timeIntervalSince1970) >= expiration { return .expired }
                if globalTimeoutSeconds > 0, let createdAt,
                   at.timeIntervalSince(createdAt) >= Double(globalTimeoutSeconds) { return .expired }

                let claimed = try await c.query("""
                    UPDATE human_input_forms SET status = 'submitted', submitted_inputs = \(inputs),
                        submitted_action = \(action), submitted_by = \(userId), submitted_at = \(at)
                    WHERE token = \(token) AND workflow_run_id = \(workflowRunId) AND status = 'waiting'
                    RETURNING \(unescaped: Self.formColumns)
                    """, logger: self.logger)
                for try await row in claimed {
                    let form = try Self.decodeForm(row)
                    try await self.refreshWake(workflowRunId, c)
                    return .accepted(form)
                }
                // Lost the row to another writer between the read and the update: read the outcome it left.
                let after = try await c.query("""
                    SELECT \(unescaped: Self.formColumns) FROM human_input_forms WHERE token = \(token)
                    """, logger: self.logger)
                for try await row in after {
                    let form = try Self.decodeForm(row)
                    switch form.status {
                    case .submitted: return .alreadySubmitted
                    case .expired, .timedOut: return .expired
                    case .waiting: return .expired
                    }
                }
                return .notFound
            }
        }
    }

    /// The form's own deadline passed while it waited (`timedOut`, the node takes `__timeout` and the run resumes) or the
    /// form was closed for another reason. Dify's timeout task calls this and then `enqueue_resume`; the transition is
    /// conditional on `waiting`, so a submission that won the race is not overwritten.
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
                    RETURNING execution_id
                    """, logger: self.logger)
                var ended = false
                for try await _ in rows { ended = true }
                guard ended else { return false }
                try await self.refreshWake(workflowRunId, c)
                return true
            }
        }
    }

    /// The runs of one document that are waiting on a pause right now (a deleted app stops them).
    public func pausedRuns(ofDocument doc: String) async throws -> [String] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT workflow_run_id FROM workflow_pauses WHERE doc_id = \(doc) AND resumed_at IS NULL
                """, logger: self.logger)
            var out: [String] = []
            for try await (id,) in rows { out.append(try id.decode(String.self)) }
            return out
        }
    }

    /// Waiting forms whose own deadline passed (`expiration_time`, Unix seconds): what a timeout scan ends with
    /// `timedOut` so the run takes the node's `__timeout` branch (Dify's `human_input_timeout_tasks`).
    public func waitingFormsPastDeadline(at now: Date, limit: Int = 500) async throws -> [StoredHumanInputForm] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.formColumns) FROM human_input_forms
                WHERE status = 'waiting' AND expiration_time IS NOT NULL AND expiration_time <= \(Int64(now.timeIntervalSince1970))
                ORDER BY expiration_time
                LIMIT \(limit)
                """, logger: self.logger)
            var out: [StoredHumanInputForm] = []
            for try await row in rows { out.append(try Self.decodeForm(row)) }
            return out
        }
    }

    /// Paused runs past the global deadline (`created_at + timeoutSeconds`): Dify's `EXPIRED` (the run stops), which is
    /// not the node's own timeout.
    public func pausedRunsPastGlobalDeadline(at now: Date, timeoutSeconds: Int, limit: Int = 500) async throws -> [(runId: String, docId: String)] {
        guard timeoutSeconds > 0 else { return [] }
        return try await bounded {
            let rows = try await self.client.query("""
                SELECT id, doc_id FROM workflow_runs
                WHERE status = 'paused' AND created_at <= \(now.addingTimeInterval(-Double(timeoutSeconds)))
                ORDER BY created_at
                LIMIT \(limit)
                """, logger: self.logger)
            var out: [(String, String)] = []
            for try await row in rows {
                let r = row.makeRandomAccess()
                out.append((try r[0].decode(String.self), try r[1].decode(String.self)))
            }
            return out
        }
    }

    /// A stop while the run waits: the waiting forms are closed (`expired`, so a later submission answers 412 instead of
    /// waking it), the run becomes `stopped` and the pause is closed. A run that is not paused is left alone.
    @discardableResult
    public func stopPausedRun(workflowRunId: String, error: String, at: Date) async throws -> Bool {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(workflowRunId, c)
                let rows = try await c.query("""
                    UPDATE workflow_runs SET status = 'stopped', error = \(error), finished_at = \(at)
                    WHERE id = \(workflowRunId) AND status = 'paused'
                    RETURNING id
                    """, logger: self.logger)
                var stopped = false
                for try await _ in rows { stopped = true }
                guard stopped else { return false }
                _ = try await c.query("""
                    UPDATE human_input_forms SET status = 'expired'
                    WHERE workflow_run_id = \(workflowRunId) AND status = 'waiting'
                    """, logger: self.logger)
                _ = try await c.query("""
                    UPDATE workflow_pauses SET resumed_at = \(at)
                    WHERE workflow_run_id = \(workflowRunId) AND resumed_at IS NULL
                    """, logger: self.logger)
                return true
            }
        }
    }

    /// The global deadline (`created_at + HUMAN_INPUT_GLOBAL_TIMEOUT_SECONDS`), which is not the node's: every form still
    /// waiting is marked `expired`, the run is stopped with the error Dify writes, and the pause is closed. Dify's
    /// `_handle_global_timeout` does the same three things; a node's own deadline takes `endHumanInputForm(.timedOut)`.
    @discardableResult
    public func expireRunForGlobalTimeout(workflowRunId: String, error: String, at: Date) async throws -> Bool {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { c in
                try await self.lockRun(workflowRunId, c)
                _ = try await c.query("""
                    UPDATE human_input_forms SET status = 'expired'
                    WHERE workflow_run_id = \(workflowRunId) AND status = 'waiting'
                    """, logger: self.logger)
                let stopped = try await c.query("""
                    UPDATE workflow_runs SET status = 'stopped', error = \(error), finished_at = \(at)
                    WHERE id = \(workflowRunId) AND status = 'paused'
                    RETURNING id
                    """, logger: self.logger)
                var didStop = false
                for try await _ in stopped { didStop = true }
                guard didStop else { return false }
                _ = try await c.query("""
                    UPDATE workflow_pauses SET resumed_at = \(at)
                    WHERE workflow_run_id = \(workflowRunId) AND resumed_at IS NULL
                    """, logger: self.logger)
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
