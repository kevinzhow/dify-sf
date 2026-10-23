/// Database schema. Applied idempotently at startup (`PostgresStore.migrate`).
///
/// * `documents.rev` is the fencing token: it is incremented by every transaction that writes anything for
///   the document, and every write transaction first locks the row (`SELECT ... FOR UPDATE`) and checks that
///   `rev` is what the writer's in-memory state was built from.
/// * `ops` is the append-only op log (the source of truth). `(doc_id, seq)` and `(doc_id, client_id, cseq)`
///   are unique: the database itself refuses a second op for the same sequence slot or the same idempotency key.
/// * `rejections` and `client_state.high` make the per-client cseq high-water mark durable, so a retransmit of
///   a rejected op gets the original reason, also after a restart.
/// * `snapshots` are checkpoints of the materialised document; recovery = latest snapshot + replay of `ops`.
/// * `secrets` holds the secret environment variables (protocol 1.7), never part of a document; since 1.9 encrypted.
/// * Model providers (protocol 1.9): `provider_credentials`, `provider_settings`, `provider_model_credentials`,
///   `provider_models`, `provider_model_settings`, `default_models`.
/// * `comments` and `comment_replies` are canvas comments (additive, Dify's workflow comments): a resource beside the
///   document, not part of it (no ops, no log, no snapshots, no export, no undo).
/// * Apps (protocol 1.10, Dify's Studio): `apps` (one row per document; soft delete), `app_stars`, `app_imports`.
/// * App detail pages (protocol 1.11): `app_sites` (the Web App site, one per app), `apps.enable_site` / `enable_api`,
///   `app_api_keys` (Service API keys, sealed + SHA-256), `app_annotations`, `app_annotation_settings`, `app_jobs` (Dify's
///   annotation job states), `app_versions` (published versions: snapshots of the document).
/// * Accounts (protocol 1.8, Dify's community edition: one workspace per server): `accounts`, `members` (the workspace's
///   members and their roles), `sessions` (opaque bearer tokens, stored only as SHA-256), `invitations` (activation links)
///   and `client_accounts` (which account a client id belongs to); `password_resets` and, protocol 1.12, `email_changes`
///   (forgot-password and change-email tokens).
/// * Human input (protocol 1.16): `workflow_pauses` (the engine snapshot that resumes a paused run) and
///   `human_input_forms` (Dify's FormDefinition as rendered, its token, deadline and submission). `(workflow_run_id,
///   execution_id)` is the key of both: a loop's second round through the same node is another execution, so one form
///   belongs to exactly one execution and a re-pause cannot fork it.
/// * Runs (protocol 1.13): `workflow_node_executions` (Dify's table of the same name: node runs, single-step ones too, with
///   the document seq they ran at) and, protocol 1.14, `workflow_runs` (whole draft runs). Never ops: runs do not change
///   the document.
public enum Schema {
    public static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS documents (
            id          text        PRIMARY KEY,
            rev         bigint      NOT NULL DEFAULT 0,
            head        bigint      NOT NULL DEFAULT 0,
            created_at  timestamptz NOT NULL DEFAULT now()
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS snapshots (
            doc_id  text   NOT NULL REFERENCES documents(id),
            seq     bigint NOT NULL,
            state   jsonb  NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (doc_id, seq)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS ops (
            doc_id       text   NOT NULL REFERENCES documents(id),
            seq          bigint NOT NULL,
            client_id    text   NOT NULL,
            cseq         bigint NOT NULL,
            base         bigint NOT NULL,
            op           jsonb  NOT NULL,
            fp           bigint NOT NULL DEFAULT 0,
            committed_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (doc_id, seq),
            UNIQUE (doc_id, client_id, cseq)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS rejections (
            doc_id    text   NOT NULL REFERENCES documents(id),
            client_id text   NOT NULL,
            cseq      bigint NOT NULL,
            reason    jsonb  NOT NULL,
            fp        bigint NOT NULL DEFAULT 0,
            PRIMARY KEY (doc_id, client_id, cseq)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS client_state (
            doc_id    text   NOT NULL REFERENCES documents(id),
            client_id text   NOT NULL,
            high      bigint NOT NULL,
            PRIMARY KEY (doc_id, client_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS clients (
            doc_id     text NOT NULL REFERENCES documents(id),
            client_id  text NOT NULL,
            name       text NOT NULL,
            updated_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (doc_id, client_id)
        )
        """,
        // Dify workflow-file parts outside the graph (app, features, variables, edge extras), kept for export.
        """
        CREATE TABLE IF NOT EXISTS doc_meta (
            doc_id     text  PRIMARY KEY REFERENCES documents(id),
            dsl        jsonb NOT NULL,
            updated_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        // Protocol 1.7: plaintext of secret environment variables, by opaque reference. Documents (ops, log, snapshots,
        // streams) carry only the reference and a mask. Rows are never deleted (a removed variable leaves its row).
        """
        CREATE TABLE IF NOT EXISTS secrets (
            doc_id     text NOT NULL REFERENCES documents(id),
            ref        text NOT NULL,
            value      text NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (doc_id, ref)
        )
        """,
        // Canvas comments (Dify's workflow_comments / workflow_comment_replies / workflow_comment_mentions). Authors, resolvers
        // and mentions are account ids since protocol 1.8 (client ids before; such old rows keep them and match no account).
        """
        CREATE TABLE IF NOT EXISTS comments (
            doc_id      text             NOT NULL REFERENCES documents(id),
            id          text             NOT NULL,
            position_x  double precision NOT NULL,
            position_y  double precision NOT NULL,
            content     text             NOT NULL,
            created_by  text             NOT NULL,
            created_at  timestamptz      NOT NULL DEFAULT now(),
            updated_at  timestamptz      NOT NULL DEFAULT now(),
            resolved    boolean          NOT NULL DEFAULT false,
            resolved_by text,
            resolved_at timestamptz,
            mentions    text[]           NOT NULL DEFAULT '{}',
            PRIMARY KEY (doc_id, id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS comment_replies (
            doc_id     text        NOT NULL,
            comment_id text        NOT NULL,
            id         text        NOT NULL,
            content    text        NOT NULL,
            created_by text        NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            mentions   text[]      NOT NULL DEFAULT '{}',
            PRIMARY KEY (doc_id, id),
            FOREIGN KEY (doc_id, comment_id) REFERENCES comments (doc_id, id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS comment_replies_by_comment ON comment_replies (doc_id, comment_id, created_at)",
        // Protocol 1.8: accounts (Dify's `accounts` / `tenant_account_joins`). Emails are unique ignoring case; the password is
        // Dify's scheme (PBKDF2-HMAC-SHA256, base64), NULL until an invited account is activated.
        """
        CREATE TABLE IF NOT EXISTS accounts (
            id                 text        PRIMARY KEY,
            email              text        NOT NULL,
            name               text        NOT NULL,
            avatar_url         text,
            password_hash      text,
            password_salt      text,
            status             text        NOT NULL,
            interface_language text,
            timezone           text,
            created_at         timestamptz NOT NULL DEFAULT now(),
            last_login_at      timestamptz
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS accounts_email ON accounts (lower(email))",
        // The one workspace's members. At most one owner (the partial unique index).
        """
        CREATE TABLE IF NOT EXISTS members (
            account_id text        PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
            role       text        NOT NULL,
            invited_by text,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS members_one_owner ON members (role) WHERE role = 'owner'",
        // Bearer tokens (access and refresh), by SHA-256 of the token. `session_id` groups every token of one sign-in (also
        // across refreshes): logout revokes them all.
        """
        CREATE TABLE IF NOT EXISTS sessions (
            token_hash text        PRIMARY KEY,
            account_id text        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            session_id text        NOT NULL,
            kind       text        NOT NULL,
            expires_at timestamptz NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        "CREATE INDEX IF NOT EXISTS sessions_by_session ON sessions (session_id)",
        "CREATE INDEX IF NOT EXISTS sessions_by_account ON sessions (account_id)",
        """
        CREATE TABLE IF NOT EXISTS invitations (
            token_hash text        PRIMARY KEY,
            account_id text        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            email      text        NOT NULL,
            role       text        NOT NULL,
            invited_by text        NOT NULL,
            expires_at timestamptz NOT NULL,
            used_at    timestamptz,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        // Forgot password (Dify's `reset_password:token:*` in Redis) and the admins' reset links, by SHA-256 of the token.
        // `phase`: `verify` (an email code was sent; `code_hash` = SHA-256 of token and code), `reset` (the code was right),
        // `link` (an admin's reset link). `account_id` is NULL for an email without an account (Dify answers alike).
        """
        CREATE TABLE IF NOT EXISTS password_resets (
            token_hash text        PRIMARY KEY,
            account_id text        REFERENCES accounts(id) ON DELETE CASCADE,
            email      text        NOT NULL,
            code_hash  text,
            phase      text        NOT NULL,
            created_by text,
            expires_at timestamptz NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        "CREATE INDEX IF NOT EXISTS password_resets_by_email ON password_resets (lower(email))",
        "CREATE INDEX IF NOT EXISTS password_resets_by_account ON password_resets (account_id)",
        // Protocol 1.12: changing the account's email (Dify's `change_email:token:*` in Redis), by SHA-256 of the token. One
        // current token per account (a new one replaces the others). `phase`: `old_email` / `new_email` (a code went to that
        // address; `code_hash` = SHA-256 of token and code) and `old_email_verified` / `new_email_verified` (its code was
        // right). `email` is the address the code went to, `old_email` the account's address when the change began.
        """
        CREATE TABLE IF NOT EXISTS email_changes (
            token_hash text        PRIMARY KEY,
            account_id text        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            email      text        NOT NULL,
            old_email  text        NOT NULL,
            code_hash  text,
            phase      text        NOT NULL,
            expires_at timestamptz NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        "CREATE INDEX IF NOT EXISTS email_changes_by_account ON email_changes (account_id)",
        // A client id belongs to the account that obtained it (POST /clients) or used it first; ops under it from any other
        // account are refused (protocol 1.8). Never changes once written.
        """
        CREATE TABLE IF NOT EXISTS client_accounts (
            doc_id     text        NOT NULL,
            client_id  text        NOT NULL,
            account_id text        NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (doc_id, client_id)
        )
        """,
        // Protocol 1.9: secrets are stored encrypted (`SecretCipher`, the server's COLLAB_SECRETS_KEY). `sealed` marks rows written
        // that way; rows of older servers (plaintext) are sealed at startup once a key is configured (`sealLegacySecrets`).
        "ALTER TABLE secrets ADD COLUMN IF NOT EXISTS sealed boolean NOT NULL DEFAULT false",
        // Model providers (protocol 1.9; Dify's provider_credentials, providers, provider_model_credentials, provider_models,
        // provider_model_settings, tenant_default_models, without tenant columns: one workspace). `encrypted_config` is the whole
        // credential JSON sealed with the server's secrets key. A provider has a `provider_settings` row while it has
        // credentials (Dify's custom `providers` row); its `current_credential_id` may be NULL (the current one was deleted).
        """
        CREATE TABLE IF NOT EXISTS provider_credentials (
            id               text        PRIMARY KEY,
            provider         text        NOT NULL,
            name             text        NOT NULL,
            encrypted_config text        NOT NULL,
            created_by       text,
            created_at       timestamptz NOT NULL DEFAULT now(),
            updated_at       timestamptz NOT NULL DEFAULT now(),
            UNIQUE (provider, name)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_settings (
            provider              text        PRIMARY KEY,
            current_credential_id text,
            updated_at            timestamptz NOT NULL DEFAULT now()
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_model_credentials (
            id               text        PRIMARY KEY,
            provider         text        NOT NULL,
            model            text        NOT NULL,
            model_type       text        NOT NULL,
            name             text        NOT NULL,
            encrypted_config text        NOT NULL,
            created_by       text,
            created_at       timestamptz NOT NULL DEFAULT now(),
            updated_at       timestamptz NOT NULL DEFAULT now(),
            UNIQUE (provider, model, model_type, name)
        )
        """,
        // Custom models in the model list, with their current credential (Dify's provider_models).
        """
        CREATE TABLE IF NOT EXISTS provider_models (
            provider              text        NOT NULL,
            model                 text        NOT NULL,
            model_type            text        NOT NULL,
            current_credential_id text,
            created_at            timestamptz NOT NULL DEFAULT now(),
            updated_at            timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (provider, model, model_type)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_model_settings (
            provider   text        NOT NULL,
            model      text        NOT NULL,
            model_type text        NOT NULL,
            enabled    boolean     NOT NULL,
            updated_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (provider, model, model_type)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS default_models (
            model_type text        PRIMARY KEY,
            provider   text        NOT NULL,
            model      text        NOT NULL,
            updated_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        // Protocol 1.10: apps (Dify's `apps`, Studio). One row per document, created with it (documents of older servers get
        // theirs from `PostgresStore.backfillApps` at startup). The source of truth for the app's name, description and
        // icon. `deleted_at`: soft delete (the document then answers `404 app_deleted`). "Last modified" is
        // GREATEST(apps.updated_at, documents.updated_at): commits bump the document's (the deviation from Dify's rule).
        "ALTER TABLE documents ADD COLUMN IF NOT EXISTS updated_at timestamptz",
        """
        CREATE TABLE IF NOT EXISTS apps (
            doc_id                  text        PRIMARY KEY REFERENCES documents(id),
            name                    text        NOT NULL,
            description             text        NOT NULL DEFAULT '',
            mode                    text        NOT NULL,
            icon_type               text,
            icon                    text,
            icon_background         text,
            use_icon_as_answer_icon boolean     NOT NULL DEFAULT false,
            max_active_requests     integer,
            created_by              text,
            created_at              timestamptz NOT NULL DEFAULT now(),
            updated_by              text,
            updated_at              timestamptz NOT NULL DEFAULT now(),
            deleted_at              timestamptz
        )
        """,
        "CREATE INDEX IF NOT EXISTS apps_live_by_created ON apps (created_at) WHERE deleted_at IS NULL",
        "CREATE INDEX IF NOT EXISTS apps_by_creator ON apps (created_by)",
        // Stars per account (Dify's `app_stars`, without the tenant).
        """
        CREATE TABLE IF NOT EXISTS app_stars (
            account_id text        NOT NULL,
            doc_id     text        NOT NULL REFERENCES documents(id),
            created_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (account_id, doc_id)
        )
        """,
        // DSL imports waiting for the confirmation of their version (Dify keeps them 10 minutes in Redis).
        """
        CREATE TABLE IF NOT EXISTS app_imports (
            id         text        PRIMARY KEY,
            account_id text        NOT NULL,
            yaml       text        NOT NULL,
            overrides  jsonb       NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        // Protocol 1.11: the Web App site of an app (Dify's `sites`), one row per app, written with the app row (older apps get
        // theirs from `PostgresStore.backfillSites` at startup). `code` is the Web App URL's last segment (16 letters and
        // digits, Dify's `Site.generate_code(16)`); the access-token reset draws a new one.
        """
        CREATE TABLE IF NOT EXISTS app_sites (
            doc_id                    text        PRIMARY KEY REFERENCES documents(id),
            code                      text        NOT NULL UNIQUE,
            title                     text        NOT NULL,
            icon_type                 text,
            icon                      text,
            icon_background           text,
            description               text,
            default_language          text        NOT NULL,
            chat_color_theme          text,
            chat_color_theme_inverted boolean     NOT NULL DEFAULT false,
            customize_domain          text,
            copyright                 text,
            privacy_policy            text,
            input_placeholder         text,
            custom_disclaimer         text        NOT NULL DEFAULT '',
            customize_token_strategy  text        NOT NULL DEFAULT 'not_allow',
            prompt_public             boolean     NOT NULL DEFAULT false,
            show_workflow_steps       boolean     NOT NULL DEFAULT true,
            use_icon_as_answer_icon   boolean     NOT NULL DEFAULT false,
            created_by                text,
            created_at                timestamptz NOT NULL DEFAULT now(),
            updated_by                text,
            updated_at                timestamptz NOT NULL DEFAULT now()
        )
        """,
        // The Web App and Service API switches (Dify's `apps.enable_site` / `enable_api`; on for workflow and chatflow apps,
        // as Dify's templates and DSL import). `last_version_number`: the per-app version counter (Dify's
        // `workflow_version_counters`; numbers are never reused).
        "ALTER TABLE apps ADD COLUMN IF NOT EXISTS enable_site boolean NOT NULL DEFAULT true",
        "ALTER TABLE apps ADD COLUMN IF NOT EXISTS enable_api boolean NOT NULL DEFAULT true",
        "ALTER TABLE apps ADD COLUMN IF NOT EXISTS last_version_number integer NOT NULL DEFAULT 0",
        // Service API keys (Dify's `api_tokens` of type `app`). Dify stores the token in plaintext; dify-sf stores it sealed
        // with the server's secrets key (`sealed_token`, context `app_api_key:<doc>:<id>`) and its SHA-256 (`token_hash`, hex)
        // for the runtime's lookup.
        """
        CREATE TABLE IF NOT EXISTS app_api_keys (
            id           text        PRIMARY KEY,
            doc_id       text        NOT NULL REFERENCES documents(id),
            token_hash   text        NOT NULL UNIQUE,
            sealed_token text        NOT NULL,
            last_used_at timestamptz,
            created_by   text,
            created_at   timestamptz NOT NULL DEFAULT clock_timestamp()
        )
        """,
        "CREATE INDEX IF NOT EXISTS app_api_keys_by_doc ON app_api_keys (doc_id, created_at)",
        // Annotations (Dify's `message_annotations`; `content` is the answer) and the Annotation Reply setting (Dify's
        // `app_annotation_settings` with the embedding model inline instead of a collection binding).
        """
        CREATE TABLE IF NOT EXISTS app_annotations (
            id         text        PRIMARY KEY,
            doc_id     text        NOT NULL REFERENCES documents(id),
            question   text        NOT NULL,
            content    text        NOT NULL,
            message_id text,
            hit_count  integer     NOT NULL DEFAULT 0,
            account_id text,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
        )
        """,
        "CREATE INDEX IF NOT EXISTS app_annotations_by_doc ON app_annotations (doc_id, created_at DESC, id DESC)",
        """
        CREATE TABLE IF NOT EXISTS app_annotation_settings (
            doc_id                  text             PRIMARY KEY REFERENCES documents(id),
            id                      text             NOT NULL,
            score_threshold         double precision NOT NULL,
            embedding_provider_name text             NOT NULL,
            embedding_model_name    text             NOT NULL,
            created_by              text,
            updated_by              text,
            updated_at              timestamptz      NOT NULL DEFAULT now()
        )
        """,
        // Dify's annotation job states (Redis keys with a 10-minute expiry): the batch import and the reply enable / disable
        // jobs. dify-sf runs them synchronously, so they are `completed` when created.
        """
        CREATE TABLE IF NOT EXISTS app_jobs (
            id         text        PRIMARY KEY,
            doc_id     text        NOT NULL,
            kind       text        NOT NULL,
            status     text        NOT NULL,
            error      text        NOT NULL DEFAULT '',
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        // Published versions (Dify's `workflows` rows with a version other than `draft`): the document at `seq` (`state`, as
        // `snapshots.state`) and its Dify metadata with the app row (`dsl`, as `doc_meta.dsl`). Secret variables keep their
        // references (their `secrets` rows are never deleted). The newest is the app's published version.
        """
        CREATE TABLE IF NOT EXISTS app_versions (
            id             text        PRIMARY KEY,
            doc_id         text        NOT NULL REFERENCES documents(id),
            version_number integer     NOT NULL,
            version        text        NOT NULL,
            seq            bigint      NOT NULL,
            state          jsonb       NOT NULL,
            dsl            jsonb       NOT NULL,
            hash           text        NOT NULL,
            marked_name    text        NOT NULL DEFAULT '',
            marked_comment text        NOT NULL DEFAULT '',
            created_by     text,
            created_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_by     text,
            updated_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
            UNIQUE (doc_id, version_number)
        )
        """,
        "CREATE INDEX IF NOT EXISTS app_versions_by_doc ON app_versions (doc_id, created_at DESC, id DESC)",
        // Messages of an app's conversations (the minimal part of Dify's `messages` the console needs to address one). Filled
        // by a future runtime; nothing writes it yet (tests seed it directly).
        """
        CREATE TABLE IF NOT EXISTS app_messages (
            id              uuid        PRIMARY KEY,
            doc_id          text        NOT NULL REFERENCES documents(id),
            conversation_id uuid        NOT NULL,
            created_at      timestamptz NOT NULL DEFAULT clock_timestamp()
        )
        """,
        "CREATE INDEX IF NOT EXISTS app_messages_by_doc ON app_messages (doc_id, created_at)",
        "CREATE INDEX IF NOT EXISTS app_messages_by_conversation ON app_messages (conversation_id, created_at)",
        // Likes and dislikes of messages (Dify's `message_feedbacks`): `from_source` `user` (an end user of the Web App or
        // Service API, `from_end_user_id`) or `admin` (a member in the console's logs, `from_account_id`; at most one per
        // message). The runtime's feedback statistics and a message's `feedbacks` read it.
        """
        CREATE TABLE IF NOT EXISTS app_message_feedbacks (
            id               uuid        PRIMARY KEY,
            doc_id           text        NOT NULL REFERENCES documents(id),
            conversation_id  uuid        NOT NULL,
            message_id       uuid        NOT NULL REFERENCES app_messages(id) ON DELETE CASCADE,
            rating           text        NOT NULL CHECK (rating IN ('like', 'dislike')),
            content          text,
            from_source      text        NOT NULL CHECK (from_source IN ('user', 'admin')),
            from_account_id  text,
            from_end_user_id text,
            created_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
            updated_at       timestamptz NOT NULL DEFAULT clock_timestamp()
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS app_message_feedbacks_one_admin ON app_message_feedbacks (message_id) WHERE from_source = 'admin'",
        "CREATE INDEX IF NOT EXISTS app_message_feedbacks_by_doc ON app_message_feedbacks (doc_id)",
        "CREATE INDEX IF NOT EXISTS app_message_feedbacks_by_message ON app_message_feedbacks (message_id, from_source)",
        """
        CREATE INDEX IF NOT EXISTS app_message_feedbacks_by_conversation
            ON app_message_feedbacks (conversation_id, from_source, rating)
        """,
        // Protocol 1.13: node executions (Dify's `workflow_node_executions`). `doc_seq` = the document seq the run read (one
        // consistent snapshot). JSON members are text, not jsonb, so their key order (Python's dict order) survives.
        """
        CREATE TABLE IF NOT EXISTS workflow_node_executions (
            id                  text             PRIMARY KEY,
            doc_id              text             NOT NULL REFERENCES documents(id),
            workflow_run_id     text,
            triggered_from      text             NOT NULL,
            doc_seq             bigint           NOT NULL,
            run_index           integer          NOT NULL,
            predecessor_node_id text,
            node_id             text             NOT NULL,
            node_type           text             NOT NULL,
            title               text             NOT NULL,
            inputs              text,
            process_data        text,
            outputs             text,
            status              text             NOT NULL,
            error               text,
            elapsed_time        double precision NOT NULL,
            execution_metadata  text,
            created_by          text,
            created_at          timestamptz      NOT NULL,
            finished_at         timestamptz
        )
        """,
        "CREATE INDEX IF NOT EXISTS workflow_node_executions_last ON workflow_node_executions (doc_id, node_id, created_at DESC)",
        // Protocol 1.14: workflow runs (Dify's `workflow_runs`; draft runs = `triggered_from` `debugging`). `doc_seq` = the
        // document seq the run read; `graph` = the Dify graph it ran (JSON text, key order kept). Never ops.
        """
        CREATE TABLE IF NOT EXISTS workflow_runs (
            id               text             PRIMARY KEY,
            doc_id           text             NOT NULL REFERENCES documents(id),
            doc_seq          bigint           NOT NULL,
            workflow_id      text             NOT NULL,
            type             text             NOT NULL,
            triggered_from   text             NOT NULL,
            version          text             NOT NULL,
            graph            text             NOT NULL,
            inputs           text             NOT NULL,
            status           text             NOT NULL,
            outputs          text,
            error            text,
            elapsed_time     double precision NOT NULL DEFAULT 0,
            total_tokens     bigint           NOT NULL DEFAULT 0,
            total_steps      integer          NOT NULL DEFAULT 0,
            exceptions_count integer          NOT NULL DEFAULT 0,
            created_by       text,
            created_at       timestamptz      NOT NULL,
            finished_at      timestamptz
        )
        """,
        "CREATE INDEX IF NOT EXISTS workflow_runs_doc ON workflow_runs (doc_id, triggered_from, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS workflow_node_executions_run ON workflow_node_executions (workflow_run_id, created_at)",
        // Databases created before the idempotency-key fingerprint existed.
        "ALTER TABLE ops ADD COLUMN IF NOT EXISTS fp bigint NOT NULL DEFAULT 0",
        "ALTER TABLE rejections ADD COLUMN IF NOT EXISTS fp bigint NOT NULL DEFAULT 0",
        // Protocol 1.14: draft variables (Dify's `workflow_draft_variables`): per account and app, the latest value of each
        // node output, system variable and conversation variable of debug runs, for the variable inspect panel. Beside the
        // document, never ops; `value` is JSON text (key order kept); `doc_seq` = the document seq of the run that produced it.
        """
        CREATE TABLE IF NOT EXISTS workflow_draft_variables (
            id                text        PRIMARY KEY,
            doc_id            text        NOT NULL REFERENCES documents(id),
            user_id           text        NOT NULL,
            node_id           text        NOT NULL,
            name              text        NOT NULL,
            description       text        NOT NULL DEFAULT '',
            value_type        text        NOT NULL,
            value             text        NOT NULL,
            visible           boolean     NOT NULL,
            editable          boolean     NOT NULL,
            node_execution_id text,
            doc_seq           bigint,
            last_edited_at    timestamptz,
            created_at        timestamptz NOT NULL,
            updated_at        timestamptz NOT NULL,
            UNIQUE (doc_id, user_id, node_id, name)
        )
        """,
        // Protocol 1.16: a run waiting for human input. The pause is the whole run's: one snapshot per generation of a
        // run, so resuming is claimed once per generation rather than once per node execution — two nodes waiting in the
        // same pause must not each start an engine, and a node that pauses again after a resume is another generation
        // rather than a duplicate key. `snapshot` is the JSON text the engine wrote (key order, number kinds and segment
        // types kept). `execution_ids` lists the node executions the snapshot has to decide on: the resume consumes exactly
        // those forms, so a submission that arrives later is left for the next pause. `resume_requested` means one of this
        // run's forms is terminal and no resume has consumed it yet; `resumed_at` is the claim.
        """
        CREATE TABLE IF NOT EXISTS workflow_pauses (
            workflow_run_id text             NOT NULL REFERENCES workflow_runs(id),
            generation      integer          NOT NULL,
            doc_id          text             NOT NULL REFERENCES documents(id),
            node_id         text             NOT NULL DEFAULT '',
            snapshot        text             NOT NULL,
            execution_ids   text[]           NOT NULL DEFAULT '{}',
            total_tokens    bigint           NOT NULL DEFAULT 0,
            total_steps     integer          NOT NULL DEFAULT 0,
            elapsed_time    double precision NOT NULL DEFAULT 0,
            outputs         text             NOT NULL DEFAULT '{}',
            created_at      timestamptz      NOT NULL,
            resumed_at      timestamptz,
            resume_requested boolean         NOT NULL DEFAULT false,
            PRIMARY KEY (workflow_run_id, generation)
        )
        """,
        // Dify's WorkflowPause is zero-or-one per run (UniqueConstraint workflow_run_id): a pause that is not resumed yet
        // is the run's only one, so two generations can never be claimed at once.
        // Protocol 1.16: the run's outputs so far, as the live `workflow_paused` frame reports them; a reconnect rebuilds
        // that frame from the record, and Dify's pause record carries the same state.
        "ALTER TABLE workflow_pauses ADD COLUMN IF NOT EXISTS outputs text NOT NULL DEFAULT '{}'",
        "CREATE UNIQUE INDEX IF NOT EXISTS workflow_pauses_one_open ON workflow_pauses (workflow_run_id) WHERE resumed_at IS NULL",
        // Protocol 1.16: the form a human answers. `(workflow_run_id, execution_id)` is its unique key: a node execution
        // has one form, and a later pause of the same run adopts a form that is still waiting instead of minting a new
        // token (the recipient keeps the link they were given). `generation` names the pause the form currently belongs
        // to. `form_content`, `inputs`, `user_actions`, `actions`, `default_values` and `resolved_default_values` are
        // Dify's FormDefinition members as JSON text (array order kept); `rendered_content` is the rendered markdown;
        // `expiration_time` is Dify's Unix seconds. Statuses: waiting, submitted, expired (the form's deadline passed),
        // timed_out (the node's own deadline, which fails that node rather than the whole run). `recipient_type` is Dify's
        // delivery surface (console, backstage, webapp); the console API answers only its own, everything else 404s.
        """
        CREATE TABLE IF NOT EXISTS human_input_forms (
            id                      text        PRIMARY KEY,
            workflow_run_id         text        NOT NULL REFERENCES workflow_runs(id),
            generation              integer     NOT NULL,
            execution_id            text        NOT NULL,
            doc_id                  text        NOT NULL REFERENCES documents(id),
            node_id                 text        NOT NULL,
            node_title              text        NOT NULL DEFAULT '',
            token                   text        NOT NULL UNIQUE,
            form_content            text        NOT NULL,
            inputs                  text        NOT NULL,
            user_actions            text        NOT NULL,
            rendered_content        text        NOT NULL,
            default_values          text,
            resolved_default_values text,
            actions                 text        NOT NULL,
            display_in_ui           boolean     NOT NULL,
            expiration_time         bigint,
            status                  text        NOT NULL,
            submitted_inputs        text,
            submitted_action        text,
            submitted_by            text,
            submitted_at            timestamptz,
            consumed_at             timestamptz,
            created_at              timestamptz NOT NULL,
            recipient_type          text        NOT NULL DEFAULT 'console',
            UNIQUE (workflow_run_id, execution_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS human_input_forms_run ON human_input_forms (workflow_run_id, generation, created_at)",
        // Protocol 1.17: only ready files may be referenced; paths are server-generated, never document fields.
        """
        CREATE TABLE IF NOT EXISTS upload_files (
            id text PRIMARY KEY,
            workspace_id text NOT NULL,
            storage_key text NOT NULL UNIQUE,
            name text NOT NULL,
            size bigint NOT NULL CHECK (size >= 0),
            extension text NOT NULL,
            mime_type text NOT NULL,
            created_by_role text NOT NULL DEFAULT 'account',
            created_by text NOT NULL REFERENCES accounts(id),
            created_at timestamptz NOT NULL,
            sha256 text NOT NULL,
            source_url text,
            ready boolean NOT NULL DEFAULT false,
            deleting boolean NOT NULL DEFAULT false
        )
        """,
        "ALTER TABLE upload_files ADD COLUMN IF NOT EXISTS deleting boolean NOT NULL DEFAULT false",
        "CREATE INDEX IF NOT EXISTS upload_files_workspace ON upload_files (workspace_id, created_at)",
        // Protocol 1.16: an email recipient of a form (Dify's `human_input_form_recipient`). Its `token` is the one the
        // link carries, so a link works for the person it was mailed to without a console account; `mailed_at` makes the
        // delivery idempotent (a restart, or a pause that adopts the same waiting form, does not mail twice).
        """
        CREATE TABLE IF NOT EXISTS human_input_form_recipients (
            token           text        PRIMARY KEY,
            form_id         text        NOT NULL REFERENCES human_input_forms(id),
            workflow_run_id text        NOT NULL,
            method_index    integer     NOT NULL,
            recipient_type  text        NOT NULL,
            reference_id    text,
            email           text        NOT NULL,
            mailed_at       timestamptz,
            used_at         timestamptz,
            created_at      timestamptz NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS human_input_form_recipients_form ON human_input_form_recipients (form_id)",
        // Protocol 1.16: a **delivery-test** form (Dify's `HumanInputFormKind.DELIVERY_TEST`) belongs to no run: the panel's
        // test mail opens and validates a form, and answering it never claims or resumes a workflow.
        "ALTER TABLE human_input_forms ADD COLUMN IF NOT EXISTS form_kind text NOT NULL DEFAULT 'runtime'",
        "ALTER TABLE human_input_forms ALTER COLUMN workflow_run_id DROP NOT NULL",
        "ALTER TABLE human_input_form_recipients ALTER COLUMN workflow_run_id DROP NOT NULL",
        // One row per address and form: a pause that adopts a waiting form must keep the links it already handed out.
        "CREATE UNIQUE INDEX IF NOT EXISTS human_input_form_recipients_address ON human_input_form_recipients (form_id, email)",
    ] + ChatSchema.statements
}
