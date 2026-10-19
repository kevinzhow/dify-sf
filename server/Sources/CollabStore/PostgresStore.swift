import CollabCore
import Foundation
import Logging
import PostgresNIO

public enum StoreError: Error, Sendable {
    /// The row-lock/revision check failed: another writer changed the document since this state was built.
    case revisionMismatch
    case corrupt(String)
    /// The transaction definitely did NOT commit (it failed or was rolled back before COMMIT was sent).
    case notCommitted(String)
    /// COMMIT was sent but its result is unknown (connection lost). The batch may or may not be durable.
    case uncertain(String)
    /// A read did not finish in time (the connection is probably dead).
    case timedOut
}

/// Result of loading a document's durable state.
public struct LoadedDocument: Sendable {
    public var snapshot: Snapshot
    public var tail: [LogEntry]
    public var rev: Int
    public var head: Int
}

/// Postgres persistence for the collaboration kernel (no ORM: plain SQL through postgres-nio).
public struct PostgresStore: Sendable {
    public let client: PostgresClient
    public let logger: Logger
    /// Upper bound for any single database operation as seen by the caller. A connection that silently dies (half-open
    /// TCP) would otherwise make a query wait forever, and with it the document's sequencer.
    public let operationTimeout: Duration
    /// Encrypts secrets at rest (protocol 1.9); nil = the server has no secrets key: storing a secret throws
    /// `SecretsKeyMissing` (nothing is ever stored in plaintext), reading sealed rows yields nothing.
    public let cipher: (any SecretCipher)?

    public init(client: PostgresClient, logger: Logger, operationTimeout: Duration = .seconds(20), cipher: (any SecretCipher)? = nil) {
        self.client = client
        self.logger = logger
        self.operationTimeout = operationTimeout
        self.cipher = cipher
    }

    /// The sealed form of a secret environment variable (context: document and reference).
    func sealSecret(doc: String, ref: String, _ value: String) throws -> String {
        guard let cipher else { throw SecretsKeyMissing() }
        return try cipher.seal(value, context: "secrets:\(doc):\(ref)")
    }

    /// The plaintext of a `secrets` row: sealed rows are opened (nil if that fails: wrong or missing key), rows written
    /// before 1.9 that were not sealed yet are plaintext.
    func openSecret(doc: String, ref: String, value: String, sealed: Bool) -> String? {
        guard sealed else { return value }
        guard let cipher else { return nil }
        do { return try cipher.open(value, context: "secrets:\(doc):\(ref)") } catch {
            logger.warning("secret \(ref) of \(doc) cannot be decrypted with the configured key")
            return nil
        }
    }

