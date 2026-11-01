import CollabCore
import CollabStore
import Foundation
import Testing

@testable import CollabServer

/// Protocol 1.22 presence: the in-memory room (merging per account, deltas, expiry) and the routes.
@Suite struct PresenceTests {
    /// Time the test moves by hand: expiry must not depend on how fast the machine runs the suite.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { t } }
        func advance(_ d: Duration) { lock.withLock { t += d } }
    }

    /// Waits (real time, generously) until [condition] holds; the room's own loop does the work.
    static func eventually(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(600)
        while !(await condition()), clock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }
    /// Collects the frames a room announces.
    actor Frames {
        var all: [PresenceEvent] = []
        func add(_ frame: String) {
            guard let data = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
                  let e = try? WireJSON.decode(PresenceEvent.self, from: String(data)) else { return }
            all.append(e)
        }
    }

    @Test func mergesClientsPerAccountAndSendsOnlyWhatChanged() async throws {
        let frames = Frames()
        let room = PresenceRoom(flushEvery: nil) { await frames.add($0) }
        // Two tabs of Maya, one of Bo, in one flush: one delta with both accounts.
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: PresencePoint(x: 1, y: 2), panel: .some(nil))
        await room.update(client: "m2", account: "maya", name: "Maya", avatar: nil, cursor: nil, panel: "llm")
        await room.update(client: "b1", account: "bo", name: "Bo", avatar: "/a.png", cursor: PresencePoint(x: 5, y: 5), panel: nil)
        await room.flush()
        var got = await frames.all
        try #require(got.count == 1)
        #expect(got[0].full == false && got[0].left.isEmpty)
        let maya = got[0].users.first { $0.account == "maya" }
        #expect(maya?.cursor == PresencePoint(x: 1, y: 2) && maya?.panels == ["llm"] && maya?.name == "Maya")
        #expect(got[0].users.first { $0.account == "bo" }?.avatar_url == "/a.png")
        // The other tab moves: Maya's cursor is the most recently moved one; Bo is unchanged and not resent.
        await room.update(client: "m2", account: "maya", name: "Maya", avatar: nil, cursor: PresencePoint(x: 9, y: 9), panel: nil)
        await room.flush()
        got = await frames.all
        try #require(got.count == 2)
        #expect(got[1].users.map(\.account) == ["maya"] && got[1].users.first?.cursor == PresencePoint(x: 9, y: 9))
        // A heartbeat with nothing new: no frame.
        await room.update(client: "b1", account: "bo", name: "Bo", avatar: "/a.png", cursor: nil, panel: nil)
        await room.flush()
        #expect(await frames.all.count == 2)
        // Panels of both tabs, then one tab leaves: still present, one panel less; then the last leaves: `left`.
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: nil, panel: "code")
        await room.flush()
        await room.remove(client: "m2")
        await room.flush()
        await room.remove(client: "m1")
        await room.flush()
        got = await frames.all
        try #require(got.count == 5)
        #expect(got[2].users.first?.panels == ["code", "llm"])
        #expect(got[3].users.first?.panels == ["code"] && got[3].left.isEmpty)
        #expect(got[4].users.isEmpty && got[4].left == ["maya"])
        // The full frame: everyone present, ordered by arrival.
        let full = await room.fullFrame()
        #expect(full?.contains("\"full\":true") == true && full?.contains("\"account\":\"bo\"") == true)
        #expect(full?.contains("maya") == false)
    }

    @Test func aDragGoesWithTheAccountsPointer() async throws {
        let frames = Frames()
        let room = PresenceRoom(flushEvery: nil) { await frames.add($0) }
        let held = PresenceDrag(node: "llm", x: 40, y: 12)
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: PresencePoint(x: 1, y: 1), panel: nil)
        await room.update(client: "m2", account: "maya", name: "Maya", avatar: nil, cursor: PresencePoint(x: 5, y: 5), drag: .some(held), panel: nil)
        await room.flush()
        var got = await frames.all
        #expect(got.last?.users.first?.drag == held && got.last?.users.first?.cursor == PresencePoint(x: 5, y: 5))
        // The other tab's pointer moves: it is shown, without the drag (that tab drags nothing).
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: PresencePoint(x: 2, y: 2), panel: nil)
        await room.flush()
        got = await frames.all
        #expect(got.last?.users.first?.drag == nil && got.last?.users.first?.cursor == PresencePoint(x: 2, y: 2))
        // The dragging tab lets go where its pointer is.
        await room.update(client: "m2", account: "maya", name: "Maya", avatar: nil, cursor: PresencePoint(x: 9, y: 9), drag: .some(nil), panel: nil)
        await room.flush()
        got = await frames.all
        try #require(got.count == 3)
        #expect(got[2].users.first?.drag == nil && got[2].users.first?.cursor == PresencePoint(x: 9, y: 9))
    }

    @Test func aReportArrivingAfterTheGoodbyeIsIgnoredUntilANewStream() async throws {
        let frames = Frames()
        let room = PresenceRoom(flushEvery: nil) { await frames.add($0) }
        _ = await room.streamStarted(client: "m1")
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: nil, panel: "llm")
        await room.flush()
        // The editor closes: goodbye, then a report it had sent just before arrives late.
        await room.remove(client: "m1")
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: nil, panel: "code")
        await room.flush()
        #expect(await frames.all.last?.left == ["maya"])
        #expect(await room.clientCount == 0)
        // The same client id opens the document again (a reload): its reports count again.
        _ = await room.streamStarted(client: "m1")
        await room.update(client: "m1", account: "maya", name: "Maya", avatar: nil, cursor: nil, panel: "code")
        await room.flush()
        #expect(await frames.all.last?.users.first?.panels == ["code"])
    }

    @Test func aGoodbyeBeforeAnyReportIsForgottenAfterTheTtl() async throws {
        let frames = Frames()
        let clock = ManualClock()
        // The loop's own timer never fires during the test (an hour): the test runs its passes itself.
        let room = PresenceRoom(ttl: .seconds(30), flushEvery: .seconds(3600), now: { clock.now }) { await frames.add($0) }
        await room.remove(client: "x1")
        // The goodbye starts the loop even though the client never reported: the loop is what forgets the goodbye.
        #expect(await room.loopRunning)
        await room.update(client: "x1", account: "xu", name: "Xu", avatar: nil, cursor: nil, panel: "llm")
        #expect(await room.clientCount == 0)
        await room.flush()
        #expect(await room.goneCount == 1)
        clock.advance(.seconds(31))
        await room.flush()
        #expect(await room.goneCount == 0)
        #expect(await frames.all.isEmpty)
    }

    @Test func silentClientsExpireAndAnEndedStreamOnlyHasAGracePeriod() async throws {
        let frames = Frames()
        let clock = ManualClock()
        let room = PresenceRoom(ttl: .seconds(30), streamGrace: .seconds(5), flushEvery: nil, now: { clock.now }) {
            await frames.add($0)
        }
        var streams: [String: Int] = [:]
        for (client, account) in [("a", "ann"), ("b", "ben"), ("c", "cy"), ("d", "dee")] {
            streams[client] = await room.streamStarted(client: client)
            await room.update(client: client, account: account, name: account, avatar: nil, cursor: nil, panel: nil)
        }
        await room.flush()
        // Ben's stream ends for good; Cy's ends and Cy reconnects (reports again) within the grace period.
        await room.streamEnded(client: "b", stream: streams["b"]!)
        await room.streamEnded(client: "c", stream: streams["c"]!)
        await room.update(client: "c", account: "cy", name: "cy", avatar: nil, cursor: nil, panel: nil)
        // Dee reconnects the other way round: the new stream opens and she reports before the old stream's end is
        // noticed. That late end must not make her leave.
        _ = await room.streamStarted(client: "d")
        await room.update(client: "d", account: "dee", name: "dee", avatar: nil, cursor: nil, panel: nil)
        await room.streamEnded(client: "d", stream: streams["d"]!)
        clock.advance(.seconds(6))
        await room.flush()
        #expect(await frames.all.flatMap(\.left) == ["ben"])
        // Nobody reports any more: Ann, Cy and Dee expire after the ttl.
        clock.advance(.seconds(30))
        await room.flush()
        #expect(Set(await frames.all.flatMap(\.left)) == ["ann", "ben", "cy", "dee"])
        #expect(await room.clientCount == 0)
    }
}

