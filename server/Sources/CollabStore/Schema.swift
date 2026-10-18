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
/// * `secrets` holds the plaintext of secret environment variables (protocol 1.7), never part of a document.
/// * `comments` and `comment_replies` are canvas comments (additive, Dify's workflow comments): a resource beside the
///   document, not part of it (no ops, no log, no snapshots, no export, no undo).
/// * Accounts (protocol 1.8, Dify's community edition: one workspace per server): `accounts`, `members` (the workspace's
///   members and their roles), `sessions` (opaque bearer tokens, stored only as SHA-256), `invitations` (activation links)
///   and `client_accounts` (which account a client id belongs to).
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
        // Databases created before the idempotency-key fingerprint existed.
        "ALTER TABLE ops ADD COLUMN IF NOT EXISTS fp bigint NOT NULL DEFAULT 0",
        "ALTER TABLE rejections ADD COLUMN IF NOT EXISTS fp bigint NOT NULL DEFAULT 0",
    ]
}
