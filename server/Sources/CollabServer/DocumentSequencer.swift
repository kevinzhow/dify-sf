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
            core = try Sequencer(snapshot: loaded.snapshot, tail: loaded.tail,
                                 defects: config.testDefect == "skipStaleCheck" ? .skipStaleCheck : [])
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

    // MARK: - Submit (group commit)

    private struct Pending {
        var req: SubmitRequest
        var cont: CheckedContinuation<SubmitResponse, Error>
    }
    private var pending: [Pending] = []
    private var draining = false
    /// Upper bound of requests committed in one transaction.
    private static let maxGroup = 64

    /// Queues the request. Requests that arrive while a commit is in flight are committed TOGETHER in the next
    /// transaction (group commit): one round of row lock + insert + COMMIT for many clients, which is what keeps the
    /// write path flat when commits are slow or many clients are active. Nobody is answered before its transaction committed.
    func submit(_ req: SubmitRequest) async throws -> SubmitResponse {
        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SubmitResponse, Error>) in
            pending.append(Pending(req: req, cont: cont))
            if !draining {
                draining = true
                Task { await self.drain() }
            }
        }
        return await annotated(response)
    }

    // MARK: - Client display names (protocol 1.3)

    private var names: [ClientID: String] = [:]
    private var namesRefreshedAt: ContinuousClock.Instant?

    /// Display names of this document's clients (refreshed from the database at most every 2 s unless forced).
    func clientNames(force: Bool = false) async throws -> [ClientID: String] {
        if force || namesRefreshedAt == nil || ContinuousClock.now - namesRefreshedAt! > .seconds(2) {
            do { names = try await store.clientNames(docId) } catch { throw ServerError.unavailable("\(error)") }
            namesRefreshedAt = ContinuousClock.now
        }
        return names
    }

    func setName(client: ClientID, name: String) async throws {
        do { try await store.setClientName(docId, client: client, name: name) } catch { throw ServerError.unavailable("\(error)") }
        names[client] = name
    }

    /// Adds `byName` to conflict notices whose author registered a name. Never fails the request.
    private func annotated(_ r: SubmitResponse) async -> SubmitResponse {
        func author(_ reason: RejectReason) -> ClientID? { if case .conflict(let c) = reason { return c.by }; return nil }
        var any = false
        for res in r.results { if case .reject(_, let reason) = res, author(reason) != nil { any = true } }
        for reason in (r.known?.rejected.values.map { $0 } ?? []) where author(reason) != nil { any = true }
        guard any else { return r }
        let table = (try? await clientNames()) ?? names
        func named(_ reason: RejectReason) -> RejectReason {
            guard case .conflict(var c) = reason, let n = table[c.by] else { return reason }
            c.byName = n
            return .conflict(c)
        }
        var out = r
        out.results = r.results.map { res in
            if case .reject(let cs, let reason) = res { return .reject(cseq: cs, reason: named(reason)) }
            return res
        }
        if let k = r.known {
            var kk = k
            kk.rejected = k.rejected.mapValues(named)
            out.known = kk
        }
        return out
    }

    private func drain() async {
        while !pending.isEmpty {
            let group = Array(pending.prefix(Self.maxGroup))
            pending.removeFirst(group.count)
            await exclusive { await self.commitGroup(group) }
        }
        draining = false
    }

    private func commitGroup(_ group: [Pending]) async {
        var attempts = 0
        while true {
            attempts += 1
            do {
                let responses = try await commitGroupOnce(group.map(\.req))
                for (p, r) in zip(group, responses) { p.cont.resume(returning: r) }
                return
            } catch StoreError.revisionMismatch {
                // Someone else wrote this document: forget our state, reload, re-plan the whole group.
                state = nil
                logger.warning("document \(docId): revision changed under us, reloading (attempt \(attempts))")
                if attempts >= 25 {
                    for p in group { p.cont.resume(throwing: ServerError.unavailable("document is contended")) }
                    return
                }
                // Back off a little (randomised) so that two processes do not keep invalidating each other in lockstep.
                try? await Task.sleep(for: .milliseconds(Int.random(in: 1...(5 * attempts))))
            } catch {
                for p in group { p.cont.resume(throwing: error) }
                return
            }
        }
    }

    /// Plans every request of the group in order on one working copy, persists everything in ONE transaction, and only
    /// then adopts the new state, announces the commits and returns the responses (same order as `reqs`).
    private func commitGroupOnce(_ reqs: [SubmitRequest]) async throws -> [SubmitResponse] {
        var live = try await ensureLoaded()
        var working = live.core
        var highs = live.highs
        var factsOfGroup: [ClientID: KnownOutcomes] = [:]  // outcomes decided earlier in this same group
        var responses: [SubmitResponse] = []
        var groups: [PostgresStore.CommitGroup] = []

        for req in reqs {
            let high: Int
            if let h = highs[req.client] {
                high = h
            } else {
                do { high = try await store.clientHigh(docId, client: req.client) } catch { throw ServerError.unavailable("\(error)") }
                highs[req.client] = high
            }
            var known = KnownOutcomes()
            if let range = Sequencer.lookupRange(for: req, clientHigh: high) {
                do { known = try await store.knownOutcomes(docId, client: req.client, range: range) } catch { throw ServerError.unavailable("\(error)") }
            }
            if let earlier = factsOfGroup[req.client] {
                known.committed.merge(earlier.committed) { $1 }
                known.rejected.merge(earlier.rejected) { $1 }
                known.fingerprints.merge(earlier.fingerprints) { $1 }
            }
            let batch = working.process(req, clientHigh: high, known: known)
            responses.append(batch.response)
            highs[req.client] = batch.newHigh
            if batch.isEmpty { continue }  // pure duplicates / gaps: nothing to persist
            var facts = factsOfGroup[req.client] ?? KnownOutcomes()
            for e in batch.entries { facts.committed[e.cseq] = e.seq }
            for (c, r) in batch.rejections { facts.rejected[c] = r }
            facts.fingerprints.merge(batch.fingerprints) { $1 }
            factsOfGroup[req.client] = facts
            groups.append(.init(client: req.client, batch: batch))
        }
        if groups.isEmpty { return responses }

        let snapshot = Sequencer.snapshotDue(oldSeq: live.core.seq, newSeq: working.seq, every: config.snapshotEvery) ? working.snapshot : nil
        if config.testCommitDelayMillis > 0 { try? await Task.sleep(for: .milliseconds(config.testCommitDelayMillis)) }
        let entries = groups.flatMap(\.batch.entries)
        if config.testDefect == "ackBeforeCommit" {
            // TEST ONLY defect: answer first, persist a moment later (a kill -9 in between loses acknowledged ops).
            let store = self.store, docId = self.docId, rev = live.rev, head = working.seq, grp = groups
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                _ = try? await store.commit(doc: docId, expectedRev: rev, groups: grp, newHead: head, snapshot: snapshot)
            }
            live.core = working
            live.rev += 1
            live.highs = highs
            state = live
            for e in entries { broadcast(e) }
            published = working.seq
            return responses
        }
        let newRev: Int
        do {
            newRev = try await store.commit(doc: docId, expectedRev: live.rev, groups: groups, newHead: working.seq, snapshot: snapshot)
        } catch StoreError.revisionMismatch {
            throw StoreError.revisionMismatch
        } catch StoreError.notCommitted(let why) {
            throw ServerError.unavailable("not committed: \(why)")
        } catch {
            // Uncertain outcome (or cancellation): the group may be durable. Forget memory; the retries are answered from the database.
            state = nil
            logger.error("document \(docId): commit outcome unknown: \(error)")
            throw ServerError.unavailable("commit outcome unknown")
        }
        // Durable. Only now adopt the new state and tell anyone.
        live.core = working
        live.rev = newRev
        live.highs = highs
        state = live
        for e in entries { broadcast(e) }
        published = working.seq
        return responses
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
