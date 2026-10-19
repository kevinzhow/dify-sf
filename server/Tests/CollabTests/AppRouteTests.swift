import CollabCore
import CollabDSL
import CollabModels
import CollabStore
import Foundation
import PostgresNIO
import Testing
import VaporTesting
@testable import CollabServer

private func json(_ v: JSON) -> String { String(decoding: try! JSONCoding.encode(v), as: UTF8.self) }

extension API.Answer {
    var appIds: [String] { (j["data"]?.array ?? []).compactMap { $0["id"]?.string } }
    var total: Int? { j["total"]?.int }
}

private let secretFile = """
    app: {name: With secrets, mode: workflow, icon: "🧪", icon_background: "#E0F2FE", description: has a key}
    kind: app
    version: 0.7.0
    workflow:
      environment_variables:
      - {id: e1, name: api_key, value: sk-copy-me-please, value_type: secret, description: ''}
      - {id: e2, name: region, value: eu, value_type: string, description: ''}
      conversation_variables: []
      features: {}
      graph:
        nodes:
        - id: s
          data: {type: start, title: Start, variables: []}
        edges: []
    """

private func file(name: String = "Imported", mode: String = "workflow", version: String = "0.7.0", answer: Bool = false) -> String {
    """
    app: {name: \(name), mode: \(mode)}
    kind: app
    version: \(version)
    workflow:
      graph:
        nodes:
        - id: s
          data: {type: start, title: Start, variables: []}
    \(answer ? "    - id: a\n      data: {type: answer, title: Answer, answer: hi}\n" : "")    edges: []
    """
}

/// One op on the start node's config (a committed graph edit).
private func edit(_ client: String, cseq: Int, node: String = "start") -> String {
    #"{"client":"\#(client)","ops":[{"cseq":\#(cseq),"base":0,"op":{"t":"setField","node":"\#(node)","field":{"k":"config","path":["desc"]},"value":"edit \#(cseq)"}}]}"#
}

/// Protocol 1.10 apps (Dify's Studio) against Postgres and the real routes, each test on a fresh database.
@Suite("App routes", .enabled(if: testDbHost != nil))
struct AppRouteTests {
    private func create(_ api: API, _ token: String, name: String, mode: String = "workflow") async throws -> String {
        let r = try await api.post("/v1/apps", json(["name": .string(name), "mode": .string(mode)]), token: token)
        #expect(r.status == 201, "\(r.text)")
        return r.j["id"]?.string ?? ""
    }

