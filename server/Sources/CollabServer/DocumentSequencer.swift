import CollabCore
import CollabStore
import Foundation
import Logging

/// HTTP-level failures, mapped to status codes by the routes.
public enum ServerError: Error, Sendable {
    case badRequest(String)
    case notFound
    case payloadTooLarge
    /// Database unavailable or the commit outcome is uncertain: the client retries the identical request.
    case unavailable(String)
    case internalError(String)
}

/// One document's single writer.
///
/// Concurrency model: every request for the document passes through this actor, and `exclusive` additionally
/// serialises them across the awaits inside (an actor alone is re-entrant at suspension points), so there is
/// exactly one batch in flight per document at any time: that is the "single sequencer".
///
/// Across processes the guard is in the database: each commit locks the `documents` row and checks that its
/// revision is the one this actor's in-memory state was built from; a mismatch means another writer got in,
/// so the state is thrown away, re-read and the batch is re-planned (`PostgresStore.commit`).
actor DocumentSequencer {
    struct Live {
        var core: Sequencer
        var rev: Int
        var highs: [ClientID: Int] = [:]
    }

    struct Subscription {
        var id: Int
        var head: Int
        var plan: ResumePlan
        /// Present for `.snapshot` plans: the document at `head`, captured atomically with the registration.
        var doc: Document?
        var live: AsyncStream<String>
    }

    private let docId: String
    private let store: PostgresStore
    private let config: ServerConfig
    private let logger: Logger
    private var state: Live?
    /// Highest seq already pushed to subscribers.
    private var published = 0
    private var subs: [Int: AsyncStream<String>.Continuation] = [:]
    private var nextSub = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(docId: String, store: PostgresStore, config: ServerConfig, logger: Logger) {
        self.docId = docId
        self.store = store
        self.config = config
        self.logger = logger
    }

    // MARK: - Mutual exclusion across awaits

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    // MARK: - Loading

    private func ensureLoaded() async throws -> Live {
        if let state { return state }
        let loaded: LoadedDocument?
        do {
            loaded = try await store.load(docId)
        } catch {
            throw ServerError.unavailable("load failed: \(error)")
        }
        guard let loaded else { throw ServerError.notFound }
        let core: Sequencer
        do {
            core = try Sequencer(snapshot: loaded.snapshot, tail: loaded.tail)
        } catch {
            logger.critical("document \(docId): durable log is not replayable: \(error)")
            throw ServerError.internalError("durable log is not replayable")
        }
        let live = Live(core: core, rev: loaded.rev)
        state = live
        // A previous commit may have been durable without being announced (uncertain commit, or another
        // process wrote): tell the subscribers about everything they have not seen.
        if core.seq > published {
            if !subs.isEmpty {
                if let missed = try? await store.entries(docId, after: published, through: core.seq) {
                    for e in missed { broadcast(e) }
                }
            }
            published = core.seq
        }
        return live
    }

    // MARK: - Submit

    func submit(_ req: SubmitRequest) async throws -> SubmitResponse {
        try await exclusive {
            var attempts = 0
            while true {
                attempts += 1
                do {
                    return try await submitOnce(req)
                } catch StoreError.revisionMismatch {
                    // Someone else wrote this document: forget our state, reload, re-plan.
                    state = nil
                    logger.warning("document \(docId): revision changed under us, reloading (attempt \(attempts))")
                    if attempts >= 5 { throw ServerError.unavailable("document is contended") }
                }
            }
        }
    }

    private func submitOnce(_ req: SubmitRequest) async throws -> SubmitResponse {
        var live = try await ensureLoaded()
        let high: Int
        if let h = live.highs[req.client] {
            high = h
        } else {
            do { high = try await store.clientHigh(docId, client: req.client) } catch { throw ServerError.unavailable("\(error)") }
            state?.highs[req.client] = high
            live.highs[req.client] = high
        }
        var known = KnownOutcomes()
        if let range = Sequencer.lookupRange(for: req, clientHigh: high) {
            do { known = try await store.knownOutcomes(docId, client: req.client, range: range) } catch { throw ServerError.unavailable("\(error)") }
        }
        var working = live.core
        let batch = working.process(req, clientHigh: high, known: known)
        if batch.isEmpty { return batch.response }  // pure duplicates / gaps: nothing to persist

        let snapshot = Sequencer.snapshotDue(oldSeq: live.core.seq, newSeq: working.seq, every: config.snapshotEvery) ? working.snapshot : nil
        if config.testCommitDelayMillis > 0 { try? await Task.sleep(for: .milliseconds(config.testCommitDelayMillis)) }
        let newRev: Int
        do {
            newRev = try await store.commit(doc: docId, expectedRev: live.rev, client: req.client, batch: batch,
                                            newHead: working.seq, snapshot: snapshot)
        } catch StoreError.revisionMismatch {
            throw StoreError.revisionMismatch
        } catch StoreError.notCommitted(let why) {
            throw ServerError.unavailable("not committed: \(why)")
        } catch {
            // Uncertain outcome (or cancellation): the batch may be durable. Forget memory; the retry is answered from the database.
            state = nil
            logger.error("document \(docId): commit outcome unknown: \(error)")
            throw ServerError.unavailable("commit outcome unknown")
        }
        // Durable. Only now adopt the new state and tell anyone.
        live.core = working
        live.rev = newRev
        live.highs[req.client] = batch.newHigh
        state = live
        for e in batch.entries { broadcast(e) }
        published = working.seq
        return batch.response
    }

    private func broadcast(_ entry: LogEntry) {
        guard !subs.isEmpty, let frame = try? StreamEvent.commit(entry).sseFrame() else { return }
        for (id, c) in subs {
            if case .dropped = c.yield(frame) {
                // Too slow: cut it loose. The client reconnects with Last-Event-ID and catches up from the log.
                c.finish()
                subs[id] = nil
            }
        }
    }

    // MARK: - Reads and streams

    func currentSnapshot() async throws -> Snapshot {
        try await exclusive { try await ensureLoaded().core.snapshot }
    }

    func head() async throws -> Int {
        try await exclusive { try await ensureLoaded().core.seq }
    }

    /// Registers a stream subscriber atomically with respect to commits: it receives every entry after `head`
    /// through `live`, and the caller is responsible for the catch-up up to `head`.
    func subscribe(lastEventId: Int?, maxReplay: Int) async throws -> Subscription {
        try await exclusive {
            let live = try await ensureLoaded()
            let head = live.core.seq
            let plan = resumePlan(lastEventId: lastEventId, head: head, maxReplay: maxReplay)
            let (stream, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2000))
            nextSub += 1
            let id = nextSub
            subs[id] = cont
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(id) }
            }
            var doc: Document?
            if plan == .snapshot { doc = live.core.doc }
            return Subscription(id: id, head: head, plan: plan, doc: doc, live: stream)
        }
    }

    func unsubscribe(_ id: Int) {
        subs[id]?.finish()
        subs[id] = nil
    }

    func ping() {
        for (id, c) in subs {
            if case .dropped = c.yield(": ping\n\n") {
                c.finish()
                subs[id] = nil
            }
        }
    }

    func finishAllStreams() {
        for (_, c) in subs { c.finish() }
        subs = [:]
    }

    var subscriberCount: Int { subs.count }
}

/// Lazily creates one `DocumentSequencer` per document.
actor DocumentRegistry {
    private var docs: [String: DocumentSequencer] = [:]
    private let store: PostgresStore
    private let config: ServerConfig
    private let logger: Logger

    init(store: PostgresStore, config: ServerConfig, logger: Logger) {
        self.store = store
        self.config = config
        self.logger = logger
    }

    func sequencer(_ id: String) -> DocumentSequencer {
        if let s = docs[id] { return s }
        let s = DocumentSequencer(docId: id, store: store, config: config, logger: logger)
        docs[id] = s
        return s
    }

    func pingAll() async {
        for s in docs.values { await s.ping() }
    }

    func finishAll() async {
        for s in docs.values { await s.finishAllStreams() }
    }

    func totalSubscribers() async -> Int {
        var n = 0
        for s in docs.values { n += await s.subscriberCount }
        return n
    }
}