    /// Runs a database operation with the deadline above.
    func bounded<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        do { return try await withTimeout(operationTimeout, body) } catch is TimeoutError {
            throw StoreError.timedOut
        }
    }


    // MARK: - Public API (every operation is bounded by `operationTimeout`)

    /// Registers (or renames) the display name of a client id.
    public func setClientName(_ id: String, client c: ClientID, name: String) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO clients (doc_id, client_id, name) VALUES (\(id), \(c), \(name))
                ON CONFLICT (doc_id, client_id) DO UPDATE SET name = EXCLUDED.name, updated_at = now()
                """, logger: self.logger)
        }
    }

    /// client id -> display name for every client of the document that registered one.
    public func clientNames(_ id: String) async throws -> [ClientID: String] {
        try await bounded {
            var out: [ClientID: String] = [:]
            for try await (c, n) in try await self.client.query("SELECT client_id, name FROM clients WHERE doc_id = \(id)", logger: self.logger).decode((String, String).self) {
                out[c] = n
            }
            return out
        }
    }

    public func migrate() async throws { try await bounded { try await self.migrateImpl() } }
    public func ping() async throws { try await bounded { try await self.pingImpl() } }
    /// The Dify workflow-file parts outside the graph stored at import, if the document was imported.
    public func documentMetadata(_ id: String) async throws -> Value? {
        try await bounded {
            for try await (json,) in try await self.client.query("SELECT dsl::text FROM doc_meta WHERE doc_id = \(id)", logger: self.logger).decode((String,).self) {
                return try WireJSON.decode(Value.self, from: Data(json.utf8))
            }
            return nil
        }
    }

    /// Creates the document (seed state, optional Dify metadata, secrets of an imported file) in one transaction. Returns
    /// false, writing nothing, if it already existed.
    /// Protocol 1.10: the app row is inserted in the same transaction: `app`, or one derived from `metadata`
    /// (`NewApp.from`, name = the file's or the document id, creator unknown).
    public func createDocument(id: String, initial: Document, metadata: Value? = nil, secrets: [String: String] = [:],
                               app: NewApp? = nil) async throws -> Bool {
        let row = app ?? NewApp.from(metadata: metadata, fallbackName: id, createdBy: nil)
        return try await bounded { try await self.createDocumentImpl(id: id, initial: initial, metadata: metadata, secrets: secrets, app: row) }
    }

    /// Stores a secret environment variable under `ref` (protocol 1.7), encrypted (1.9; `SecretsKeyMissing` without a key).
    /// Idempotent for the same reference.
    public func storeSecret(_ id: String, ref: String, value: String) async throws {
        let sealed = try sealSecret(doc: id, ref: ref, value)
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO secrets (doc_id, ref, value, sealed) VALUES (\(id), \(ref), \(sealed), true) ON CONFLICT (doc_id, ref) DO NOTHING
                """, logger: self.logger)
        }
    }

    /// ref -> plaintext of every secret of the document (secrets that cannot be decrypted are left out).
    public func secrets(_ id: String) async throws -> [String: String] {
        try await bounded {
            var out: [String: String] = [:]
            let rows = try await self.client.query("SELECT ref, value, sealed FROM secrets WHERE doc_id = \(id)", logger: self.logger)
            for try await (r, v, sealed) in rows.decode((String, String, Bool).self) {
                if let plain = self.openSecret(doc: id, ref: r, value: v, sealed: sealed) { out[r] = plain }
            }
            return out
        }
    }

    /// Protocol 1.9 migration: encrypts the `secrets` rows that older servers stored in plaintext. Needs the key (no-op
    /// without one, answering how many rows are still plaintext). Idempotent; returns the number of rows sealed (or left).
    @discardableResult
    public func sealLegacySecrets() async throws -> (sealed: Int, plaintextLeft: Int) {
        try await bounded {
            guard self.cipher != nil else {
                for try await n in try await self.client.query("SELECT count(*)::bigint FROM secrets WHERE NOT sealed", logger: self.logger).decode(Int.self) {
                    return (0, n)
                }
                return (0, 0)
            }
            return try await self.client.withTransaction(logger: self.logger) { tx in
                var rows: [(String, String, String)] = []
                for try await row in try await tx.query("SELECT doc_id, ref, value FROM secrets WHERE NOT sealed FOR UPDATE", logger: self.logger)
                    .decode((String, String, String).self) { rows.append(row) }
                for (doc, ref, value) in rows {
                    let sealed = try self.sealSecret(doc: doc, ref: ref, value)
                    _ = try await tx.query("UPDATE secrets SET value = \(sealed), sealed = true WHERE doc_id = \(doc) AND ref = \(ref)", logger: self.logger)
                }
                return (rows.count, 0)
            }
        }
    }

    public func documentHead(_ id: String) async throws -> Int? { try await bounded { try await self.documentHeadImpl(id) } }
    /// The document row's revision (bumped by every commit), nil if unknown.
    public func documentRevision(_ id: String) async throws -> Int? {
        try await bounded {
            for try await rev in try await self.client.query("SELECT rev FROM documents WHERE id = \(id)", logger: self.logger).decode(Int.self) {
                return rev
            }
            return nil
        }
    }
    public func load(_ id: String) async throws -> LoadedDocument? { try await bounded { try await self.loadImpl(id) } }
    public func entries(_ id: String, after: Int, through: Int) async throws -> [LogEntry] {
        try await bounded { try await self.entriesImpl(id, after: after, through: through) }
    }
    public func clientHigh(_ id: String, client c: ClientID) async throws -> Int {
        try await bounded { try await self.clientHighImpl(id, client: c) }
    }
    public func knownOutcomes(_ id: String, client c: ClientID, range: ClosedRange<Int>?) async throws -> KnownOutcomes {
        try await bounded { try await self.knownOutcomesImpl(id, client: c, range: range) }
    }
    /// Whether the log has an op of type `t` (the wire discriminator) with `after < seq <= through`.
    public func logContainsOp(_ id: String, type t: String, after: Int, through: Int) async throws -> Bool {
        try await bounded { try await self.logContainsOpImpl(id, type: t, after: after, through: through) }
    }
    /// Whether the log has a commit that writes a document-level register (node `$app`, protocol 1.7) with
    /// `after < seq <= through`.
    public func logTouchesApp(_ id: String, after: Int, through: Int) async throws -> Bool {
        try await bounded { try await self.logTouchesAppImpl(id, after: after, through: through) }
    }
    public func committedMap(_ id: String, client c: ClientID, from: Int, through: Int) async throws -> [Int: Int] {
        try await bounded { try await self.committedMapImpl(id, client: c, from: from, through: through) }
    }

    // MARK: - Setup

    /// Idempotent. Serialised with an advisory lock so that several processes starting at once do not race
    /// inside `CREATE TABLE IF NOT EXISTS` (which is not safe against concurrent creators).
    func migrateImpl() async throws {
        try await client.withTransaction(logger: logger) { tx in
            _ = try await tx.query("SELECT pg_advisory_xact_lock(7318004)", logger: logger)
            for sql in Schema.statements {
                _ = try await tx.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            }
        }
    }

    func pingImpl() async throws {
        _ = try await client.query("SELECT 1", logger: logger)
    }

    // MARK: - Documents

    /// Creates the document with its seed state (snapshot at seq 0). Returns false if it already existed.
    func createDocumentImpl(id: String, initial: Document, metadata: Value? = nil, secrets: [String: String] = [:],
                            app: NewApp) async throws -> Bool {
        var sealedSecrets: [String: String] = [:]
        for (ref, value) in secrets { sealedSecrets[ref] = try sealSecret(doc: id, ref: ref, value) }
        let state = try WireJSON.encodeString(initial)
        let meta = try metadata.map { try WireJSON.encodeString($0) }
        return try await client.withTransaction(logger: logger) { c in
            let inserted = try await c.query("INSERT INTO documents (id) VALUES (\(id)) ON CONFLICT DO NOTHING RETURNING rev", logger: logger)
            var created = false
            for try await _ in inserted { created = true }
            if created {
                _ = try await c.query("INSERT INTO snapshots (doc_id, seq, state) VALUES (\(id), 0, \(state)::text::jsonb)", logger: logger)
                try await self.insertApp(c, id: id, app)
                if let meta {
                    _ = try await c.query("INSERT INTO doc_meta (doc_id, dsl) VALUES (\(id), \(meta)::text::jsonb)", logger: logger)
                }
                for (ref, value) in sealedSecrets.sorted(by: { $0.key < $1.key }) {
                    _ = try await c.query("INSERT INTO secrets (doc_id, ref, value, sealed) VALUES (\(id), \(ref), \(value), true)", logger: logger)
                }
            }
            return created
        }
    }

    /// nil for an unknown document and for one whose app was deleted (protocol 1.10; `documentStatus` tells them apart).
    func documentHeadImpl(_ id: String) async throws -> Int? {
        let rows = try await client.query("""
            SELECT head FROM documents d WHERE id = \(id)
              AND NOT EXISTS (SELECT 1 FROM apps a WHERE a.doc_id = d.id AND a.deleted_at IS NOT NULL)
            """, logger: logger)
        for try await (head) in rows.decode(Int.self) { return head }
        return nil
    }

    /// Latest snapshot + the log tail after it, read in one repeatable-read transaction so they are consistent.
    func loadImpl(_ id: String) async throws -> LoadedDocument? {
        try await client.withTransaction(logger: logger) { c in
            _ = try await c.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", logger: logger)
            var rev = -1
            var head = 0
            // Protocol 1.10: a deleted app's document is not loaded (nil, as an unknown one).
            for try await (r, h) in try await c.query("""
                SELECT rev, head FROM documents d WHERE id = \(id)
                  AND NOT EXISTS (SELECT 1 FROM apps a WHERE a.doc_id = d.id AND a.deleted_at IS NOT NULL)
                """, logger: logger).decode((Int, Int).self) {
                rev = r
                head = h
            }
            guard rev >= 0 else { return nil }
            var snapshot: Snapshot?
            for try await (seq, state) in try await c.query(
                "SELECT seq, state::text FROM snapshots WHERE doc_id = \(id) ORDER BY seq DESC LIMIT 1", logger: logger
            ).decode((Int, String).self) {
                snapshot = Snapshot(seq: seq, doc: try WireJSON.decode(Document.self, from: state))
            }
            guard let snapshot else { throw StoreError.corrupt("document \(id) has no snapshot") }
            var tail: [LogEntry] = []
            for try await row in try await c.query(
                "SELECT seq, client_id, cseq, base, op::text FROM ops WHERE doc_id = \(id) AND seq > \(snapshot.seq) ORDER BY seq",
                logger: logger
            ).decode((Int, String, Int, Int, String).self) {
                tail.append(LogEntry(seq: row.0, client: row.1, cseq: row.2, base: row.3, op: try WireJSON.decode(Op.self, from: row.4)))
            }
            return LoadedDocument(snapshot: snapshot, tail: tail, rev: rev, head: head)
        }
    }

    // MARK: - Reads

    /// Committed entries with `after < seq <= through`, in order.
    func entriesImpl(_ id: String, after: Int, through: Int) async throws -> [LogEntry] {
        var out: [LogEntry] = []
        let rows = try await client.query(
            "SELECT seq, client_id, cseq, base, op::text FROM ops WHERE doc_id = \(id) AND seq > \(after) AND seq <= \(through) ORDER BY seq",
            logger: logger)
        for try await row in rows.decode((Int, String, Int, Int, String).self) {
            out.append(LogEntry(seq: row.0, client: row.1, cseq: row.2, base: row.3, op: try WireJSON.decode(Op.self, from: row.4)))
        }
        return out
    }

    func logContainsOpImpl(_ id: String, type t: String, after: Int, through: Int) async throws -> Bool {
        let rows = try await client.query(
            "SELECT EXISTS (SELECT 1 FROM ops WHERE doc_id = \(id) AND seq > \(after) AND seq <= \(through) AND op->>'t' = \(t))",
            logger: logger)
        for try await found in rows.decode(Bool.self) { return found }
        return false
    }

    func logTouchesAppImpl(_ id: String, after: Int, through: Int) async throws -> Bool {
        let app = Document.appNode
        let rows = try await client.query(
            "SELECT EXISTS (SELECT 1 FROM ops WHERE doc_id = \(id) AND seq > \(after) AND seq <= \(through) AND op->>'node' = \(app))",
            logger: logger)
        for try await found in rows.decode(Bool.self) { return found }
        return false
    }

    func clientHighImpl(_ id: String, client c: ClientID) async throws -> Int {
        let rows = try await client.query("SELECT high FROM client_state WHERE doc_id = \(id) AND client_id = \(c)", logger: logger)
        for try await high in rows.decode(Int.self) { return high }
        return 0
    }

    /// Durable outcomes of this client's cseqs in `range`.
    func knownOutcomesImpl(_ id: String, client c: ClientID, range: ClosedRange<Int>?) async throws -> KnownOutcomes {
        guard let range else { return KnownOutcomes() }
        var k = KnownOutcomes()
        let lo = range.lowerBound, hi = range.upperBound
        for try await (cseq, seq, fp) in try await client.query(
            "SELECT cseq, seq, fp FROM ops WHERE doc_id = \(id) AND client_id = \(c) AND cseq BETWEEN \(lo) AND \(hi)", logger: logger
        ).decode((Int, Int, Int64).self) {
            k.committed[cseq] = seq
            if fp != 0 { k.fingerprints[cseq] = fp }
        }
        for try await (cseq, reason, fp) in try await client.query(
            "SELECT cseq, reason::text, fp FROM rejections WHERE doc_id = \(id) AND client_id = \(c) AND cseq BETWEEN \(lo) AND \(hi)", logger: logger
        ).decode((Int, String, Int64).self) {
            k.rejected[cseq] = try WireJSON.decode(RejectReason.self, from: reason)
            if fp != 0 { k.fingerprints[cseq] = fp }
        }
        return k
    }

    /// cseq -> seq for the client's ops with `cseq >= from` committed at or before `through`.
    func committedMapImpl(_ id: String, client c: ClientID, from: Int, through: Int) async throws -> [Int: Int] {
        var out: [Int: Int] = [:]
        for try await (cseq, seq) in try await client.query(
            "SELECT cseq, seq FROM ops WHERE doc_id = \(id) AND client_id = \(c) AND cseq >= \(from) AND seq <= \(through)", logger: logger
        ).decode((Int, Int).self) {
            out[cseq] = seq
        }
        return out
    }

    // MARK: - The commit

    /// One client's processed request inside a group commit.
    public struct CommitGroup: Sendable {
        public var client: ClientID
        public var batch: SequencerBatch
        public init(client: ClientID, batch: SequencerBatch) {
            self.client = client
            self.batch = batch
        }
    }

    /// Convenience for a single request.
    public func commit(doc id: String, expectedRev: Int, client c: ClientID, batch: SequencerBatch,
                       newHead: Int, snapshot: Snapshot?) async throws -> Int {
        try await commit(doc: id, expectedRev: expectedRev, groups: [CommitGroup(client: c, batch: batch)], newHead: newHead, snapshot: snapshot)
    }

    /// Atomically persists the processed requests of several clients in ONE transaction (group commit). Throws
    /// `StoreError.revisionMismatch` (without writing) if the document row's revision differs from `expectedRev`.
    /// Returns the new revision.
    ///
    /// `.notCommitted` means the transaction definitely did not commit; `.uncertain` means its outcome is unknown (the caller
    /// must re-read durable state before doing anything else).
    ///
    /// `metadata` (a replacement from a Dify file, `POST /replace`) replaces the document's import metadata and `secrets` are
    /// stored, in the same transaction.
    public func commit(doc id: String, expectedRev: Int, groups: [CommitGroup], newHead: Int, snapshot: Snapshot?,
                       metadata: Value? = nil, secrets: [String: String] = [:]) async throws -> Int {
        let snapshotJSON = try snapshot.map { try WireJSON.encodeString($0.doc) }
        var rows = Rows()
        for g in groups {
            for e in g.batch.entries {
                rows.opSeq.append(e.seq); rows.opClient.append(g.client); rows.opCseq.append(e.cseq); rows.opBase.append(e.base)
                rows.opJSON.append(try WireJSON.encodeString(e.op)); rows.opFp.append(g.batch.fingerprints[e.cseq] ?? 0)
            }
            for c in g.batch.rejections.keys.sorted() {
                rows.rejClient.append(g.client); rows.rejCseq.append(c)
                rows.rejJSON.append(try WireJSON.encodeString(g.batch.rejections[c]!)); rows.rejFp.append(g.batch.fingerprints[c] ?? 0)
            }
            if g.batch.highChanged { rows.highClient.append(g.client); rows.highValue.append(g.batch.newHigh) }
        }
        rows.metadata = try metadata.map { try WireJSON.encodeString($0) }
        for (ref, value) in secrets.sorted(by: { $0.key < $1.key }) {
            rows.secretRef.append(ref)
            rows.secretValue.append(try sealSecret(doc: id, ref: ref, value))
        }
        let snap = snapshot.map { ($0.seq, snapshotJSON!) }
        let frozen = rows
        do {
            return try await withTimeout(operationTimeout) {
                try await self.commitTransaction(id, expectedRev, frozen, newHead, snap)
            }
        } catch is TimeoutError {
            throw StoreError.uncertain("commit did not finish in time")
        } catch let e as PostgresTransactionError {
            if e.commitError != nil { throw StoreError.uncertain("\(e.commitError!)") }
            if let closure = e.closureError as? StoreError { throw closure }
            throw StoreError.notCommitted("\(e.beginError ?? e.closureError ?? e.rollbackError ?? e)")
        }
    }

    /// Column-oriented rows for the bulk inserts.
    struct Rows: Sendable {
        var opSeq: [Int] = [], opClient: [String] = [], opCseq: [Int] = [], opBase: [Int] = [], opJSON: [String] = [], opFp: [Int64] = []
        var rejClient: [String] = [], rejCseq: [Int] = [], rejJSON: [String] = [], rejFp: [Int64] = []
        var highClient: [String] = [], highValue: [Int] = []
        var metadata: String?
        var secretRef: [String] = [], secretValue: [String] = []
    }

    private func commitTransaction(_ id: String, _ expectedRev: Int, _ r: Rows, _ newHead: Int, _ snap: (Int, String)?) async throws -> Int {
        try await client.withTransaction(logger: logger) { tx in
            var current: Int?
            for try await rev in try await tx.query("SELECT rev FROM documents WHERE id = \(id) FOR UPDATE", logger: logger).decode(Int.self) {
                current = rev
            }
            guard current == expectedRev else { throw StoreError.revisionMismatch }

            if !r.opSeq.isEmpty {
                _ = try await tx.query("""
                    INSERT INTO ops (doc_id, seq, client_id, cseq, base, op, fp)
                    SELECT \(id), u.seq, u.client, u.cseq, u.base, u.op::jsonb, u.fp
                    FROM unnest(\(r.opSeq)::bigint[], \(r.opClient)::text[], \(r.opCseq)::bigint[], \(r.opBase)::bigint[], \(r.opJSON)::text[], \(r.opFp)::bigint[])
                         AS u(seq, client, cseq, base, op, fp)
                    """, logger: logger)
            }
            if !r.rejCseq.isEmpty {
                _ = try await tx.query("""
                    INSERT INTO rejections (doc_id, client_id, cseq, reason, fp)
                    SELECT \(id), u.client, u.cseq, u.reason::jsonb, u.fp
                    FROM unnest(\(r.rejClient)::text[], \(r.rejCseq)::bigint[], \(r.rejJSON)::text[], \(r.rejFp)::bigint[]) AS u(client, cseq, reason, fp)
                    """, logger: logger)
            }
            if !r.highClient.isEmpty {
                _ = try await tx.query("""
                    INSERT INTO client_state (doc_id, client_id, high)
                    SELECT \(id), u.client, max(u.high) FROM unnest(\(r.highClient)::text[], \(r.highValue)::bigint[]) AS u(client, high) GROUP BY u.client
                    ON CONFLICT (doc_id, client_id) DO UPDATE SET high = GREATEST(client_state.high, EXCLUDED.high)
                    """, logger: logger)
            }
            if let meta = r.metadata {
                _ = try await tx.query("""
                    INSERT INTO doc_meta (doc_id, dsl) VALUES (\(id), \(meta)::text::jsonb)
                    ON CONFLICT (doc_id) DO UPDATE SET dsl = EXCLUDED.dsl, updated_at = now()
                    """, logger: logger)
            }
            if !r.secretRef.isEmpty {
                _ = try await tx.query("""
                    INSERT INTO secrets (doc_id, ref, value, sealed)
                    SELECT \(id), u.ref, u.value, true FROM unnest(\(r.secretRef)::text[], \(r.secretValue)::text[]) AS u(ref, value)
                    ON CONFLICT (doc_id, ref) DO NOTHING
                    """, logger: logger)
            }
            if let (seq, json) = snap {
                _ = try await tx.query("""
                    INSERT INTO snapshots (doc_id, seq, state) VALUES (\(id), \(seq), \(json)::text::jsonb)
                    ON CONFLICT DO NOTHING
                    """, logger: logger)
                // Keep the two most recent checkpoints.
                _ = try await tx.query("""
                    DELETE FROM snapshots WHERE doc_id = \(id) AND seq < COALESCE(
                        (SELECT min(seq) FROM (SELECT seq FROM snapshots WHERE doc_id = \(id) ORDER BY seq DESC LIMIT 2) keep), 0)
                    """, logger: logger)
            }
            // Protocol 1.10: `updated_at` is the app's "last modified" (same statement, no extra round trip).
            _ = try await tx.query("UPDATE documents SET rev = rev + 1, head = \(newHead), updated_at = now() WHERE id = \(id)", logger: logger)
            return expectedRev + 1
        }
    }
}
