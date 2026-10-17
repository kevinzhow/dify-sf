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
        // Databases created before the idempotency-key fingerprint existed.
        "ALTER TABLE ops ADD COLUMN IF NOT EXISTS fp bigint NOT NULL DEFAULT 0",
        "ALTER TABLE rejections ADD COLUMN IF NOT EXISTS fp bigint NOT NULL DEFAULT 0",
    ]
}
