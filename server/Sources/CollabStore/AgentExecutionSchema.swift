// Durable ownership and acknowledgement outbox for inline Agent v2. These are runtime records, never graph ops.
enum AgentExecutionSchema {
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS agent_node_sessions (
            execution_id text PRIMARY KEY, workflow_run_id text NOT NULL REFERENCES workflow_runs(id),
            doc_id text NOT NULL REFERENCES documents(id), node_id text NOT NULL,
            agent_id text NOT NULL, config_snapshot_id text NOT NULL REFERENCES agent_config_snapshots(id),
            owner_id text NOT NULL, generation bigint NOT NULL CHECK (generation > 0),
            lease_until timestamptz NOT NULL, status text NOT NULL,
            output_attempt integer NOT NULL DEFAULT 0, resume_sequence integer NOT NULL DEFAULT 0,
            operation_id text, agent_run_id text, result_event_id bigint,
            question_id text, form_id text REFERENCES human_input_forms(id),
            continuation jsonb, prepared_result jsonb, usage jsonb NOT NULL DEFAULT '{}',
            accepted_outputs jsonb, error_type text, created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            FOREIGN KEY (config_snapshot_id, doc_id, node_id, agent_id)
                REFERENCES agent_config_snapshots(id, doc_id, node_id, agent_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS agent_event_records (
            ordinal bigserial PRIMARY KEY,
            execution_id text NOT NULL REFERENCES agent_node_sessions(execution_id) ON DELETE CASCADE,
            operation_id text NOT NULL, event_key text NOT NULL, record text NOT NULL, log text,
            created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(execution_id, event_key)
        )
        """,
        "CREATE INDEX IF NOT EXISTS agent_event_records_execution ON agent_event_records(execution_id, ordinal)",
        // Upgrade the earlier bounded JSON archive once; durable rows survive result ACK and process restart.
        """
        INSERT INTO agent_event_records(execution_id, operation_id, event_key, record, log)
        SELECT s.execution_id, coalesce(s.operation_id, s.execution_id || ':legacy'), e.value->>'event_key',
            jsonb_build_array(e.value)::text,
            (SELECT jsonb_build_array(l.value)::text FROM jsonb_array_elements(coalesce(s.usage->'agent_log','[]'::jsonb)) l(value)
                WHERE l.value->>'message_id' = e.value->>'event_key' LIMIT 1)
        FROM agent_node_sessions s, LATERAL jsonb_array_elements(coalesce(s.usage->'agent_events','[]'::jsonb)) WITH ORDINALITY e(value, position)
        WHERE s.usage ? 'agent_events' AND e.value->>'event_key' IS NOT NULL
        ORDER BY s.execution_id, e.position
        ON CONFLICT(execution_id, event_key) DO NOTHING
        """,
        "UPDATE agent_node_sessions SET usage = usage - 'agent_events' - 'agent_log' WHERE usage ? 'agent_events' OR usage ? 'agent_log'",
        "CREATE INDEX IF NOT EXISTS agent_node_sessions_recovery ON agent_node_sessions(status, lease_until)",
        """
        CREATE TABLE IF NOT EXISTS agent_operations (
            id text PRIMARY KEY, execution_id text NOT NULL REFERENCES agent_node_sessions(execution_id),
            generation bigint NOT NULL, output_attempt integer NOT NULL, resume_sequence integer NOT NULL,
            request_digest text NOT NULL, token_hash text NOT NULL, status text NOT NULL,
            agent_run_id text, result_event_id bigint, result_json jsonb,
            created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE (execution_id, output_attempt, resume_sequence)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS agent_runtime_outbox (
            id text PRIMARY KEY, execution_id text NOT NULL, workflow_run_id text NOT NULL,
            generation bigint NOT NULL, kind text NOT NULL CHECK(kind IN ('ack', 'cancel', 'cleanup')),
            agent_run_id text, result_event_id bigint, attempts integer NOT NULL DEFAULT 0,
            next_at timestamptz NOT NULL DEFAULT now(), done_at timestamptz,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        "CREATE INDEX IF NOT EXISTS agent_runtime_outbox_pending ON agent_runtime_outbox(next_at) WHERE done_at IS NULL",
        // Ordinary human-input forms keep the empty question identity and the same external SSE/API fields.
        "ALTER TABLE human_input_forms ADD COLUMN IF NOT EXISTS question_id text NOT NULL DEFAULT ''",
        "ALTER TABLE human_input_forms DROP CONSTRAINT IF EXISTS human_input_forms_workflow_run_id_execution_id_key",
        "CREATE UNIQUE INDEX IF NOT EXISTS human_input_forms_question ON human_input_forms(workflow_run_id, execution_id, question_id)",
        """
        CREATE TABLE IF NOT EXISTS agent_file_uploads (
            id text PRIMARY KEY, execution_id text NOT NULL REFERENCES agent_node_sessions(execution_id),
            operation_id text NOT NULL REFERENCES agent_operations(id), generation bigint NOT NULL,
            token_hash text NOT NULL, filename text NOT NULL, mime_type text NOT NULL,
            size bigint NOT NULL CHECK(size >= 0), state text NOT NULL DEFAULT 'pending',
            expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
            file_id text REFERENCES upload_files(id), sha256 text
        )
        """,
    ]
}
