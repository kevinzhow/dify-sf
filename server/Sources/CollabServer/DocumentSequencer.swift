import CollabCore
import CollabStore
import Foundation
import Logging

/// HTTP-level failures, mapped to status codes by the routes.
public enum ServerError: Error, Sendable {
    case badRequest(String)
    case notFound
    /// 404 for something inside a known document (a comment, a reply); the message names it.
    case missing(String)
    /// 403 with a specific error code (`not_author`).
    case forbidden(code: String, message: String)
    case payloadTooLarge
    /// Database unavailable or the commit outcome is uncertain: the client retries the identical request.
    case unavailable(String)
    case internalError(String)
    /// 401 `unauthorized`: no, an unknown, an expired or a revoked access token (protocol 1.8).
    case unauthorized(String)
    /// Any other status with its error code (`invalid_credentials`, `setup_done`, `forbidden`, ...).
    case http(status: Int, code: String, message: String)
    /// 404 `app_deleted` (protocol 1.10): the document's app was deleted.
    case appDeleted
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
        /// The document at `head`, captured atomically with the registration: for `.snapshot` plans, and for streams of
        /// clients older than this protocol version (whose replay may have to become a snapshot, see `StreamCompat`).
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
    /// Subscribers of clients older than this protocol version, with their `proto`: their streams must not carry the
    /// commits they cannot decode (`StreamCompat`).
    private var legacySubs: [Int: String?] = [:]
    private var nextSub = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The app was deleted (protocol 1.10): every call answers `appDeleted`, nothing is loaded again.
    private var deleted = false

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
        if deleted { throw ServerError.appDeleted }
        if let state { return state }
        let loaded: LoadedDocument?
        do {
            loaded = try await store.load(docId)
        } catch {
            throw ServerError.unavailable("load failed: \(error)")
        }
        guard let loaded else {
            // Unknown, or (protocol 1.10) its app was deleted, possibly by another process.
            let status: DocumentStatus?
            do { status = try await store.documentStatus(docId) } catch { throw ServerError.unavailable("\(error)") }
            if status == .deleted {
                markDeleted()
                throw ServerError.appDeleted
            }
            throw ServerError.notFound
        }
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

    // MARK: - Client ids and their accounts (protocol 1.8)

    typealias DirectoryEntry = (account: String, name: String, avatarUrl: String?)
    private var directory: [ClientID: DirectoryEntry] = [:]
    private var directoryRefreshedAt: ContinuousClock.Instant?
    /// client id -> account. A binding never changes once made, so this cache never goes stale.
    private var bindings: [ClientID: String] = [:]

    /// client id -> (account, account name, avatar) of every bound client id (refreshed from the database at most every 2 s
    /// unless forced, so renamed accounts show up).
    func clientDirectory(force: Bool = false) async throws -> [ClientID: DirectoryEntry] {
        if force || directoryRefreshedAt == nil || ContinuousClock.now - directoryRefreshedAt! > .seconds(2) {
            do { directory = try await store.clientDirectory(docId) } catch { throw ServerError.unavailable("\(error)") }
            directoryRefreshedAt = ContinuousClock.now
            for (c, e) in directory { bindings[c] = e.account }
        }
        return directory
    }

    /// Account name per client id (for `byName`).
    func clientNames() async throws -> [ClientID: String] { try await clientDirectory().mapValues(\.name) }

    /// The account `client` is bound to, nil if none.
    func account(of client: ClientID) async throws -> String? {
        if let a = bindings[client] { return a }
        let a: String?
        do { a = try await store.clientAccount(docId, client: client) } catch { throw ServerError.unavailable("\(error)") }
        if let a { bindings[client] = a }
        return a
    }

    /// Binds `client` to `account` unless it is bound already (`404` for an unknown document); returns the account it is
    /// bound to.
    func bind(client: ClientID, to account: String) async throws -> String {
        if deleted { throw ServerError.appDeleted }
        if let a = try await self.account(of: client) { return a }
        do {
            guard try await store.documentHead(docId) != nil else { throw ServerError.notFound }
            let a = try await store.bindClient(docId, client: client, account: account)
            bindings[client] = a
            directoryRefreshedAt = nil
            return a
        } catch let e as ServerError { throw e } catch { throw ServerError.unavailable("\(error)") }
    }