    @Test func rolesAndPermissionKeys() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let admin = try await api.member("admin@example.com", role: "admin", inviter: owner).token
            let editor = try await api.member("editor@example.com", role: "editor", inviter: owner).token
            let normal = try await api.member("normal@example.com", role: "normal", inviter: owner).token
            let operatorToken = try await api.member("ops@example.com", role: "dataset_operator", inviter: owner).token
            let id = try await create(api, editor, name: "By the editor")
            #expect(try await api.get("/v1/apps").status == 401)
            for (token, keys) in [(owner, 13), (admin, 13), (editor, 12), (normal, 2), (operatorToken, 1)] {
                let list = try await api.get("/v1/apps", token: token)
                #expect(list.status == 200 && list.appIds == [id])
                let k = (list.j["data"]?.array?.first?["permission_keys"]?.array ?? []).compactMap(\.string)
                #expect(k.count == keys, "\(k)")
                #expect(k.contains("app.acl.edit") == (keys >= 12) && k.contains("app.acl.view_layout") == (keys >= 12))
                #expect(k.contains("app.acl.tracing_config") == (keys == 13))
                #expect(try await api.get("/v1/apps/\(id)", token: token).status == 200)
                #expect(try await api.post("/v1/apps/\(id)/star", token: token).status == 200)
            }
            for token in [normal, operatorToken] {
                let forbidden = [
                    try await api.post("/v1/apps", #"{"name":"x","mode":"workflow"}"#, token: token),
                    try await api.put("/v1/apps/\(id)", #"{"name":"x"}"#, token: token),
                    try await api.post("/v1/apps/\(id)/copy", "{}", token: token),
                    try await api.delete("/v1/apps/\(id)", token: token),
                    try await api.get("/v1/apps/\(id)/export", token: token),
                    try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(file())]), token: token),
                ]
                #expect(forbidden.allSatisfy { $0.status == 403 && $0.errorCode == "forbidden" }, "\(forbidden.map(\.text))")
            }
            // Dify CE: any editor edits, copies, exports and deletes any app; secrets in an export: owner and admin.
            #expect(try await api.put("/v1/apps/\(id)", #"{"name":"Renamed by admin"}"#, token: admin).status == 200)
            #expect(try await api.get("/v1/apps/\(id)/export", token: editor).status == 200)
            #expect(try await api.get("/v1/apps/\(id)/export?include_secret=true", token: editor).status == 403)
            #expect(try await api.get("/v1/apps/\(id)/export?include_secret=true", token: admin).status == 200)
            #expect(try await api.post("/v1/apps/\(id)/copy", "{}", token: editor).status == 201)
        }
    }

    @Test func createBlankSeedsAndShape() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            let wf = try await api.post("/v1/apps", #"{"name":"  My flow  ","mode":"workflow","description":"d"}"#, token: owner)
            #expect(wf.status == 201)
            let a = wf.j
            #expect(a["name"] == "My flow" && a["mode"] == "workflow" && a["description"] == "d")
            #expect(a["icon_type"] == "emoji" && a["icon"] == "🤖" && a["icon_background"] == "#FFEAD5" && a["icon_url"] == .null)
            #expect(a["author_name"] == "Olivia" && a["create_user_name"] == "Olivia" && a["is_starred"] == false)
            #expect(a["tags"] == .array([]) && a["use_icon_as_answer_icon"] == false && a["has_draft_trigger"] == false)
            #expect(a["created_at"]?.int == a["updated_at"]?.int && (a["created_at"]?.int ?? 0) > 1_700_000_000)
            let id = a["id"]?.string ?? ""
            let snap = try await api.get("/v1/docs/\(id)/snapshot", token: owner)
            #expect(snap.status == 200)
            guard case .map(let doc)? = snap.json["doc"], case .list(let nodes)? = doc["nodes"] else { Issue.record("\(snap.text)"); return }
            #expect(nodes.count == 1)
            #expect(try await api.get("/v1/docs/\(id)/meta", token: owner).obj("app")["name"] == .string("My flow"))

            let chat = try await api.post("/v1/apps", ##"{"name":"Chat","mode":"advanced-chat","icon":"🐙","icon_background":"#000000"}"##,
                                          token: owner)
            #expect(chat.status == 201 && chat.j["mode"] == "advanced-chat" && chat.j["icon"] == "🐙")
            let cid = chat.j["id"]?.string ?? ""
            let csnap = try await api.get("/v1/docs/\(cid)/snapshot", token: owner)
            guard case .map(let cdoc)? = csnap.json["doc"], case .list(let cnodes)? = cdoc["nodes"], case .list(let cedges)? = cdoc["edges"]
            else { Issue.record("\(csnap.text)"); return }
            let types = cnodes.compactMap { n -> String? in if case .map(let m) = n, case .string(let t)? = m["type"] { return t }; return nil }
            #expect(Set(types) == ["start", "llm", "answer"] && cedges.count == 2)
            let meta = try await api.get("/v1/docs/\(cid)/meta", token: owner)
            #expect(meta.obj("features")["retriever_resource"] == .map(["enabled": .bool(true)]))
            #expect(meta.obj("app")["mode"] == .string("advanced-chat"))
            // The export of a blank chatflow imports again as the same app.
            let exported = try await api.get("/v1/apps/\(cid)/export", token: owner)
            #expect(exported.status == 200 && (exported.j["data"]?.string ?? "").contains("{{#llm.text#}}"))

            for (body, code) in [
                (#"{"name":"x","mode":"chat"}"#, "unsupported_app_mode"), (#"{"name":"x","mode":"agent-chat"}"#, "unsupported_app_mode"),
                (#"{"name":"x","mode":"completion"}"#, "unsupported_app_mode"), (#"{"name":"x","mode":"agent"}"#, "bad_request"),
                (#"{"name":"x"}"#, "bad_request"), (#"{"name":"   ","mode":"workflow"}"#, "bad_request"),
                (#"{"mode":"workflow"}"#, "bad_request"), (#"{"name":"x","mode":"workflow","icon_type":"svg"}"#, "bad_request"),
                (json(["name": "x", "mode": "workflow", "description": .string(String(repeating: "d", count: 401))]), "bad_request"),
            ] {
                let r = try await api.post("/v1/apps", body, token: owner)
                #expect(r.status == 400 && r.errorCode == code, "\(body): \(r.text)")
            }
            #expect(try await api.post("/v1/apps", json(["name": "x", "mode": "workflow",
                                                         "description": .string(String(repeating: "d", count: 400))]), token: owner).status == 201)
            #expect(try await api.get("/v1/apps/nope", token: owner).errorCode == "not_found")
        }
    }

    @Test func listPaginationFiltersAndSorts() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let (editorId, editor) = try await api.member("editor@example.com", role: "editor", name: "Eddie", inviter: owner)
            let a = try await create(api, owner, name: "Alpha report")
            let b = try await create(api, editor, name: "beta REPORT", mode: "advanced-chat")
            let c = try await create(api, owner, name: "Gamma")
            let d = try await create(api, editor, name: "Delta report")
            let e = try await create(api, owner, name: "Epsilon", mode: "advanced-chat")
            // Default: last modified first (here: creation order reversed), 20 a page.
            let all = try await api.get("/v1/apps", token: owner)
            #expect(all.appIds == [e, d, c, b, a] && all.total == 5 && all.j["has_more"] == false && all.j["limit"] == 20)
            // Pages.
            let p1 = try await api.get("/v1/apps?page=1&limit=2", token: owner)
            #expect(p1.appIds == [e, d] && p1.j["has_more"] == true && p1.total == 5 && p1.j["page"] == 1)
            let p3 = try await api.get("/v1/apps?page=3&limit=2", token: owner)
            #expect(p3.appIds == [a] && p3.j["has_more"] == false)
            let p9 = try await api.get("/v1/apps?page=9&limit=2", token: owner)
            #expect(p9.status == 200 && p9.appIds.isEmpty && p9.total == 5)
            // Sorts.
            #expect(try await api.get("/v1/apps?sort_by=recently_created", token: owner).appIds == [e, d, c, b, a])
            #expect(try await api.get("/v1/apps?sort_by=earliest_created", token: owner).appIds == [a, b, c, d, e])
            // Filters: mode, name (case-insensitive substring), creators, created by me; tag ids accepted and ignored.
            #expect(try await api.get("/v1/apps?mode=advanced-chat", token: owner).appIds == [e, b])
            #expect(try await api.get("/v1/apps?mode=workflow", token: owner).appIds == [d, c, a])
            for m in ["chat", "agent-chat", "completion", "agent", "channel"] {
                let r = try await api.get("/v1/apps?mode=\(m)", token: owner)
                #expect(r.status == 200 && r.appIds.isEmpty && r.total == 0)
            }
            #expect(try await api.get("/v1/apps?name=report", token: owner).appIds == [d, b, a])
            #expect(try await api.get("/v1/apps?name=Beta+Rep", token: owner).appIds == [b])
            #expect(try await api.get("/v1/apps?name=\("x" + String(repeating: "y", count: 40))", token: owner).appIds.isEmpty)
            #expect(try await api.get("/v1/apps?creator_ids=\(editorId)", token: owner).appIds == [d, b])
            #expect(try await api.get("/v1/apps?is_created_by_me=true", token: editor).appIds == [d, b])
            #expect(try await api.get("/v1/apps?is_created_by_me=false", token: editor).appIds.count == 5)
            #expect(try await api.get("/v1/apps?mode=workflow&name=report&creator_ids=\(editorId)&tag_ids=t1", token: owner).appIds == [d])
            // Authors are the creators' names.
            let authors = (try await api.get("/v1/apps?creator_ids=\(editorId)", token: owner).j["data"]?.array ?? []).map { $0["author_name"] }
            #expect(authors == [.string("Eddie"), .string("Eddie")])
            // Last modified (protocol 1.10's deviation): a committed graph edit moves the app to the top...
            let client = try await api.post("/v1/docs/\(a)/clients", token: editor).str("client")
            #expect(try await api.post("/v1/docs/\(a)/ops", edit(client, cseq: 1), token: editor).status == 200)
            #expect(try await api.get("/v1/apps", token: owner).appIds == [a, e, d, c, b])
            // ... as does editing the app's info (Dify's rule); creation order stays.
            #expect(try await api.put("/v1/apps/\(c)", #"{"name":"Gamma 2"}"#, token: owner).status == 200)
            #expect(try await api.get("/v1/apps", token: owner).appIds == [c, a, e, d, b])
            #expect(try await api.get("/v1/apps?sort_by=earliest_created", token: owner).appIds == [a, b, c, d, e])
            let edited = try await api.get("/v1/apps/\(a)", token: owner).j
            #expect((edited["updated_at"]?.int ?? 0) >= (edited["created_at"]?.int ?? 0))
            // Refused queries.
            for q in ["page=0", "page=100000", "limit=0", "limit=101", "limit=x", "mode=bogus", "sort_by=name", "is_created_by_me=maybe"] {
                let r = try await api.get("/v1/apps?\(q)", token: owner)
                #expect(r.status == 400 && r.errorCode == "bad_request", "\(q): \(r.text)")
            }
        }
    }

    @Test func starsArePerAccount() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let normal = try await api.member("normal@example.com", role: "normal", inviter: owner).token
            let a = try await create(api, owner, name: "A")
            let b = try await create(api, owner, name: "B", mode: "advanced-chat")
            let c = try await create(api, owner, name: "C")
            #expect(try await api.post("/v1/apps/\(a)/star", token: owner).j["result"] == "success")
            #expect(try await api.post("/v1/apps/\(a)/star", token: owner).status == 200)  // idempotent
            #expect(try await api.post("/v1/apps/\(b)/star", token: owner).status == 200)
            #expect(try await api.post("/v1/apps/\(c)/star", token: normal).status == 200)
            let mine = try await api.get("/v1/apps/starred", token: owner)
            #expect(mine.appIds == [b, a] && mine.total == 2)
            #expect((mine.j["data"]?.array ?? []).allSatisfy { $0["is_starred"] == true })
            #expect(try await api.get("/v1/apps/starred", token: normal).appIds == [c])
            #expect(try await api.get("/v1/apps/starred?mode=workflow", token: owner).appIds == [a])
            let starredFlags = (try await api.get("/v1/apps", token: normal).j["data"]?.array ?? []).map { ($0["id"]?.string ?? "", $0["is_starred"]) }
            #expect(starredFlags.allSatisfy { $0.1 == .bool($0.0 == c) })
            #expect(try await api.get("/v1/apps/\(a)", token: normal).j["is_starred"] == false)
            #expect(try await api.get("/v1/apps/\(a)", token: owner).j["is_starred"] == true)
            #expect(try await api.delete("/v1/apps/\(a)/star", token: owner).status == 200)
            #expect(try await api.delete("/v1/apps/\(a)/star", token: owner).status == 200)  // idempotent
            #expect(try await api.get("/v1/apps/starred", token: owner).appIds == [b])
            // A deleted app leaves the starred list; it cannot be starred.
            #expect(try await api.delete("/v1/apps/\(b)", token: owner).status == 204)
            #expect(try await api.get("/v1/apps/starred", token: owner).appIds.isEmpty)
            #expect(try await api.post("/v1/apps/\(b)/star", token: owner).errorCode == "app_deleted")
            #expect(try await api.post("/v1/apps/ghost/star", token: owner).errorCode == "not_found")
        }
    }

    @Test func updateKeepsWhatIsLeftOut() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let id = try await create(api, owner, name: "Before")
            let r = try await api.put("/v1/apps/\(id)", json([
                "name": "After", "description": "new", "icon_type": "emoji", "icon": "🦊", "icon_background": "#FFFFFF",
                "use_icon_as_answer_icon": true, "max_active_requests": 3,
            ]), token: owner)
            #expect(r.status == 200 && r.j["name"] == "After" && r.j["icon"] == "🦊" && r.j["use_icon_as_answer_icon"] == true)
            #expect(r.j["max_active_requests"] == 3)
            let again = try await api.put("/v1/apps/\(id)", #"{"name":"After 2"}"#, token: owner)
            #expect(again.j["name"] == "After 2" && again.j["description"] == "new" && again.j["icon"] == "🦊" && again.j["max_active_requests"] == 3)
            for body in [#"{"description":"x"}"#, #"{"name":""}"#, #"{"name":"x","icon_type":"svg"}"#, #"{"name":"x","max_active_requests":-1}"#,
                         #"{"name":"x","use_icon_as_answer_icon":"yes"}"#, "nope"] {
                #expect(try await api.put("/v1/apps/\(id)", body, token: owner).status == 400, "\(body)")
            }
            #expect(try await api.put("/v1/apps/ghost", #"{"name":"x"}"#, token: owner).errorCode == "not_found")
            // The app row is the source of truth for the meta and the export.
            #expect(try await api.get("/v1/docs/\(id)/meta", token: owner).obj("app")["name"] == .string("After 2"))
            let exported = try await api.get("/v1/docs/\(id)/export?format=json", token: owner)
            guard case .map(let app)? = exported.json["app"] else { Issue.record("\(exported.text)"); return }
            #expect(app["name"] == .string("After 2") && app["icon"] == .string("🦊") && app["description"] == .string("new"))
            #expect(app["use_icon_as_answer_icon"] == .bool(true) && app["mode"] == .string("workflow"))
        }
    }

    @Test func importWithVersionConfirmation() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let editor = try await api.member("editor@example.com", role: "editor", inviter: owner).token
            func importing(_ yaml: String, _ extra: [String: JSON] = [:], token: String) async throws -> API.Answer {
                var b: [String: JSON] = ["mode": "yaml-content", "yaml_content": .string(yaml)]
                for (k, v) in extra { b[k] = v }
                return try await api.post("/v1/apps/imports", json(.object(b)), token: token)
            }
            let ok = try await importing(file(name: "From file"), token: owner)
            #expect(ok.status == 200 && ok.j["status"] == "completed" && ok.j["imported_dsl_version"] == "0.7.0", "\(ok.text)")
            #expect(ok.j["current_dsl_version"] == "0.7.0" && ok.j["app_mode"] == "workflow" && ok.j["error"] == "")
            let id = ok.j["app_id"]?.string ?? ""
            #expect(try await api.get("/v1/apps/\(id)", token: owner).j["name"] == "From file")
            // Overrides (Dify's create-from-DSL modal sends none, the duplicate flow does).
            let named = try await importing(file(), ["name": "Override", "icon": "🐳", "icon_background": "#123456"], token: owner)
            let nid = named.j["app_id"]?.string ?? ""
            let n = try await api.get("/v1/apps/\(nid)", token: owner).j
            #expect(n["name"] == "Override" && n["icon"] == "🐳" && n["icon_background"] == "#123456")
            // An older minor version: imported with Dify's warning status.
            #expect(try await importing(file(version: "0.3.1"), token: owner).j["status"] == "completed-with-warnings")
            // A newer version waits for the confirmation of the same account.
            let pending = try await importing(file(name: "Future", version: "0.9.0"), ["name": "Confirmed name"], token: owner)
            #expect(pending.status == 202 && pending.j["status"] == "pending" && pending.j["imported_dsl_version"] == "0.9.0")
            #expect(pending.j["app_id"] == .null)
            let importId = pending.j["id"]?.string ?? ""
            #expect(try await api.get("/v1/apps", token: owner).total == 3)
            #expect(try await api.post("/v1/apps/imports/\(importId)/confirm", token: editor).errorCode == "not_found")
            let confirmed = try await api.post("/v1/apps/imports/\(importId)/confirm", token: owner)
            #expect(confirmed.status == 200 && confirmed.j["status"] == "completed" && confirmed.j["id"]?.string == importId, "\(confirmed.text)")
            let cid = confirmed.j["app_id"]?.string ?? ""
            #expect(try await api.get("/v1/apps/\(cid)", token: owner).j["name"] == "Confirmed name")
            #expect(try await api.post("/v1/apps/imports/\(importId)/confirm", token: owner).status == 404)  // used
            // Failures are answers (400 with Dify's Import object).
            for (yaml, extra, error) in [
                (file(mode: "chat"), [String: JSON](), "the file is a chat app"),
                (file(mode: "workflow", answer: true), [:], "answer nodes are not supported"),
                ("just text", [:], "content must be a mapping"),
                (file(version: "abc"), [:], "Invalid DSL version"),
                ("app: {}\nversion: 0.7.0", [:], "Missing app data"),
                (file(), ["app_id": "x"], "editor"),
            ] {
                let r = try await importing(yaml, extra, token: owner)
                #expect(r.status == 400 && r.j["status"] == "failed" && (r.j["error"]?.string ?? "").contains(error), "\(r.text)")
            }
            let url = try await api.post("/v1/apps/imports", #"{"mode":"yaml-url","yaml_url":"http://example.com/x.yml"}"#, token: owner)
            #expect(url.status == 400 && url.j["status"] == "failed")
            let none = try await api.post("/v1/apps/imports", #"{"mode":"yaml-content"}"#, token: owner)
            #expect(none.status == 400 && (none.j["error"]?.string ?? "").contains("yaml_content is required"))
            #expect(try await api.get("/v1/apps", token: owner).total == 4)
        }
    }

    @Test func copyReEncryptsSecretsForTheNewDocument() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let editor = try await api.member("editor@example.com", role: "editor", name: "Eddie", inviter: owner).token
            let r = try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(secretFile)]), token: owner)
            let src = r.j["app_id"]?.string ?? ""
            #expect(try await api.post("/v1/apps/\(src)/star", token: owner).status == 200)
            let copy = try await api.post("/v1/apps/\(src)/copy", #"{"name":"The copy","icon":"🐝"}"#, token: editor)
            #expect(copy.status == 201, "\(copy.text)")
            let c = copy.j
            let id = c["id"]?.string ?? ""
            #expect(id != src && c["name"] == "The copy" && c["icon"] == "🐝" && c["icon_background"] == "#E0F2FE")
            #expect(c["description"] == "has a key" && c["mode"] == "workflow" && c["author_name"] == "Eddie" && c["is_starred"] == false)
            // The copy's secret: a new reference, sealed for the new document (its row cannot be opened as the original's).
            let original = try await store.secrets(src), copied = try await store.secrets(id)
            #expect(Array(original.values) == ["sk-copy-me-please"] && Array(copied.values) == ["sk-copy-me-please"])
            #expect(Set(original.keys).isDisjoint(with: copied.keys))
            var rows: [(String, String)] = []
            for try await row in try await store.client.query("SELECT ref, value FROM secrets WHERE doc_id = \(id)", logger: store.logger)
                .decode((String, String).self) { rows.append(row) }
            let (ref, sealed) = try #require(rows.first)
            #expect(!sealed.contains("sk-copy"))
            #expect(throws: (any Error).self) { try store.cipher!.open(sealed, context: "secrets:\(src):\(ref)") }
            #expect(try store.cipher!.open(sealed, context: "secrets:\(id):\(ref)") == "sk-copy-me-please")
            let exported = try await api.get("/v1/apps/\(id)/export?include_secret=true", token: owner).j["data"]?.string ?? ""
            #expect(exported.contains("sk-copy-me-please") && exported.contains("The copy"))
            #expect(!(try await api.get("/v1/apps/\(id)/export", token: owner).j["data"]?.string ?? "").contains("sk-copy-me-please"))
            // The copy is a document of its own: editing it leaves the original alone.
            let client = try await api.post("/v1/docs/\(id)/clients", token: owner).str("client")
            #expect(try await api.post("/v1/docs/\(id)/ops", edit(client, cseq: 1, node: "s"), token: owner).status == 200)
            #expect(try await store.documentHead(id) == 1)
            #expect(try await store.documentHead(src) == 0)
            // Without overrides: the original's name.
            #expect(try await api.post("/v1/apps/\(src)/copy", token: owner).j["name"] == "With secrets")
            #expect(try await api.post("/v1/apps/ghost/copy", "{}", token: owner).errorCode == "not_found")
        }
    }

    @Test func copyWithoutASecretsKeyRefusesAppsWithSecrets() async throws {
        try await withServer(secretsKey: false) { api, store, _ in
            let owner = try await api.setupOwner()
            let id = try await create(api, owner, name: "Plain")
            #expect(try await api.post("/v1/apps/\(id)/copy", "{}", token: owner).status == 201)
            // A row an older server stored in plaintext.
            _ = try await store.client.query("INSERT INTO secrets (doc_id, ref, value) VALUES (\(id), 'sec-old', 'plain')", logger: store.logger)
            let r = try await api.post("/v1/apps/\(id)/copy", "{}", token: owner)
            #expect(r.status == 503 && r.errorCode == "secrets_key_missing")
        }
    }

    @Test func deleteMakesTheDocumentGoneAndEndsItsStreams() async throws {
        try await withServer { api, store, registry in
            let owner = try await api.setupOwner()
            let normal = try await api.member("normal@example.com", role: "normal", inviter: owner).token
            let id = try await create(api, owner, name: "Doomed")
            let keep = try await create(api, owner, name: "Kept")
            let d = "/v1/docs/\(id)"
            let client = try await api.post("\(d)/clients", token: owner).str("client")
            #expect(try await api.post("\(d)/ops", edit(client, cseq: 1), token: owner).status == 200)
            let stream = try await api.client.send(.get, headers: [.authorization: "Bearer \(owner)"], to: "\(d)/events?client=\(client)")
            #expect(stream.status.code == 200)
            #expect(await registry.totalSubscribers() == 1)
            #expect(try await api.delete("/v1/apps/\(id)", token: normal).status == 403)
            #expect(try await api.delete("/v1/apps/\(id)", token: owner).status == 204)
            // The stream ended (its body is complete) and nothing is subscribed any more.
            #expect(try await stream.body.requireString().contains("event: ready"))
            #expect(await registry.totalSubscribers() == 0)
            // Every document call answers 404 app_deleted; the app left the lists.
            let calls: [API.Answer] = [
                try await api.get(d, token: owner), try await api.get("\(d)/snapshot", token: owner), try await api.get("\(d)/meta", token: owner),
                try await api.get("\(d)/export", token: owner), try await api.get("\(d)/events", token: owner),
                try await api.post("\(d)/ops", edit(client, cseq: 2), token: owner), try await api.post("\(d)/clients", token: owner),
                try await api.get("\(d)/comments", token: owner), try await api.put(d, token: owner),
                try await api.post("\(d)/secrets", #"{"value":"v"}"#, token: owner),
                try await api.get("/v1/apps/\(id)", token: owner), try await api.put("/v1/apps/\(id)", #"{"name":"x"}"#, token: owner),
                try await api.post("/v1/apps/\(id)/copy", "{}", token: owner), try await api.get("/v1/apps/\(id)/export", token: owner),
                try await api.delete("/v1/apps/\(id)", token: owner),
            ]
            #expect(calls.allSatisfy { $0.status == 404 && $0.errorCode == "app_deleted" }, "\(calls.map { "\($0.status) \($0.text)" })")
            #expect(try await api.get("/v1/apps", token: owner).appIds == [keep])
            #expect(try await store.documentStatus(id) == .deleted)
            #expect(try await store.documentHead(id) == nil)
            #expect(try await store.load(id) == nil)
            // Unknown documents stay `not_found`.
            #expect(try await api.get("/v1/docs/ghost/snapshot", token: owner).errorCode == "not_found")
        }
    }

    /// Another process deleted the app: this process's sequencer still holds the document; its next commit fails the
    /// revision check, reloads and finds the app deleted.
    @Test func aDeleteByAnotherProcessReachesAHeldSequencer() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let id = try await create(api, owner, name: "Elsewhere")
            let d = "/v1/docs/\(id)"
            let client = try await api.post("\(d)/clients", token: owner).str("client")
            #expect(try await api.post("\(d)/ops", edit(client, cseq: 1), token: owner).status == 200)
            #expect(try await store.deleteApp(id))  // straight to the database: the registry is not told
            let r = try await api.post("\(d)/ops", edit(client, cseq: 2), token: owner)
            #expect(r.status == 404 && r.errorCode == "app_deleted", "\(r.text)")
            #expect(try await api.get("\(d)/snapshot", token: owner).errorCode == "app_deleted")
        }
    }

    @Test func everyCreatingPathWritesTheAppRow() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            #expect(try await api.put("/v1/docs/plain-doc", #"{"template":"example"}"#, token: owner).status == 201)
            let created = try await api.post("/v1/docs", token: owner).j["id"]?.string ?? ""
            #expect(try await api.put("/v1/docs/imported-doc/import", file(name: "Imported file"), token: owner).status == 201)
            let list = try await api.get("/v1/apps?sort_by=earliest_created", token: owner)
            #expect(list.appIds == ["plain-doc", created, "imported-doc"])
            let names = (list.j["data"]?.array ?? []).map { $0["name"]?.string ?? "" }
            #expect(names == ["plain-doc", created, "Imported file"])
            #expect((list.j["data"]?.array ?? []).allSatisfy { $0["author_name"] == "Olivia" && $0["mode"] == "workflow" })
            // Overwriting from a file (the editor's Import DSL) takes the file's name, as Dify.
            let client = try await api.post("/v1/docs/plain-doc/clients", token: owner).str("client")
            let rep = try await api.post("/v1/docs/plain-doc/replace?client=\(client)&cseq=1", file(name: "Replaced"), token: owner)
            #expect(rep.status == 200, "\(rep.text)")
            #expect(try await api.get("/v1/apps/plain-doc", token: owner).j["name"] == "Replaced")
        }
    }

    @Test func migrationGivesOlderDocumentsTheirAppRows() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            let (editorId, editor) = try await api.member("editor@example.com", role: "editor", name: "Eddie", inviter: owner)
            // Three documents of an "older server": one imported, one edited by the editor, one untouched.
            #expect(try await api.put("/v1/docs/old-import/import", """
                app: {name: Old file, mode: advanced-chat, icon: "🐢", icon_background: "#ABCDEF", description: from before}
                kind: app
                version: 0.3.1
                workflow:
                  graph:
                    nodes:
                    - id: s
                      data: {type: start, title: Start, variables: []}
                    edges: []
                """, token: owner).status == 201)
            #expect(try await api.put("/v1/docs/old-edited", #"{"template":"example"}"#, token: owner).status == 201)
            #expect(try await api.put("/v1/docs/old-plain", #"{"template":"empty"}"#, token: owner).status == 201)
            let client = try await api.post("/v1/docs/old-edited/clients", token: editor).str("client")
            #expect(try await api.post("/v1/docs/old-edited/ops", edit(client, cseq: 1), token: editor).status == 200)
            var lastCommit = Date.distantPast
            for try await t in try await store.client.query("SELECT max(committed_at) FROM ops WHERE doc_id = 'old-edited'", logger: store.logger)
                .decode(Date.self) { lastCommit = t }
            // The older server had no apps table rows and no documents.updated_at.
            _ = try await store.client.query("DELETE FROM apps", logger: store.logger)
            _ = try await store.client.query("UPDATE documents SET updated_at = NULL", logger: store.logger)
            _ = try await store.client.query("UPDATE documents SET created_at = now() - interval '2 days' WHERE id = 'old-plain'", logger: store.logger)
            #expect(try await api.get("/v1/apps", token: owner).appIds.isEmpty)

            #expect(try await store.backfillApps() == 3)
            #expect(try await store.backfillApps() == 0)  // idempotent
            let imported = try #require(try await store.app("old-import", viewer: editorId))
            #expect(imported.name == "Old file" && imported.mode == "advanced-chat" && imported.icon == "🐢" && imported.iconBackground == "#ABCDEF")
            #expect(imported.description == "from before" && imported.iconType == "emoji")
            let edited = try #require(try await store.app("old-edited", viewer: editorId))
            #expect(edited.name == "old-edited" && edited.mode == "workflow" && edited.icon == "🤖" && edited.createdBy == editorId)
            #expect(edited.authorName == "Eddie")
            #expect(abs(edited.updatedAt.timeIntervalSince(lastCommit)) < 0.001)
            let plain = try #require(try await store.app("old-plain", viewer: editorId))
            // No client id: the workspace owner; created and last modified at the document's creation.
            #expect(plain.authorName == "Olivia" && plain.createdAt == plain.updatedAt)
            #expect(plain.createdAt < Date().addingTimeInterval(-86_400))
            let list = try await api.get("/v1/apps", token: owner)
            #expect(list.appIds == ["old-edited", "old-import", "old-plain"], "\(list.text)")
        }
    }
}
