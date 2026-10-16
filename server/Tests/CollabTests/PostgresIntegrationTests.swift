import CollabCore
import CollabStore
import Foundation
import Logging
import PostgresNIO
import Testing
@testable import CollabServer

/// Integration tests against a real Postgres. Enabled when TEST_DB_HOST is set (see server/run-db-tests.sh).
private let dbHost = ProcessInfo.processInfo.environment["TEST_DB_HOST"]

private func node(_ id: String) -> Node { Node(id: id, type: "llm", config: ["prompt": .string("p")]) }
private func prompt(_ n: String, _ v: String) -> Op { .setField(n, .config(["prompt"]), .string(v)) }
private func req(_ client: String, _ ops: [(Int, Int, Op)]) -> SubmitRequest {
    SubmitRequest(client: client, ops: ops.map { IncomingOp(cseq: $0.0, base: $0.1, op: $0.2) })
}

/// Boots a PostgresClient for the duration of `body`.
private func withStore<T: Sendable>(_ body: @Sendable (PostgresStore, Logger) async throws -> T) async throws -> T {
    var logger = Logger(label: "test")
    logger.logLevel = .error
    let cfg = PostgresClient.Configuration(host: dbHost!, port: Int(ProcessInfo.processInfo.environment["TEST_DB_PORT"] ?? "5432") ?? 5432,
                                           username: "collab", password: "collab", database: "collab", tls: .disable)
    let client = PostgresClient(configuration: cfg, backgroundLogger: logger)
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await client.run(); return nil }
        let store = PostgresStore(client: client, logger: logger)
        var migrated = false
        for _ in 0..<50 where !migrated {
            do { try await store.migrate(); migrated = true } catch { try await Task.sleep(for: .milliseconds(100)) }
        }
        let result = try await body(store, logger)
        group.cancelAll()
        return result
    }!
}

private func freshDoc(_ store: PostgresStore, nodes: [String] = ["a", "b"]) async throws -> String {
    let id = "t-\(UUID().uuidString.lowercased().prefix(12))"
    _ = try await store.createDocument(id: id, initial: Document(nodes: nodes.map(node)))
    return id
}

@Suite("Postgres store + sequencer", .enabled(if: dbHost != nil))
struct PostgresIntegrationTests {
    @Test func ackedOpsSurviveRestartAndDuplicatesReturnTheOriginalOutcome() async throws {
        try await withStore { store, logger in
            let doc = try await freshDoc(store)
            var cfg = ServerConfig.defaults
            cfg.snapshotEvery = 1000
            let first = DocumentSequencer(docId: doc, store: store, config: cfg, logger: logger)
            let r1 = try await first.submit(req("c", [(1, 0, prompt("a", "one")), (2, 0, prompt("ghost", "x")), (3, 1, prompt("a", "three"))]))
            #expect(r1.results == [.ack(cseq: 1, seq: 1), .reject(cseq: 2, reason: .nodeNotFound("ghost")), .ack(cseq: 3, seq: 2)])
            // A brand-new sequencer (= server restart) answers retransmits from the database.
            let second = DocumentSequencer(docId: doc, store: store, config: cfg, logger: logger)
            let r2 = try await second.submit(req("c", [(1, 0, prompt("a", "one")), (2, 0, prompt("ghost", "x")), (3, 1, prompt("a", "three"))]))
            #expect(r2.results == r1.results && r2.head == 2)
            // Gap: cseq 9 before 4.
            let r3 = try await second.submit(req("c", [(9, 2, prompt("a", "nine"))]))
            #expect(r3.results == [.gap(cseq: 9, expected: 4)])
            let snap = try await second.currentSnapshot()
            #expect(snap.seq == 2 && snap.doc.nodes["a"]?.config["prompt"] == .string("three"))
        }
    }