    /// Adds `byName` (the author's account name, 1.8) to conflict notices whose author is bound to an account. Never fails the request.
    private func annotated(_ r: SubmitResponse) async -> SubmitResponse {
        func author(_ reason: RejectReason) -> ClientID? { if case .conflict(let c) = reason { return c.by }; return nil }
        var any = false
        for res in r.results { if case .reject(_, let reason) = res, author(reason) != nil { any = true } }
        for reason in (r.known?.rejected.values.map { $0 } ?? []) where author(reason) != nil { any = true }
        guard any else { return r }
        let table = (try? await clientNames()) ?? directory.mapValues(\.name)
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

    // MARK: - Replace (POST /replace)

    /// What a replacement writes besides its ops.
    struct ReplaceWork: Sendable {
        var ops: [Op]
        /// New import metadata (nil = unchanged).
        var metadata: Value?
        var secrets: [String: String] = [:]
        var agentConfig: AgentConfigCommit? = nil
    }

    struct ReplaceOutcome: Sendable {
        var head: Int
        /// Ops committed (by this request, or by the earlier request a replay found).
        var ops: Int
        var doc: Document
        /// The client's next cseq after the replacement.
        var nextCseq: Int
        /// A retry of a replacement that was already committed: nothing was planned or written now.
        var replayed: Bool
    }

    /// Replaces the document's content in ONE transaction: `plan` gets the document at head and that head, and returns the
    /// ops (plus metadata and secrets) to commit as `client`'s cseqs `cseq, cseq + 1, ...` with base = head. Runs under the
    /// document's mutual exclusion, so nothing can commit between planning and committing in this process; another process
    /// committing meanwhile makes the commit's revision check fail, and the replacement is re-planned on fresh state.
    /// Either every op is committed or none (`409 conflict` if the sequencer refused one, which a correct plan never causes).
    ///
    /// `cseq` must be the client's next cseq (`high + 1`): `409 outstanding_ops` above it (the client has ops the server has
    /// not handled yet), and below it the request is a retry: if `cseq...high` are all committed ops (what a replacement
    /// leaves) it is answered as the earlier success (`replayed`), else `409 cseq_used`.
    func replace<Info: Sendable>(client: ClientID, cseq: Int,
                                 plan: @Sendable (Document, Int) async throws -> (ReplaceWork, Info)) async throws -> (ReplaceOutcome, Info?) {
        try await exclusive {
            var attempts = 0
            while true {
                attempts += 1
                var live = try await ensureLoaded()
                let high: Int
                if let h = live.highs[client] {
                    high = h
                } else {
                    do { high = try await store.clientHigh(docId, client: client) } catch { throw ServerError.unavailable("\(error)") }
                }
                let head = live.core.seq
                if cseq <= high {
                    let known: KnownOutcomes
                    do { known = try await store.knownOutcomes(docId, client: client, range: cseq...high) } catch {
                        throw ServerError.unavailable("\(error)")
                    }
                    guard known.rejected.isEmpty, known.committed.count == high - cseq + 1 else {
                        throw ServerError.http(status: 409, code: "cseq_used",
                                               message: "cseq \(cseq) is already used by this client; its next cseq is \(high + 1)")
                    }
                    return (ReplaceOutcome(head: head, ops: known.committed.count, doc: live.core.doc, nextCseq: high + 1, replayed: true), nil)
                }
                if cseq > high + 1 {
                    throw ServerError.http(status: 409, code: "outstanding_ops",
                                           message: "the server has handled this client's cseqs up to \(high): wait until its ops are resolved, then send cseq \(high + 1)")
                }
                let (work, info) = try await plan(live.core.doc, head)
                if work.ops.isEmpty && work.metadata == nil && work.secrets.isEmpty && work.agentConfig == nil {
                    // Nothing to commit, so no revision check either: make sure "nothing to do" was decided on current state.
                    let rev: Int?
                    do { rev = try await store.documentRevision(docId) } catch { throw ServerError.unavailable("\(error)") }
                    if rev != live.rev {
                        state = nil
                        if attempts >= 25 { throw ServerError.unavailable("document is contended") }
                        continue
                    }
                    return (ReplaceOutcome(head: head, ops: 0, doc: live.core.doc, nextCseq: cseq, replayed: false), info)
                }
                var working = live.core
                let req = SubmitRequest(client: client, ops: work.ops.enumerated().map { IncomingOp(cseq: cseq + $0.offset, base: head, op: $0.element) })
                let batch = working.process(req, clientHigh: high, known: KnownOutcomes())
                guard batch.rejections.isEmpty, batch.entries.count == work.ops.count else {
                    let why = batch.rejections.sorted { $0.key < $1.key }.first.map { "cseq \($0.key): \($0.value)" } ?? "not every op was sequenced"
                    logger.error("document \(docId): replacement refused by the sequencer (\(why)); nothing committed")
                    throw ServerError.http(status: 409, code: "conflict", message: "the replacement was refused (\(why)); 0 ops committed")
                }
                let snapshot = Sequencer.snapshotDue(oldSeq: live.core.seq, newSeq: working.seq, every: config.snapshotEvery) ? working.snapshot : nil
                let newRev: Int
                do {
                    newRev = try await store.commit(doc: docId, expectedRev: live.rev, groups: batch.isEmpty ? [] : [.init(client: client, batch: batch)],
                                                    newHead: working.seq, snapshot: snapshot, metadata: work.metadata, secrets: work.secrets, agentConfig: work.agentConfig)
                } catch StoreError.revisionMismatch {
                    state = nil
                    logger.warning("document \(docId): revision changed under a replacement, re-planning (attempt \(attempts))")
                    if attempts >= 25 { throw ServerError.unavailable("document is contended") }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 1...(5 * attempts))))
                    continue
                } catch StoreError.notCommitted(let why) {
                    throw ServerError.unavailable("not committed: \(why)")
                } catch {
                    state = nil
                    logger.error("document \(docId): replacement commit outcome unknown: \(error)")
                    throw ServerError.unavailable("commit outcome unknown")
                }
                live.core = working
                live.rev = newRev
                if batch.highChanged { live.highs[client] = batch.newHigh }
                state = live
                for e in batch.entries { broadcast(e) }
                published = working.seq
                return (ReplaceOutcome(head: working.seq, ops: batch.entries.count, doc: working.doc,
                                       nextCseq: cseq + batch.entries.count, replayed: false), info)
            }
        }
    }

    private func broadcast(_ entry: LogEntry) {
        guard !subs.isEmpty, let frame = try? StreamEvent.commit(entry).sseFrame() else { return }
        for (id, proto) in legacySubs where !StreamCompat.streamCarries(entry.op, proto: proto) {
            // An older client cannot decode this op: end its stream. It reconnects from its last seq and, because the
            // range contains this entry, is caught up with a snapshot.
            subs[id]?.finish()
            subs[id] = nil
            legacySubs[id] = nil
        }
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
    func subscribe(lastEventId: Int?, maxReplay: Int, proto: String? = protocolVersion) async throws -> Subscription {
        let legacy = !StreamCompat.acceptsAll(proto)
        return try await exclusive {
            let live = try await ensureLoaded()
            let head = live.core.seq
            let plan = resumePlan(lastEventId: lastEventId, head: head, maxReplay: maxReplay)
            let (stream, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2000))
            nextSub += 1
            let id = nextSub
            subs[id] = cont
            if legacy { legacySubs[id] = .some(proto) }
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(id) }
            }
            var doc: Document?
            if plan == .snapshot || legacy { doc = live.core.doc }  // copy-on-write: no copy is made here
            return Subscription(id: id, head: head, plan: plan, doc: doc, live: stream)
        }
    }

    func unsubscribe(_ id: Int) {
        subs[id]?.finish()
        subs[id] = nil
        legacySubs[id] = nil
    }

    /// Tells every stream of this process that a canvas comment changed (`event: comments`, no `id:`). Best-effort: it
    /// neither loads the document nor touches `published`, so the commit stream and every resume point are unaffected.
    /// Streams of every protocol version get it (clients that do not know the event ignore it).
    func announceComment(_ event: CommentsEvent) {
        guard !subs.isEmpty, let frame = try? event.sseFrame() else { return }
        announce(frame)
    }

    /// Tells every stream of this process that the document's app changed (`event: app`, no `id:`), with the same
    /// best-effort rules as `announceComment`.
    func announceApp(_ event: AppEvent) {
        guard !subs.isEmpty, let frame = try? event.sseFrame() else { return }
        announce(frame)
    }

    private func announce(_ frame: String) {
        for (id, c) in subs {
            if case .dropped = c.yield(frame) {
                c.finish()
                subs[id] = nil
                legacySubs[id] = nil
            }
        }
    }

    func ping() {
        for (id, c) in subs {
            if case .dropped = c.yield(": ping\n\n") {
                c.finish()
                subs[id] = nil
            }
        }
    }

    /// Protocol 1.10: the app was deleted. Ends every stream (a reconnect gets `404 app_deleted`), forgets the state and
    /// refuses everything from now on.
    func markDeleted() {
        deleted = true
        state = nil
        finishAllStreams()
    }

    func finishAllStreams() {
        for (_, c) in subs { c.finish() }
        subs = [:]
        legacySubs = [:]
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

    /// The sequencer of document `id` if this process has one (never creates one).
    func existing(_ id: String) -> DocumentSequencer? { docs[id] }

    /// Protocol 1.10: document `id`'s app was deleted: its sequencer ends its streams, refuses everything and is dropped.
    func evict(_ id: String) async {
        guard let s = docs.removeValue(forKey: id) else { return }
        await s.markDeleted()
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