/// The routes, against a real Postgres (TEST_DB_HOST, server/run-db-tests.sh).
@Suite("Presence routes", .enabled(if: testDbHost != nil)) struct PresenceRouteTests {
    static func freshDoc(_ store: PostgresStore) async throws -> String {
        let id = "t-\(UUID().uuidString.lowercased().prefix(12))"
        _ = try await store.createDocument(id: id, initial: Document(nodes: []))
        return id
    }

    @Test func routesNeedTheEditRoleAndOwnClientAndReachTheStream() async throws {
        try await withServer { api, store, registry in
            let olivia = try await api.setupOwner()
            let oliviaId = try await api.get("/v1/account", token: olivia).str("id")
            let (bobId, bob) = try await api.member("bob@example.com", role: "editor", name: "Bob", inviter: olivia)
            let (_, nora) = try await api.member("nora@example.com", role: "normal", name: "Nora", inviter: olivia)
            let doc = try await Self.freshDoc(store)
            let path = "/v1/docs/\(doc)/presence"
            let seqr = await registry.sequencer(doc)
            let sub = try await seqr.subscribe(lastEventId: 0, maxReplay: 100)
            let room = await registry.presence(doc)
            // The stream's presence events, until Bob's leaving arrives (or a generous deadline ends the stream).
            let collector = Task { () -> [PresenceEvent] in
                var events: [PresenceEvent] = []
                for await f in sub.live {
                    #expect(!f.contains("id: "))
                    if let d = f.split(separator: "\n").first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
                       let e = try? WireJSON.decode(PresenceEvent.self, from: String(d)) {
                        events.append(e)
                        if e.left.contains(bobId) { break }
                    }
                }
                return events
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(120))
                await seqr.unsubscribe(sub.id)
            }

            let put = try await api.put(
                path, #"{"client":"c-olivia","cursor":{"x":12.5,"y":-3},"drag":{"node":"llm","x":40,"y":8},"panel":"llm"}"#,
                token: olivia)
            #expect(put.status == 204, "\(put.text)")
            // A read-only member may not report; another account's client id is refused; bad bodies are 400.
            #expect(try await api.put(path, #"{"client":"c-nora","cursor":null}"#, token: nora).status == 403)
            #expect(try await api.put(path, #"{"client":"c-olivia","cursor":null}"#, token: bob).status == 403)
            #expect(try await api.put(path, #"{"client":"c-bob","cursor":{"x":"a","y":1}}"#, token: bob).status == 400)
            #expect(try await api.put(path, #"{"client":"c-bob","panel":""}"#, token: bob).status == 400)
            #expect(try await api.put(path, #"{"client":"c-bob","drag":{"node":"","x":1,"y":1}}"#, token: bob).status == 400)
            #expect(try await api.put(path, #"{"client":"c-bob","drag":{"node":"llm","x":1}}"#, token: bob).status == 400)
            #expect(try await api.put("/v1/docs/t-nope-\(UUID().uuidString.prefix(8))/presence", #"{"client":"c-x"}"#, token: bob).status == 404)
            #expect(try await api.put(path, #"{"client":"c-bob","cursor":{"x":1,"y":1}}"#, token: bob).status == 204)
            try await PresenceTests.eventually { await room.announced(bobId) }  // announced before he leaves
            #expect(try await api.delete("\(path)?client=c-bob", token: olivia).status == 403)
            #expect(try await api.delete("\(path)?client=c-bob", token: bob).status == 204)

            // The stream got a delta with Olivia (and Bob), then Bob left; nothing with an id.
            let events = await collector.value
            deadline.cancel()
            await seqr.unsubscribe(sub.id)
            let olive = events.flatMap(\.users).first { $0.account == oliviaId }
            #expect(olive?.name == "Olivia" && olive?.cursor == PresencePoint(x: 12.5, y: -3) && olive?.panels == ["llm"])
            #expect(olive?.drag == PresenceDrag(node: "llm", x: 40, y: 8))
            #expect(events.flatMap(\.left).count == 1)
            let full = await registry.presence(doc).fullFrame()
            #expect(full?.contains(oliviaId) == true && full?.contains("Bob") == false)
        }
    }
}