    @Test func twoSequencersOnOneDocumentNeverBothSequence() async throws {
        try await withStore { store, logger in
            let doc = try await freshDoc(store)
            var cfg = ServerConfig.defaults
            cfg.snapshotEvery = 7
            // Two "server processes" sharing one database.
            let a = DocumentSequencer(docId: doc, store: store, config: cfg, logger: logger)
            let b = DocumentSequencer(docId: doc, store: store, config: cfg, logger: logger)
            let acked = try await withThrowingTaskGroup(of: [(String, Int, Int)].self) { group in
                for c in 0..<6 {
                    let seqr = c % 2 == 0 ? a : b
                    group.addTask {
                        var out: [(String, Int, Int)] = []
                        for i in 1...15 {
                            let r = try await seqr.submit(req("c\(c)", [(i, 0, .moveNode(c % 2 == 0 ? "a" : "b", x: i, y: c))]))
                            if case .ack(let cs, let seq) = r.results[0] { out.append(("c\(c)", cs, seq)) }
                        }
                        return out
                    }
                }
                var all: [(String, Int, Int)] = []
                for try await part in group { all += part }
                return all
            }
            // Every op got a distinct seq, the log is gapless, and it contains exactly the acked ops.
            let head = try await store.documentHead(doc) ?? -1
            #expect(head == acked.count && acked.count == 90)
            #expect(Set(acked.map(\.2)).count == acked.count)
            let log = try await store.entries(doc, after: 0, through: head)
            #expect(log.map(\.seq) == Array(1...head))
            for (c, cseq, seq) in acked { #expect(log[seq - 1].client == c && log[seq - 1].cseq == cseq) }
            // And recovery from snapshot + tail equals the full replay.
            let loaded = try #require(try await store.load(doc))
            let recovered = try Sequencer(snapshot: loaded.snapshot, tail: loaded.tail)
            var full = Sequencer(initial: Document(nodes: [node("a"), node("b")]))
            for e in log { full.replay(e) }
            #expect(recovered.doc == full.doc && recovered.seq == head)
        }
    }

    @Test func conflictNoticesCarryTheAuthorsDisplayName() async throws {
        try await withStore { store, logger in
            let doc = try await freshDoc(store)
            let seqr = DocumentSequencer(docId: doc, store: store, config: ServerConfig.defaults, logger: logger)
            try await seqr.setName(client: "alice", name: "Alice")
            _ = try await seqr.submit(req("alice", [(1, 0, prompt("a", "A"))]))
            let r = try await seqr.submit(req("bob", [(1, 0, prompt("a", "B"))]))
            guard case .reject(_, .conflict(let c)) = r.results[0] else { Issue.record("expected a conflict"); return }
            #expect(c.by == "alice" && c.byName == "Alice")
            try await seqr.setName(client: "bob", name: "Bob")
            #expect(try await seqr.clientNames(force: true) == ["alice": "Alice", "bob": "Bob"])
        }
    }

    @Test func staleRevisionWritesNothing() async throws {
        try await withStore { store, _ in
            let doc = try await freshDoc(store)
            var s = Sequencer(initial: Document(nodes: [node("a")]))
            let batch = s.process(req("c", [(1, 0, prompt("a", "x"))]), clientHigh: 0, known: KnownOutcomes())
            _ = try await store.commit(doc: doc, expectedRev: 0, client: "c", batch: batch, newHead: 1, snapshot: nil)
            // A writer that still believes rev == 0 must be refused and must not leave anything behind.
            var s2 = Sequencer(initial: Document(nodes: [node("a")]))
            let batch2 = s2.process(req("d", [(1, 0, prompt("a", "y"))]), clientHigh: 0, known: KnownOutcomes())
            await #expect(throws: StoreError.self) {
                _ = try await store.commit(doc: doc, expectedRev: 0, client: "d", batch: batch2, newHead: 1, snapshot: nil)
            }
            #expect(try await store.documentHead(doc) == 1)
            #expect(try await store.entries(doc, after: 0, through: 5).count == 1)
            #expect(try await store.clientHigh(doc, client: "d") == 0)
        }
    }

    @Test func databaseRefusesDuplicateSlots() async throws {
        try await withStore { store, _ in
            let doc = try await freshDoc(store)
            var s = Sequencer(initial: Document(nodes: [node("a")]))
            let batch = s.process(req("c", [(1, 0, prompt("a", "x"))]), clientHigh: 0, known: KnownOutcomes())
            _ = try await store.commit(doc: doc, expectedRev: 0, client: "c", batch: batch, newHead: 1, snapshot: nil)
            // Even with the right revision, re-inserting the same (client, cseq) or the same seq is impossible.
            await #expect(throws: StoreError.self) {
                _ = try await store.commit(doc: doc, expectedRev: 1, client: "c", batch: batch, newHead: 1, snapshot: nil)
            }
        }
    }
}

extension Sequencer {
    /// Test helper: apply a committed entry without validation (what recovery does).
    mutating func replay(_ e: LogEntry) {
        var tail = [e]
        tail[0].seq = seq + 1
        self = (try? Sequencer(snapshot: snapshot, tail: tail, defects: defects)) ?? self
    }
}
