import CollabCore
import Foundation

/// Who has one document open (protocol 1.22, "Presence"): per client its pointer on the canvas and the node whose panel it
/// has open, in memory only. Streams of this process get the merged state per account: one full event right after `ready`
/// (`fullFrame`), then at most every `flushEvery` the accounts that appeared, changed or left. Nothing here is durable: a
/// restart forgets everyone and clients re-announce within a heartbeat.
actor PresenceRoom {
    /// A client not heard from for this long is gone (clients send a heartbeat at least every 10 s).
    static let ttl: Duration = .seconds(30)
    /// After the client's stream ends it stays this long, so a reconnect (which re-announces) shows no leave and join.
    static let streamGrace: Duration = .seconds(5)
    static let flushEvery: Duration = .milliseconds(100)

    struct Entry {
        var account: String
        var name: String
        var avatar: String?
        var cursor: PresencePoint?
        var drag: PresenceDrag?
        var panel: String?
        /// When the client was last heard from.
        var seen: ContinuousClock.Instant
        /// When its cursor or drag last changed (nil: never reported): the account shows its most recently moved cursor.
        var cursorAt: ContinuousClock.Instant?
        /// When the client appeared (Unix milliseconds).
        var joined: Int64
        /// Gone at this instant unless heard from again (`seen + ttl`, or sooner once its stream ended).
        var expires: ContinuousClock.Instant
    }

    private let announce: @Sendable (String) async -> Void
    private let ttl: Duration
    private let grace: Duration
    /// nil: no timer, `flush()` sends (tests).
    private let flushEvery: Duration?
    private let clock = ContinuousClock()
    private var entries: [String: Entry] = [:]
    /// What the streams were last told, per account.
    private var sent: [String: PresenceUser] = [:]
    private var dirty = false
    /// The latest stream of each client that has one open (`streamStarted`).
    private var streams: [String: Int] = [:]
    private var nextStream = 0
    /// Clients that said goodbye, and when (forgotten after `ttl`, or when the client opens a new stream).
    private var gone: [String: ContinuousClock.Instant] = [:]
    private var loop: Task<Void, Never>?

    init(ttl: Duration = PresenceRoom.ttl, streamGrace: Duration = PresenceRoom.streamGrace,
         flushEvery: Duration? = PresenceRoom.flushEvery, announce: @escaping @Sendable (String) async -> Void) {
        self.ttl = ttl
        self.grace = streamGrace
        self.flushEvery = flushEvery
        self.announce = announce
    }

    /// A client's report. `cursor` / `drag` / `panel`: `nil` = unchanged, `.some(nil)` = cleared. Ignored from a client
    /// that said goodbye, until it opens a new stream: a report it sent just before closing may arrive after the goodbye.
    func update(client: String, account: String, name: String, avatar: String?, cursor: PresencePoint??,
                drag: PresenceDrag?? = nil, panel: String??) {
        let now = clock.now
        if let at = gone[client] {
            if now - at < ttl { return }
            gone[client] = nil
        }
        var e = entries[client] ?? Entry(
            account: account, name: name, avatar: avatar, cursor: nil, drag: nil, panel: nil, seen: now, cursorAt: nil,
            joined: Int64(Date().timeIntervalSince1970 * 1000), expires: now + ttl)
        e.account = account
        e.name = name
        e.avatar = avatar
        e.seen = now
        e.expires = now + ttl
        if let c = cursor, c != e.cursor || e.cursorAt == nil {
            e.cursor = c
            e.cursorAt = now
        }
        if let d = drag, d != e.drag {
            e.drag = d
            e.cursorAt = now
        }
        if let p = panel { e.panel = p }
        entries[client] = e
        dirty = true
        startLoop()
    }

    /// The client said it is gone (`DELETE .../presence`).
    func remove(client: String) {
        gone[client] = clock.now
        if entries.removeValue(forKey: client) != nil { dirty = true }
        // Also when the goodbye came first: the record of it is dropped after `ttl` by the loop.
        startLoop()
    }

    /// A stream of [client] opened; [streamEnded] takes the token back. A reconnecting client opens its new stream
    /// before its old one is noticed to have ended.
    func streamStarted(client: String) -> Int {
        gone[client] = nil
        nextStream += 1
        streams[client] = nextStream
        return nextStream
    }

    /// The client's stream [token] ended: gone after `streamGrace` unless it reports again (a reconnect does). The end of
    /// an older stream, once the client has opened a newer one, changes nothing: the client is still here.
    func streamEnded(client: String, stream token: Int) {
        guard streams[client] == token else { return }
        streams[client] = nil
        guard var e = entries[client] else { return }
        e.expires = min(e.expires, clock.now + grace)
        entries[client] = e
    }

    /// Everyone present, for a stream that just became ready.
    func fullFrame() -> String? {
        try? PresenceEvent(full: true, users: Self.ordered(merged())).sseFrame()
    }

    var clientCount: Int { entries.count }
    var goneCount: Int { gone.count }

    private func merged() -> [String: PresenceUser] {
        var groups: [String: [Entry]] = [:]
        for e in entries.values { groups[e.account, default: []].append(e) }
        var users: [String: PresenceUser] = [:]
        for (account, es) in groups {
            let latest = es.max { $0.seen < $1.seen }!
            let moved = es.filter { $0.cursorAt != nil }.max { $0.cursorAt! < $1.cursorAt! }
            users[account] = PresenceUser(
                account: account, name: latest.name, avatar_url: latest.avatar, cursor: moved?.cursor, drag: moved?.drag,
                panels: Array(Set(es.compactMap(\.panel))).sorted(), since: es.map(\.joined).min()!)
        }
        return users
    }

    private static func ordered(_ users: [String: PresenceUser]) -> [PresenceUser] {
        users.values.sorted { ($0.since, $0.account) < ($1.since, $1.account) }
    }

    /// Expires and sends now (a room made without a timer).
    func flush() async {
        _ = await tick()
    }

    private func startLoop() {
        guard loop == nil, let every = flushEvery else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let self, await self.tick() else { return }
            }
        }
    }

    /// Expires silent clients and tells the streams what changed. False (and the loop ends) once nobody is left to tell.
    private func tick() async -> Bool {
        let now = clock.now
        for (client, e) in entries where e.expires <= now {
            entries[client] = nil
            dirty = true
        }
        gone = gone.filter { now - $0.value < ttl }
        if dirty {
            dirty = false
            let users = merged()
            let changed = users.filter { sent[$0.key] != $0.value }
            let left = sent.keys.filter { users[$0] == nil }.sorted()
            sent = users
            if !changed.isEmpty || !left.isEmpty,
               let frame = try? PresenceEvent(full: false, users: Self.ordered(changed), left: left).sseFrame() {
                await announce(frame)
            }
        }
        if entries.isEmpty && sent.isEmpty && !dirty && gone.isEmpty {
            loop = nil
            return false
        }
        return true
    }
}
