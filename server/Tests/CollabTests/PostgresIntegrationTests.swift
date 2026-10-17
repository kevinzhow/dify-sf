import CollabCore
import CollabDSL
import CollabStore
import Foundation
import Logging
import PostgresNIO
import Testing
import VaporTesting
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

    @Test func aRestoreIsDurableAndOldStreamsAreCaughtUpWithASnapshot() async throws {
        try await withStore { store, logger in
            let doc = try await freshDoc(store, nodes: ["a", "b"])
            var cfg = ServerConfig.defaults
            cfg.snapshotEvery = 1000  // recovery replays the restore from the log
            let seqr = DocumentSequencer(docId: doc, store: store, config: cfg, logger: logger)
            let e = Edge(id: "e", source: "a", target: "b")
            let restore = Op.restoreNode(node("a"), edges: [e])
            let r = try await seqr.submit(req("c", [(1, 0, .addEdge(e)), (2, 1, .removeNode("a")), (3, 2, restore)]))
            #expect(r.results == [.ack(cseq: 1, seq: 1), .ack(cseq: 2, seq: 2), .ack(cseq: 3, seq: 3)])
            let restarted = DocumentSequencer(docId: doc, store: store, config: cfg, logger: logger)
            let snap = try await restarted.currentSnapshot()
            #expect(snap.seq == 3 && snap.doc.nodes["a"] == node("a") && snap.doc.edges["e"] == e && snap.doc.deletedNodes.isEmpty)
            #expect(try await store.entries(doc, after: 2, through: 3).map(\.op) == [restore])
            #expect(try await store.logContainsOp(doc, type: "restoreNode", after: 0, through: 3))
            #expect(try await store.logContainsOp(doc, type: "restoreNode", after: 2, through: 3))
            #expect(try await !store.logContainsOp(doc, type: "restoreNode", after: 3, through: 3))
            #expect(try await !store.logContainsOp(doc, type: "restoreNode", after: 0, through: 2))
            // An old (1.5) stream's replay would carry the restore: the route turns it into a snapshot; the
            // subscription captured the document for that.
            let sub = try await restarted.subscribe(lastEventId: 1, maxReplay: 100, proto: nil)
            #expect(sub.plan == .replay(after: 1) && sub.doc == snap.doc)
            await restarted.unsubscribe(sub.id)
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

    @Test func anImportedWorkflowKeepsItsDifyPartsAndExportsItsCurrentState() async throws {
        let yaml = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dify/basic_llm_chat_workflow.yml"), encoding: .utf8)
        let imported = try DifyDSL.importYAML(yaml)
        try await withStore { store, logger in
            let doc = "t-\(UUID().uuidString.lowercased().prefix(12))"
            #expect(try await store.createDocument(id: doc, initial: imported.document, metadata: imported.metadata))
            #expect(try await store.createDocument(id: doc, initial: Document(), metadata: nil) == false)  // retry: left alone
            #expect(try await store.documentMetadata(doc) == imported.metadata)
            let seqr = DocumentSequencer(docId: doc, store: store, config: ServerConfig.defaults, logger: logger)
            let llm = imported.document.nodes.values.first { $0.type == "llm" }!.id
            _ = try await seqr.submit(req("alice", [(1, 0, .setField(llm, .title, .string("Renamed")))]))
            let current = try await seqr.currentSnapshot().doc
            guard case .map(let top) = try DifyDSL.exportValue(current, metadata: try await store.documentMetadata(doc)!),
                  case .map(let app)? = top["app"], case .map(let wf)? = top["workflow"], case .map(let g)? = wf["graph"],
                  case .list(let nodes)? = g["nodes"] else { Issue.record("export shape"); return }
            guard case .map(let origTop) = imported.metadata, case .map(let origApp)? = origTop["app"] else { Issue.record("meta"); return }
            #expect(app == origApp)
            #expect(nodes.contains { if case .map(let n) = $0, case .map(let d)? = n["data"] { return d["title"] == .string("Renamed") }; return false })
            #expect(try await store.documentMetadata("t-never-imported") == nil)
        }
    }

    @Test func metaRouteServesTheAppMetadataWithSecretsBlanked() async throws {
        let yaml = """
        app: {name: Meta chat, mode: advanced-chat, icon: "🤖"}
        kind: app
        version: 0.3.1
        workflow:
          environment_variables:
          - {id: e1, name: api_key, value: sk-not-for-clients, value_type: secret}
          - {id: e2, name: region, value: eu, value_type: string}
          conversation_variables:
          - {id: c1, name: str, selector: [conversation, str], value: default, value_type: string}
          features: {opening_statement: hi}
          graph:
            nodes:
            - id: s
              data: {type: start, title: Start, variables: []}
            edges: []
        """
        try await withStore { store, logger in
            let registry = DocumentRegistry(store: store, config: ServerConfig.defaults, logger: logger)
            try await withApp(configure: { app in
                Routes(registry: registry, store: store, config: ServerConfig.defaults, logger: logger).register(on: app)
            }) { app in
                try await app.testing { client in
                    func meta(_ doc: String) async throws -> (Int, Value) {
                        let res = try await client.get("/v1/docs/\(doc)/meta")
                        return (res.status.code, try WireJSON.decode(Value.self, from: Data(try await res.body.requireString().utf8)))
                    }
                    let imported = "t-\(UUID().uuidString.lowercased().prefix(12))"
                    let put = try await client.put("/v1/docs/\(imported)/import") { $0.body = .init(string: yaml) }
                    #expect(put.status.code == 201)
                    let (status, body) = try await meta(imported)
                    #expect(status == 200)
                    guard case .map(let m) = body, case .map(let app)? = m["app"], case .list(let env)? = m["environment_variables"],
                          case .list(let conv)? = m["conversation_variables"] else { Issue.record("meta shape: \(body)"); return }
                    #expect(app["mode"] == .string("advanced-chat") && app["name"] == .string("Meta chat"))
                    func s(_ x: String) -> Value { .string(x) }
                    // 1.7: a secret is served masked (never the plaintext, never its reference).
                    #expect(env == [.map(["id": s("e1"), "name": s("api_key"), "value": s("sk-not************ts"), "value_type": s("secret")]),
                                    .map(["id": s("e2"), "name": s("region"), "value": s("eu"), "value_type": s("string")])])
                    #expect(conv.count == 1 && m["features"] == .map(["opening_statement": s("hi")]))
                    #expect(m["workflow"] == nil)

                    let plain = try await freshDoc(store)
                    let (s2, b2) = try await meta(plain)
                    guard case .map(let d) = b2, case .map(let dApp)? = d["app"] else { Issue.record("default shape: \(b2)"); return }
                    #expect(s2 == 200 && dApp["mode"] == .string("workflow") && d["environment_variables"] == .list([]))

                    let (s3, _) = try await meta("t-never-created-\(UUID().uuidString.lowercased().prefix(8))")
                    #expect(s3 == 404)
                }
            }
        }
    }

    @Test func appRegistersSecretsAndOldStreams() async throws {
        let yaml = """
        app: {name: Env, mode: workflow}
        workflow:
          environment_variables:
          - {id: e1, name: api_key, value: sk-imported-secret, value_type: secret}
          conversation_variables: []
          features: {}
          graph:
            nodes:
            - id: s
              data: {type: start, title: Start, variables: []}
            edges: []
        """
        try await withStore { store, logger in
            let registry = DocumentRegistry(store: store, config: ServerConfig.defaults, logger: logger)
            try await withApp(configure: { app in
                Routes(registry: registry, store: store, config: ServerConfig.defaults, logger: logger).register(on: app)
            }) { app in
                try await app.testing { client in
                    func json(_ text: String) throws -> Value { try WireJSON.decode(Value.self, from: Data(text.utf8)) }
                    func getJSON(_ path: String) async throws -> Value { try json(try await client.get(.init(stringLiteral: path)).body.requireString()) }
                    func env(_ v: Value, workflow: Bool) -> [Value] {
                        guard case .map(var m) = v else { return [] }
                        if workflow, case .map(let w)? = m["workflow"] { m = w }
                        if case .list(let xs)? = m["environment_variables"] { return xs }
                        return []
                    }
                    func member(_ v: Value, _ k: String) -> Value? { if case .map(let m) = v { return m[k] }; return nil }
                    let doc = "t-\(UUID().uuidString.lowercased().prefix(12))"
                    #expect(try await client.put("/v1/docs/\(doc)/import") { $0.body = .init(string: yaml) }.status.code == 201)

                    // The imported secret is stored aside; the document has its mask and reference only.
                    let snap = try await client.get("/v1/docs/\(doc)/snapshot")
                    let snapText = try await snap.body.requireString()
                    #expect(!snapText.contains("sk-imported-secret") && snapText.contains("sk-imp************et"))
                    #expect(try await store.secrets(doc).values.sorted() == ["sk-imported-secret"])

                    // POST /secrets: 201 {ref, masked}; validation; unknown document.
                    let stored = try await client.post("/v1/docs/\(doc)/secrets") { $0.body = .init(string: #"{"value":"sk-typed-in-the-panel"}"#) }
                    #expect(stored.status.code == 201)
                    guard case .map(let sm) = try json(try await stored.body.requireString()), case .string(let ref)? = sm["ref"] else { Issue.record("secret"); return }
                    #expect(ref.hasPrefix("sec-") && ref.count == 36 && sm["masked"] == .string("sk-typ************el"))
                    #expect(try await client.post("/v1/docs/\(doc)/secrets") { $0.body = .init(string: #"{"v":1}"#) }.status.code == 400)
                    #expect(try await client.post("/v1/docs/t-nope-\(UUID().uuidString.prefix(8))/secrets") {
                        $0.body = .init(string: #"{"value":"x"}"#)
                    }.status.code == 404)

                    // The panel writes a second secret variable with ordinary ops.
                    let item: Value = .map(["id": .string("e2"), "name": .string("other"), "value": .string("sk-typ************el"),
                                            "value_type": .string("secret"), "secret_ref": .string(ref)])
                    let op = Op.insertItem(Document.appNode, path: ["environment_variables"], item: Item(id: "e2", value: item), after: "e1")
                    let r = try await registry.sequencer(doc).submit(req("alice", [(1, 0, op)]))
                    #expect(r.results == [.ack(cseq: 1, seq: 1)])
                    #expect(try await store.logTouchesApp(doc, after: 0, through: 1))
                    #expect(try await !store.logTouchesApp(doc, after: 1, through: 1))

                    // Meta follows the document: masks, no references.
                    let metaEnv = env(try await getJSON("/v1/docs/\(doc)/meta"), workflow: false)
                    #expect(metaEnv.map { member($0, "value") } == [.string("sk-imp************et"), .string("sk-typ************el")])
                    #expect(metaEnv.allSatisfy { member($0, "secret_ref") == nil })
                    // Export: "" by default, the plaintext with include_secret; never a reference.
                    let plain = env(try await getJSON("/v1/docs/\(doc)/export?format=json"), workflow: true)
                    #expect(plain.map { member($0, "value") } == [.string(""), .string("")])
                    let full = env(try await getJSON("/v1/docs/\(doc)/export?format=json&include_secret=true"), workflow: true)
                    #expect(full.map { member($0, "value") } == [.string("sk-imported-secret"), .string("sk-typed-in-the-panel")])
                    #expect((plain + full).allSatisfy { member($0, "secret_ref") == nil })
                    let yamlOut = try await client.get("/v1/docs/\(doc)/export?include_secret=true").body.requireString()
                    #expect(yamlOut.contains("sk-typed-in-the-panel"))

                    // A 1.6 stream never carries the $app commit: its catch-up becomes a snapshot.
                    let seqr = await registry.sequencer(doc)
                    let old = try await seqr.subscribe(lastEventId: 0, maxReplay: 100, proto: "1.6")
                    #expect(old.plan == .replay(after: 0) && old.doc != nil)  // the route turns it into a snapshot (doc captured)
                    await seqr.unsubscribe(old.id)
                }
            }
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
