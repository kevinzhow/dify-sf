import CollabCore
import Foundation

/// Where a client keeps what must survive a process crash (the write-ahead journal or just the counters).
public protocol DurableStorage: Sendable {
    func load() -> ClientDurable?
    func save(_ d: ClientDurable)
}

/// One JSON file, replaced atomically (write temp, fsync, rename), so a kill -9 never leaves a torn file.
public struct FileDurableStorage: DurableStorage {
    public let path: String
    public init(path: String) { self.path = path }

    public func load() -> ClientDurable? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ClientDurable.self, from: data)
    }

    public func save(_ d: ClientDurable) {
        guard let data = try? JSONEncoder().encode(d) else { return }
        let tmp = path + ".tmp"
        guard let fh = FileHandle(forWritingAtPath: tmp) ?? {
            FileManager.default.createFile(atPath: tmp, contents: nil)
            return FileHandle(forWritingAtPath: tmp)
        }() else { return }
        try? fh.truncate(atOffset: 0)
        try? fh.write(contentsOf: data)
        try? fh.synchronize()
        try? fh.close()
        rename(tmp, path)
    }
}

public struct DriverHooks: Sendable {
    /// A new op was created (called after the journal was persisted, before the op is sent).
    public var issued: @Sendable (_ cseq: Int, _ base: Int, _ op: Op) -> Void
    /// A terminal or advisory event for the user.
    public var event: @Sendable (ClientEvent) -> Void
    /// Server seqs `first...last` just became part of the confirmed document, at the given wall-clock millis.
    public var applied: @Sendable (_ first: Int, _ last: Int, _ wallMillis: Int64) -> Void

    public init(issued: @escaping @Sendable (Int, Int, Op) -> Void = { _, _, _ in },
                event: @escaping @Sendable (ClientEvent) -> Void = { _ in },
                applied: @escaping @Sendable (Int, Int, Int64) -> Void = { _, _, _ in }) {
        self.issued = issued
        self.event = event
        self.applied = applied
    }
}

/// Client-side fault injection (the duplicate-POST faults of the chaos harness).
public struct DriverFaults: Sendable {
    /// Probability that a POST is sent twice back-to-back.
    public var duplicatePostRate = 0.0
    /// Probability that, after a POST, an OLD request (one already answered) is replayed as well.
    public var replayOldRate = 0.0
    public init(duplicatePostRate: Double = 0, replayOldRate: Double = 0) {
        self.duplicatePostRate = duplicatePostRate
        self.replayOldRate = replayOldRate
    }
}

public struct DriverStats: Sendable, Codable {
    public var posts = 0
    public var postFailures = 0
    public var streamsOpened = 0
    public var streamsLost = 0
    public var snapshots = 0
    public var commits = 0
    /// Round-trip time of successful POSTs in milliseconds (all of them; the harness reports percentiles).
    public var postMillis: [Int] = []
    /// Gaps in milliseconds between consecutive stream events that carried data while a commit was pending (diagnostics).
}

