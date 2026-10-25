enum AgentConfigSchema {
    static let statements: [String] = [
        // Inline Agent v2: private identities, immutable Soul revisions and a draft pointer. A graph pins the exact
        // snapshot ID; editing the pointer cannot change a published graph or a paused execution.
        """
        CREATE TABLE IF NOT EXISTS inline_agents (
            id text PRIMARY KEY, doc_id text NOT NULL REFERENCES documents(id), node_id text NOT NULL,
            created_by text NOT NULL REFERENCES accounts(id), created_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE (doc_id, node_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS agent_config_snapshots (
            id text PRIMARY KEY, agent_id text NOT NULL REFERENCES inline_agents(id), binding_id text NOT NULL,
            doc_id text NOT NULL REFERENCES documents(id), node_id text NOT NULL,
            revision integer NOT NULL CHECK (revision > 0), soul jsonb NOT NULL CHECK (jsonb_typeof(soul) = 'object'),
            version_note text NOT NULL DEFAULT '', node_job jsonb NOT NULL DEFAULT '{}', display_version integer NOT NULL CHECK (display_version > 0),
            created_by text NOT NULL REFERENCES accounts(id), created_at timestamptz NOT NULL,
            UNIQUE (doc_id, node_id, revision), UNIQUE (id, doc_id, node_id, agent_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS workflow_agent_bindings (
            id text PRIMARY KEY, agent_id text NOT NULL REFERENCES inline_agents(id),
            doc_id text NOT NULL REFERENCES documents(id), node_id text NOT NULL, current_snapshot_id text NOT NULL,
            UNIQUE (doc_id, node_id),
            FOREIGN KEY (current_snapshot_id, doc_id, node_id, agent_id)
                REFERENCES agent_config_snapshots(id, doc_id, node_id, agent_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS workflow_agent_published_bindings (
            version_id text NOT NULL REFERENCES app_versions(id) ON DELETE CASCADE, node_id text NOT NULL,
            snapshot_id text NOT NULL REFERENCES agent_config_snapshots(id),
            PRIMARY KEY (version_id, node_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS agent_composer_receipts (
            doc_id text NOT NULL REFERENCES documents(id), user_id text NOT NULL REFERENCES accounts(id), request_id text NOT NULL,
            node_id text NOT NULL, digest text NOT NULL, response_json jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (doc_id, user_id, request_id)
        )
        """,
    ]
}
