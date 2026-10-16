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

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    // MARK: - Setup

    public func migrate() async throws {
        for sql in Schema.statements {
            _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        }
    }

    public func ping() async throws {
        _ = try await client.query("SELECT 1", logger: logger)
    }

    // MARK: - Documents

    /// Creates the document with its seed state (snapshot at seq 0). Returns false if it already existed.
    public func createDocument(id: String, initial: Document) async throws -> Bool {
        let state = try WireJSON.encodeString(initial)
        return try await client.withTransaction(logger: logger) { c in
            let inserted = try await c.query("INSERT INTO documents (id) VALUES (\(id)) ON CONFLICT DO NOTHING RETURNING rev", logger: logger)
            var created = false
            for try await _ in inserted { created = true }
            if created {
                _ = try await c.query("INSERT INTO snapshots (doc_id, seq, state) VALUES (\(id), 0, \(state)::text::jsonb)", logger: logger)
            }
            return created
        }
    }

    public func documentHead(_ id: String) async throws -> Int? {
        let rows = try await client.query("SELECT head FROM documents WHERE id = \(id)", logger: logger)
        for try await (head) in rows.decode(Int.self) { return head }
        return nil
    }

    /// Latest snapshot + the log tail after it, read in one repeatable-read transaction so they are consistent.
    public func load(_ id: String) async throws -> LoadedDocument? {
        try await client.withTransaction(logger: logger) { c in
            _ = try await c.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", logger: logger)
            var rev = -1
            var head = 0
            for try await (r, h) in try await c.query("SELECT rev, head FROM documents WHERE id = \(id)", logger: logger).decode((Int, Int).self) {
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
    public func entries(_ id: String, after: Int, through: Int) async throws -> [LogEntry] {
        var out: [LogEntry] = []
        let rows = try await client.query(
            "SELECT seq, client_id, cseq, base, op::text FROM ops WHERE doc_id = \(id) AND seq > \(after) AND seq <= \(through) ORDER BY seq",
            logger: logger)
        for try await row in rows.decode((Int, String, Int, Int, String).self) {
            out.append(LogEntry(seq: row.0, client: row.1, cseq: row.2, base: row.3, op: try WireJSON.decode(Op.self, from: row.4)))
        }
        return out
    }

    public func clientHigh(_ id: String, client c: ClientID) async throws -> Int {
        let rows = try await client.query("SELECT high FROM client_state WHERE doc_id = \(id) AND client_id = \(c)", logger: logger)
        for try await high in rows.decode(Int.self) { return high }
        return 0
    }

    /// Durable outcomes of this client's cseqs in `range`.
    public func knownOutcomes(_ id: String, client c: ClientID, range: ClosedRange<Int>?) async throws -> KnownOutcomes {
        guard let range else { return KnownOutcomes() }
        var k = KnownOutcomes()
        let lo = range.lowerBound, hi = range.upperBound
        for try await (cseq, seq) in try await client.query(
            "SELECT cseq, seq FROM ops WHERE doc_id = \(id) AND client_id = \(c) AND cseq BETWEEN \(lo) AND \(hi)", logger: logger
        ).decode((Int, Int).self) {
            k.committed[cseq] = seq
        }
        for try await (cseq, reason) in try await client.query(
            "SELECT cseq, reason::text FROM rejections WHERE doc_id = \(id) AND client_id = \(c) AND cseq BETWEEN \(lo) AND \(hi)", logger: logger
        ).decode((Int, String).self) {
            k.rejected[cseq] = try WireJSON.decode(RejectReason.self, from: reason)
        }
        return k
    }

    /// cseq -> seq for the client's ops with `cseq >= from` committed at or before `through`.
    public func committedMap(_ id: String, client c: ClientID, from: Int, through: Int) async throws -> [Int: Int] {
        var out: [Int: Int] = [:]
        for try await (cseq, seq) in try await client.query(
            "SELECT cseq, seq FROM ops WHERE doc_id = \(id) AND client_id = \(c) AND cseq >= \(from) AND seq <= \(through)", logger: logger
        ).decode((Int, Int).self) {
            out[cseq] = seq
        }
        return out
    }

    // MARK: - The commit

    /// Atomically persists one processed batch. Throws `StoreError.revisionMismatch` (without writing) if the
    /// document row's revision differs from `expectedRev`. Returns the new revision.
    ///
    /// Any other thrown error means the outcome is UNKNOWN to the caller (the transaction may or may not have
    /// committed); the caller must re-read durable state before doing anything else.
    public func commit(doc id: String, expectedRev: Int, client c: ClientID, batch: SequencerBatch,
                       newHead: Int, snapshot: Snapshot?) async throws -> Int {
        let snapshotJSON = try snapshot.map { try WireJSON.encodeString($0.doc) }
        let seqs = batch.entries.map(\.seq)
        let cseqs = batch.entries.map(\.cseq)
        let bases = batch.entries.map(\.base)
        let ops = try batch.entries.map { try WireJSON.encodeString($0.op) }
        let rejected = batch.rejections.keys.sorted()
        let reasons = try rejected.map { try WireJSON.encodeString(batch.rejections[$0]!) }

        do {
            return try await commitTransaction(id, expectedRev, c, batch, newHead, snapshot, snapshotJSON, seqs, cseqs, bases, ops, rejected, reasons)
        } catch let e as PostgresTransactionError {
            if e.commitError != nil { throw StoreError.uncertain("\(e.commitError!)") }
            if let closure = e.closureError as? StoreError { throw closure }
            throw StoreError.notCommitted("\(e.beginError ?? e.closureError ?? e.rollbackError ?? e)")
        }
    }

    private func commitTransaction(_ id: String, _ expectedRev: Int, _ c: ClientID, _ batch: SequencerBatch, _ newHead: Int,
                                   _ snapshot: Snapshot?, _ snapshotJSON: String?, _ seqs: [Int], _ cseqs: [Int], _ bases: [Int],
                                   _ ops: [String], _ rejected: [Int], _ reasons: [String]) async throws -> Int {
        let newHigh = batch.newHigh
        return try await client.withTransaction(logger: logger) { tx in
            var current: Int?
            for try await rev in try await tx.query("SELECT rev FROM documents WHERE id = \(id) FOR UPDATE", logger: logger).decode(Int.self) {
                current = rev
            }
            guard current == expectedRev else { throw StoreError.revisionMismatch }

            if !seqs.isEmpty {
                _ = try await tx.query("""
                    INSERT INTO ops (doc_id, seq, client_id, cseq, base, op)
                    SELECT \(id), u.seq, \(c), u.cseq, u.base, u.op::jsonb
                    FROM unnest(\(seqs)::bigint[], \(cseqs)::bigint[], \(bases)::bigint[], \(ops)::text[]) AS u(seq, cseq, base, op)
                    """, logger: logger)
            }
            if !rejected.isEmpty {
                _ = try await tx.query("""
                    INSERT INTO rejections (doc_id, client_id, cseq, reason)
                    SELECT \(id), \(c), u.cseq, u.reason::jsonb
                    FROM unnest(\(rejected)::bigint[], \(reasons)::text[]) AS u(cseq, reason)
                    """, logger: logger)
            }
            if batch.highChanged {
                _ = try await tx.query("""
                    INSERT INTO client_state (doc_id, client_id, high) VALUES (\(id), \(c), \(newHigh))
                    ON CONFLICT (doc_id, client_id) DO UPDATE SET high = GREATEST(client_state.high, EXCLUDED.high)
                    """, logger: logger)
            }
            if let snapshot, let json = snapshotJSON {
                _ = try await tx.query("""
                    INSERT INTO snapshots (doc_id, seq, state) VALUES (\(id), \(snapshot.seq), \(json)::text::jsonb)
                    ON CONFLICT DO NOTHING
                    """, logger: logger)
                // Keep the two most recent checkpoints.
                _ = try await tx.query("""
                    DELETE FROM snapshots WHERE doc_id = \(id) AND seq < COALESCE(
                        (SELECT min(seq) FROM (SELECT seq FROM snapshots WHERE doc_id = \(id) ORDER BY seq DESC LIMIT 2) keep), 0)
                    """, logger: logger)
            }
            _ = try await tx.query("UPDATE documents SET rev = rev + 1, head = \(newHead) WHERE id = \(id)", logger: logger)
            return expectedRev + 1
        }
    }
}