/// Runs the pure `Client` state machine against real HTTP/SSE: executes its requests, feeds back responses
/// and stream events, drives its timers, and persists its durable state.
public actor ClientDriver {
    public let id: ClientID
    private var client: Client
    private let transport: HTTPTransport
    private let storage: DurableStorage?
    private let hooks: DriverHooks
    private let tickEvery: Duration
    private let postTimeout: Duration
    private let faults: DriverFaults
    private var recent: [SubmitRequest] = []
    private var faultRng = SystemRandomNumberGenerator()
    private let started = ContinuousClock.now
    private var lastPersisted: ClientDurable?
    private var postTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var stopped = false
    public private(set) var stats = DriverStats()

    public init(id: ClientID, journaled: Bool, transport: HTTPTransport, storage: DurableStorage?, hooks: DriverHooks,
                config: ClientConfig, faults: DriverFaults = DriverFaults(), tickEvery: Duration = .milliseconds(50), postTimeout: Duration = .seconds(10)) {
        self.faults = faults
        self.id = id
        self.transport = transport
        self.storage = storage
        self.hooks = hooks
        self.tickEvery = tickEvery
        self.postTimeout = postTimeout
        if let d = storage?.load() {
            client = Client(restoring: d, journaled: journaled, config: config)
            lastPersisted = d
        } else {
            client = Client(id: id, journaled: journaled, config: config)
        }
    }

    private func now() -> Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }
    private static func wall() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Lifecycle

    public func start() {
        // Journaled ops that survived a crash are issued ops too (the crash may have hit before they were logged).
        let d = client.durable
        for j in d.journal { hooks.issued(j.cseq, j.base, j.op) }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.tickEvery ?? .milliseconds(50))
            }
        }
        tick()
    }

    public func stop() async {
        stopped = true
        tickTask?.cancel()
        postTask?.cancel()
        streamTask?.cancel()
        await transport.shutdown()
    }

    private func tick() {
        guard !stopped else { return }
        let reqs = client.tick(now: now())
        afterMutation(reqs)
    }

    // MARK: - User API

    public func edit(_ op: Op) -> Int? {
        guard !stopped else { return nil }
        let base = client.lastSeq
        let r = client.edit(op, now: now())
        for ev in client.drainEvents() { hooks.event(ev) }
        guard let cseq = r.cseq else { return nil }
        persistIfChanged()                   // write-ahead: journal first,
        hooks.issued(cseq, base, op)         // then the ledger,
        perform(r.requests)                  // then the network
        return cseq
    }

    public var view: Document { client.view }
    public var confirmed: Document { client.confirmed }
    public var lastSeq: Int { client.lastSeq }
    public var hasState: Bool { client.hasState }
    public var unresolved: Int { client.unresolvedCount }
    public var isQuiescent: Bool { client.isQuiescent }
    public var violations: [String] { client.violations }
    public var debug: [String] { client.debugOutbox }

    /// Tell the client the network is (probably) back.
    public func networkAvailable() {
        let reqs = client.networkAvailable(now: now())
        afterMutation(reqs)
    }

    // MARK: - Transport callbacks

    private func perform(_ requests: [ClientRequest]) {
        for r in requests {
            switch r {
            case .submit(let req):
                postTask?.cancel()
                stats.posts += 1
                injectDuplicates(of: req)
                postTask = Task { [transport, postTimeout, weak self] in
                    do {
                        let t0 = ContinuousClock.now
                        let resp = try await transport.post(req, timeout: postTimeout)
                        await self?.didRespond(resp, millis: Int((ContinuousClock.now - t0) / .milliseconds(1)))
                    } catch is CancellationError {
                    } catch {
                        await self?.didFailPost(error)
                    }
                }
            case .openStream(let o):
                streamTask?.cancel()
                stats.streamsOpened += 1
                streamTask = Task { [transport, me = self] in
                    do {
                        try await transport.stream(o, headTimeout: .seconds(10)) { ev in await me.didReceive(ev, generation: o.generation) }
                    } catch {}
                    if !Task.isCancelled { await me.didLoseStream(generation: o.generation) }
                }
            }
        }
    }

    /// Fault injection: send the same request twice, or replay an old one. Responses are fed back like any other.
    private func injectDuplicates(of req: SubmitRequest) {
        if faults.duplicatePostRate > 0, Double.random(in: 0..<1, using: &faultRng) < faults.duplicatePostRate {
            sendExtra(req)
        }
        if faults.replayOldRate > 0, !recent.isEmpty, Double.random(in: 0..<1, using: &faultRng) < faults.replayOldRate {
            sendExtra(recent.randomElement(using: &faultRng)!)
        }
        recent.append(req)
        if recent.count > 20 { recent.removeFirst() }
    }

    private func sendExtra(_ req: SubmitRequest) {
        stats.posts += 1
        Task { [transport, postTimeout, me = self] in
            if let resp = try? await transport.post(req, timeout: postTimeout) { await me.didRespond(resp) }
        }
    }

    private func didRespond(_ resp: SubmitResponse, millis: Int? = nil) {
        guard !stopped else { return }
        if let millis { stats.postMillis.append(millis) }
        let reqs = client.receive(resp, now: now())
        afterMutation(reqs)
    }

    private func didFailPost(_ error: Error) {
        guard !stopped else { return }
        stats.postFailures += 1
        if case TransportError.status(let code, let body) = error, code == 400 {
            FileHandle.standardError.write(Data("client \(id): server rejected the request (400): \(body)\n".utf8))
        }
        client.submitFailed(now: now())
    }

    private func didReceive(_ ev: StreamEvent, generation: Int) {
        guard !stopped else { return }
        let before = client.lastSeq
        let wasState = client.hasState
        let reqs = client.receive(ev, generation: generation, now: now())
        let after = client.lastSeq
        switch ev {
        case .snapshot: stats.snapshots += 1
        case .commit: stats.commits += 1
        default: break
        }
        if after != before || (!wasState && client.hasState) {
            hooks.applied(min(before, after) + 1, after, Self.wall())
        }
        afterMutation(reqs)
    }

    private func didLoseStream(generation: Int) {
        guard !stopped else { return }
        stats.streamsLost += 1
        client.streamClosed(generation: generation, now: now())
    }

    private func afterMutation(_ reqs: [ClientRequest]) {
        for ev in client.drainEvents() { hooks.event(ev) }  // report first ...
        persistIfChanged()                                   // ... then persist (at-least-once across crashes)
        perform(reqs)
    }

    private func persistIfChanged() {
        guard let storage else { return }
        let d = client.durable
        if d != lastPersisted {
            storage.save(d)
            lastPersisted = d
        }
    }
}
