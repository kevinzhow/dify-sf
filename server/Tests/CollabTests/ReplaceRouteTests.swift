import CollabCore
import CollabDSL
import CollabStore
import Foundation
import Testing
import VaporTesting
@testable import CollabServer

private let seed = """
app: {name: Seed, mode: workflow}
kind: app
version: 0.3.1
workflow:
  graph:
    nodes:
    - id: seed
      data: {type: start, title: Seed, variables: []}
    edges: []
"""
private let iterationFile = "array_iteration_formatting_workflow.yml"
private let codeNode = "1754683442688"

private func setCode(_ client: String, cseq: Int, base: Int, _ value: String) -> String {
    #"{"client":"\#(client)","ops":[{"cseq":\#(cseq),"base":\#(base),"op":{"t":"setField","node":"\#(codeNode)","field":{"k":"config","path":["code"]},"value":"\#(value)"}}]}"#
}

private func percent(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

/// `POST /v1/docs/{doc}/replace` against Postgres and the real routes.
@Suite("Replace route", .enabled(if: testDbHost != nil))
struct ReplaceRouteTests {
    /// A document imported from `yaml` and a client id of `token`'s account.
    private func setUp(_ api: API, _ token: String, yaml: String = seed) async throws -> (doc: String, client: String) {
        let doc = "t-rep-\(UUID().uuidString.lowercased().prefix(10))"
        #expect(try await api.put("/v1/docs/\(doc)/import", yaml, token: token).status == 201)
        let client = try await api.post("/v1/docs/\(doc)/clients", token: token).str("client")
        return (doc, client)
    }

    @Test func theContractEndToEnd() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let (doc, client) = try await setUp(api, owner)
            let d = "/v1/docs/\(doc)"
            let file = try load(iterationFile)

            let r = try await api.post("\(d)/replace?client=\(client)&cseq=1", file, token: owner)
            #expect(r.status == 200, "\(r.text)")
            guard case .int(let n)? = r.json["ops"] else { Issue.record("\(r.text)"); return }
            #expect(n > 6 && r.json["head"] == .int(n) && r.json["next_cseq"] == .int(n + 1) && r.json["replayed"] == .bool(false))
            #expect(r.json["nodes"] == .int(6) && r.json["edges"] == .int(4))
            #expect(r.json["status"] == .string("completed-with-warnings") && r.json["imported_dsl_version"] == .string("0.3.1"))
            #expect(r.json["current_dsl_version"] == .string("0.7.0"))
            #expect(r.obj("renamed") == ["nodes": .map([:]), "edges": .map([:])])
            // Ordinary ops of the caller's client, cseqs 1...n, in the log (streams see them as commits).
            let log = try await store.entries(doc, after: 0, through: n)
            #expect(log.map(\.client) == Array(repeating: client, count: n) && log.map(\.cseq) == Array(1...n))
            #expect(Set(log.map(\.base)) == [0])
            // The export is the file; the metadata (app name) is the file's.
            let exported = try WireJSON.decode(Value.self, from: Data(try await api.get("\(d)/export?format=json", token: owner).text.utf8))
            let diff = firstDifference(normalized(try parse(file)), normalized(exported))
            #expect(diff == nil, "\(diff ?? "")")
            #expect(try await api.get("\(d)/meta", token: owner).obj("app")["name"] == .string("test_iteration"))

            // A retry (same cseq) is the earlier success; nothing is written again.
            let again = try await api.post("\(d)/replace?client=\(client)&cseq=1", file, token: owner)
            #expect(again.status == 200 && again.json["replayed"] == .bool(true) && again.json["ops"] == .int(n))
            #expect(again.json["head"] == .int(n) && again.json["next_cseq"] == .int(n + 1))
            #expect(try await store.documentHead(doc) == n)
            // The next cseq with the same file: nothing to do.
            let same = try await api.post("\(d)/replace?client=\(client)&cseq=\(n + 1)", file, token: owner)
            #expect(same.status == 200 && same.json["ops"] == .int(0) && same.json["next_cseq"] == .int(n + 1) && same.json["head"] == .int(n))
            // A cseq beyond the next one: the client has ops the server has not handled.
            let ahead = try await api.post("\(d)/replace?client=\(client)&cseq=\(n + 3)", file, token: owner)
            #expect(ahead.status == 409 && ahead.errorCode == "outstanding_ops")
            // A cseq used by an ordinary op (here a rejected one) is not a replacement to replay.
            let other = try await api.post("/v1/docs/\(doc)/clients", token: owner).str("client")
            #expect(try await api.post("\(d)/ops", setCode(other, cseq: 1, base: 0, "x").replacingOccurrences(of: codeNode, with: "ghost"),
                                       token: owner).status == 200)
            let used = try await api.post("\(d)/replace?client=\(other)&cseq=1", seed, token: owner)
            #expect(used.status == 409 && used.errorCode == "cseq_used")
            // The JSON form; back to the seed (the seed node id is tombstoned now: it comes back under a fresh id).
            struct Body: Encodable { var yaml: String; var client: String; var cseq: Int }
            let json = String(decoding: try JSONEncoder().encode(Body(yaml: seed, client: client, cseq: n + 1)), as: UTF8.self)
            let back = try await api.post("\(d)/replace", json, token: owner)
            #expect(back.status == 200 && back.json["nodes"] == .int(1) && back.json["edges"] == .int(0), "\(back.text)")
            guard case .map(let renamed)? = back.obj("renamed")["nodes"], case .string(let fresh)? = renamed["seed"] else {
                Issue.record("\(back.text)"); return
            }
            #expect(Int(fresh) != nil)
            let snap = try await DocumentSequencer(docId: doc, store: store, config: .defaults, logger: .init(label: "t")).currentSnapshot()
            #expect(Array(snap.doc.nodes.keys) == [fresh] && snap.doc.deletedNodes["seed"] != nil)
        }
    }

    @Test func refusals() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let (_, bob) = try await api.member("bob@example.com", role: "editor", name: "Bob", inviter: owner)
            let (doc, client) = try await setUp(api, owner)
            let d = "/v1/docs/\(doc)"
            let q = "client=\(client)&cseq=1"
            #expect(try await api.post("\(d)/replace?cseq=1", seed, token: owner).status == 400)
            #expect(try await api.post("\(d)/replace?client=\(client)", seed, token: owner).status == 400)
            #expect(try await api.post("\(d)/replace?client=\(client)&cseq=0", seed, token: owner).status == 400)
            #expect(try await api.post("/v1/docs/t-nope-\(UUID().uuidString.prefix(6))/replace?\(q)", seed, token: owner).status == 404)
            // Someone else's client id.
            let foreign = try await api.post("\(d)/replace?\(q)", seed, token: bob)
            #expect(foreign.status == 403 && foreign.errorCode == "forbidden")
            // Not YAML, not a mapping, no workflow, a chat app.
            let bad = try await api.post("\(d)/replace?\(q)", "app: [", token: owner)
            #expect(bad.status == 400 && bad.text.contains("Invalid YAML format"))
            #expect(try await api.post("\(d)/replace?\(q)", "- a", token: owner).text.contains("content must be a mapping"))
            #expect(try await api.post("\(d)/replace?\(q)", "app: {mode: workflow, name: x}", token: owner).text.contains("Missing workflow data"))
            #expect(try await api.post("\(d)/replace?\(q)", "app: {mode: chat, name: x}\nworkflow: {}", token: owner).status == 400)
            // The app's mode stays: a chatflow's answer nodes do not fit this workflow (Dify's validateDSLContent).
            let chat = try await api.post("\(d)/replace?\(q)", try load("basic_chatflow.yml"), token: owner)
            #expect(chat.status == 400 && chat.text.contains("Import Failed"), "\(chat.text)")
            // A newer DSL version needs the user's confirmation (Dify's pending import).
            let newer = try load(iterationFile).replacingOccurrences(of: "version: 0.3.1", with: "version: 0.9.0")
            let pending = try await api.post("\(d)/replace?\(q)", newer, token: owner)
            #expect(pending.status == 400 && pending.errorCode == "version_unconfirmed")
            #expect(pending.obj("error")["imported_dsl_version"] == .string("0.9.0") && pending.obj("error")["current_dsl_version"] == .string("0.7.0"))
            let confirmed = try await api.post("\(d)/replace?\(q)&confirm=true", newer, token: owner)
            #expect(confirmed.status == 200 && confirmed.json["status"] == .string("pending"), "\(confirmed.text)")
        }
    }

    @Test func staleAndConcurrentEditsOfOthersConflict() async throws {
        var cfg = ServerConfig.defaults
        cfg.testCommitDelayMillis = 5
        try await withServer(config: cfg) { api, store, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            let (_, bob) = try await api.member("bob@example.com", role: "editor", name: "Bob", inviter: owner)
            let file = try load(iterationFile)
            let (doc, client) = try await setUp(api, owner, yaml: file)
            let d = "/v1/docs/\(doc)"
            let bobClient = try await api.post("\(d)/clients", token: bob).str("client")
            // Bob edits the code; the owner replaces the document with the file again (writes the code back).
            #expect(try await api.post("\(d)/ops", setCode(bobClient, cseq: 1, base: 0, "draft"), token: bob).status == 200)
            let seen = 1
            // Concurrently: Bob keeps writing from the version he saw while the replacement runs.
            async let replaced = api.post("\(d)/replace?client=\(client)&cseq=1", file, token: owner)
            var answers: [API.Answer] = []
            for c in 2...6 { answers.append(try await api.post("\(d)/ops", setCode(bobClient, cseq: c, base: seen, "bob-\(c)"), token: bob)) }
            let r = try await replaced
            #expect(r.status == 200, "\(r.text)")
            guard case .int(let head)? = r.json["head"], case .int(let n)? = r.json["ops"] else { Issue.record("\(r.text)"); return }
            let firstReplaceSeq = head - n + 1
            for a in answers {
                guard case .map(let res)? = a.list("results").first else { Issue.record("\(a.text)"); continue }
                if res["status"] == .string("ack"), case .int(let seq)? = res["seq"] {
                    #expect(seq < firstReplaceSeq, "an ack after the replacement would have overwritten it silently")
                } else {
                    guard case .map(let reason)? = res["reason"] else { Issue.record("\(a.text)"); continue }
                    #expect(reason["type"] == .string("conflict") && reason["by"] == .string(client) && reason["byName"] == .string("Olivia"),
                            "\(a.text)")
                }
            }
            // The file's code won (written by the replacement, never overwritten by a stale write).
            let snap = try await DocumentSequencer(docId: doc, store: store, config: .defaults, logger: .init(label: "t")).currentSnapshot()
            if case .string(let code)? = snap.doc.nodes[codeNode]?.config["code"] { #expect(code.contains("return")) } else { Issue.record("code") }
            // After seeing the replacement, Bob writes freely again.
            let fresh = try await api.post("\(d)/ops", setCode(bobClient, cseq: 7, base: snap.seq, "later"), token: bob)
            #expect(fresh.list("results").first.map { if case .map(let m) = $0 { return m["status"] == .string("ack") }; return false } == true)
        }
    }

    @Test func secretsGoToTheSecretsTable() async throws {
        let file = """
        app: {name: Env, mode: workflow}
        kind: app
        version: 0.3.1
        workflow:
          environment_variables:
          - {id: k, name: api_key, value: sk-replaced-secret-1, value_type: secret}
          graph:
            nodes:
            - {id: s, data: {type: start, title: Start, variables: []}}
            edges: []
        """
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let (doc, client) = try await setUp(api, owner)
            let d = "/v1/docs/\(doc)"
            let r = try await api.post("\(d)/replace?client=\(client)&cseq=1", file, token: owner)
            #expect(r.status == 200, "\(r.text)")
            #expect(try await store.secrets(doc).values.sorted() == ["sk-replaced-secret-1"])
            let snap = try await api.get("\(d)/snapshot", token: owner).text
            #expect(!snap.contains("sk-replaced-secret-1") && snap.contains(DifyDSL.maskSecret("sk-replaced-secret-1")))
            guard case .int(let n)? = r.json["ops"] else { return }
            for e in try await store.entries(doc, after: 0, through: n) { #expect(!"\(e.op)".contains("sk-replaced-secret-1")) }
            #expect(try await api.get("\(d)/export?include_secret=true", token: owner).text.contains("sk-replaced-secret-1"))
            // The same file again: the stored secret keeps its reference; nothing new is written.
            let again = try await api.post("\(d)/replace?client=\(client)&cseq=\(n + 1)", file, token: owner)
            #expect(again.json["ops"] == .int(0))
            #expect(try await store.secrets(doc).count == 1)
        }
    }

    @Test func anotherProcessCommittingMeanwhileMakesItReplan() async throws {
        try await withStore { store, logger in
            let doc = "t-rep-\(UUID().uuidString.lowercased().prefix(10))"
            let imp = try DifyDSL.importYAML(try load(iterationFile))
            _ = try await store.createDocument(id: doc, initial: imp.document, metadata: imp.metadata)
            let p1 = DocumentSequencer(docId: doc, store: store, config: .defaults, logger: logger)
            let p2 = DocumentSequencer(docId: doc, store: store, config: .defaults, logger: logger)
            _ = try await p2.currentSnapshot()  // p2's state is loaded ...
            let r = try await p1.submit(SubmitRequest(client: "other", ops: [IncomingOp(cseq: 1, base: 0, op: .setField(codeNode, .config(["code"]), .string("x")))]))
            #expect(r.results == [.ack(cseq: 1, seq: 1)])  // ... and now stale
            let root = try DifyDSL.parseYAML(try load(iterationFile))
            let plans = Counter()
            let (outcome, _) = try await p2.replace(client: "r", cseq: 1) { current, head -> (DocumentSequencer.ReplaceWork, Int) in
                await plans.bump()
                let plan = try DifyDSL.planReplacement(root, current: current, metadata: imp.metadata, storedSecrets: [:], client: "r", base: head)
                return (.init(ops: plan.ops), head)
            }
            #expect(await plans.value == 2)  // planned on the stale state, refused by the revision check, planned again
            #expect(outcome.ops == 1 && outcome.head == 2)
            let entries = try await store.entries(doc, after: 1, through: 2)
            #expect(entries.map(\.base) == [1] && entries.map(\.client) == ["r"])
        }
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}
