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

/// A multipart upload of one file (the annotation CSV import).
private func upload(_ api: API, _ path: String, filename: String, _ content: String, token: String,
                    extraFile: Bool = false) async throws -> API.Answer {
    let boundary = "----difysf\(UUID().uuidString.prefix(8))"
    var body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: text/csv\r\n\r\n\(content)\r\n"
    if extraFile {
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"other\"; filename=\"b.csv\"\r\nContent-Type: text/csv\r\n\r\nq,a\r\n"
    }
    body += "--\(boundary)--\r\n"
    return try await api.send(.post, path, body, token: token, headers: [("Content-Type", "multipart/form-data; boundary=\(boundary)")])
}

private let secretFlow = """
    app: {name: Secret flow, mode: workflow, icon: "🔐", icon_background: "#E0F2FE"}
    kind: app
    version: 0.7.0
    workflow:
      environment_variables:
      - {id: e1, name: api_key, value: sk-original-secret, value_type: secret, description: ''}
      - {id: e2, name: region, value: eu, value_type: string, description: ''}
      conversation_variables: []
      features: {opening_statement: hello}
      graph:
        nodes:
        - id: start
          data: {type: start, title: Start, desc: one, variables: []}
        - id: end
          data: {type: end, title: End, outputs: []}
        edges:
        - {id: start-source-end-target, source: start, sourceHandle: source, target: end, targetHandle: target}
    """

/// Protocol 1.11 app detail pages (Access Point, annotations, publish and versions, statistics and logs) against Postgres
/// and the real routes, each test on a fresh database.
@Suite("App detail routes", .enabled(if: testDbHost != nil))
struct AppDetailRouteTests {
    private func create(_ api: API, _ token: String, name: String, mode: String = "workflow") async throws -> String {
        let r = try await api.post("/v1/apps", json(["name": .string(name), "mode": .string(mode)]), token: token)
        #expect(r.status == 201, "\(r.text)")
        return r.j["id"]?.string ?? ""
    }

    /// One op on the start node's `desc` by a fresh client of the caller.
    private func edit(_ api: API, _ id: String, _ value: String, token: String) async throws {
        let client = try await api.post("/v1/docs/\(id)/clients", token: token).str("client")
        let op = #"{"client":"\#(client)","ops":[{"cseq":1,"base":0,"op":{"t":"setField","node":"start","field":{"k":"config","path":["desc"]},"value":"\#(value)"}}]}"#
        let r = try await api.post("/v1/docs/\(id)/ops", op, token: token)
        #expect(r.status == 200, "\(r.text)")
    }

    private func startDesc(_ graph: JSON?) -> String? {
        graph?["nodes"]?.array?.first(where: { $0["id"] == "start" })?["data"]?["desc"]?.string
    }

    @Test func rolesFollowDifyCommunityEditionWithItsQuirks() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let admin = try await api.member("admin@example.com", role: "admin", inviter: owner).token
            let editor = try await api.member("editor@example.com", role: "editor", inviter: owner).token
            let normal = try await api.member("normal@example.com", role: "normal", inviter: owner).token
            let ops = try await api.member("ops@example.com", role: "dataset_operator", inviter: owner).token
            let wf = try await create(api, owner, name: "Flow")
            let chat = try await create(api, owner, name: "Chat", mode: "advanced-chat")
            var keyIds: [String] = []
            for _ in 0..<5 { keyIds.append(try await api.post("/v1/apps/\(wf)/api-keys", token: owner).j["id"]?.string ?? "") }
            let ann = try await api.post("/v1/apps/\(chat)/annotations", #"{"question":"q","answer":"a"}"#, token: owner).j["id"]?.string ?? ""

            func status(_ token: String, _ call: Int) async throws -> Int {
                switch call {
                case 0: return try await api.post("/v1/apps/\(wf)/site", #"{"title":"t"}"#, token: token).status
                case 1: return try await api.post("/v1/apps/\(wf)/site/access-token-reset", token: token).status
                case 2: return try await api.post("/v1/apps/\(wf)/site-enable", #"{"enable_site":true}"#, token: token).status
                case 3: return try await api.post("/v1/apps/\(wf)/api-enable", #"{"enable_api":true}"#, token: token).status
                case 4: return try await api.get("/v1/apps/\(wf)/api-keys", token: token).status
                case 5: return try await api.delete("/v1/apps/\(wf)/api-keys/\(keyIds.removeLast())", token: token).status
                case 6: return try await api.get("/v1/apps/\(chat)/annotations", token: token).status
                case 7: return try await api.get("/v1/apps/\(chat)/annotations/count", token: token).status
                case 8: return try await api.post("/v1/apps/\(chat)/annotations/\(ann)", #"{"question":"q","answer":"a"}"#, token: token).status
                case 9: return try await api.get("/v1/apps/\(wf)/workflows/publish", token: token).status
                case 10: return try await api.get("/v1/apps/\(wf)/workflows", token: token).status
                case 11: return try await api.get("/v1/apps/\(wf)/workflow/statistics/daily-conversations", token: token).status
                case 12: return try await api.get("/v1/apps/\(wf)/workflow-app-logs", token: token).status
                case 13: return try await api.get("/v1/apps/\(chat)/chat-conversations", token: token).status
                case 14: return try await api.get("/v1/apps/\(wf)", token: token).status
                default: return 0
                }
            }
            //                         site reset siteOn apiOn keys delKey annList count annEdit pub vers stats wfLogs chatLogs detail
            let matrix: [(String, [Int])] = [
                (owner, [200, 200, 200, 200, 200, 204, 200, 200, 200, 200, 200, 200, 200, 200, 200]),
                (admin, [200, 200, 200, 200, 200, 204, 200, 200, 200, 200, 200, 200, 200, 200, 200]),
                (editor, [200, 403, 200, 403, 200, 403, 200, 200, 200, 200, 200, 200, 200, 200, 200]),
                (normal, [403, 403, 403, 403, 403, 403, 403, 200, 403, 403, 403, 200, 200, 403, 200]),
                (ops, [403, 403, 403, 403, 403, 403, 403, 200, 403, 403, 403, 200, 200, 403, 200]),
            ]
            for (i, (token, want)) in matrix.enumerated() {
                var got: [Int] = []
                for call in 0..<want.count { got.append(try await status(token, call)) }
                #expect(got == want, "role #\(i)")
            }
            // Dify looks the app up before the owner/admin check of a key delete.
            #expect(try await api.delete("/v1/apps/no-such-app/api-keys/x", token: editor).status == 404)
            #expect(try await api.get("/v1/apps/\(wf)/api-keys").status == 401)
        }
    }

    @Test func siteIsCreatedWithTheAppAndEditedAsDify() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            _ = try await store.client.query("UPDATE accounts SET interface_language = 'ja-JP'", logger: store.logger)
            let id = try await create(api, owner, name: "Sited")
            let app = try await api.get("/v1/apps/\(id)", token: owner).j
            #expect(app["enable_site"] == true && app["enable_api"] == true)
            #expect(app["api_base_url"]?.string?.hasSuffix("/v1") == true)
            let site = app["site"] ?? .null
            let code = site["access_token"]?.string ?? ""
            #expect(code.count == 16 && code.allSatisfy { $0.isLetter || $0.isNumber } && site["code"]?.string == code)
            #expect(site["title"] == "Sited" && site["icon"] == "🤖" && site["icon_background"] == "#FFEAD5")
            #expect(site["default_language"] == "ja-JP", "the creator's interface language")
            #expect(site["customize_token_strategy"] == "not_allow" && site["show_workflow_steps"] == true && site["custom_disclaimer"] == "")
            #expect(site["app_base_url"]?.string?.hasPrefix("http") == true)
            // Behind a proxy the URLs follow its host.
            let proxied = try await api.send(.get, "/v1/apps/\(id)", token: owner,
                                             headers: [("X-Forwarded-Host", "apps.example.com"), ("X-Forwarded-Proto", "https")])
            #expect(proxied.j["site"]?["app_base_url"] == "https://apps.example.com" && proxied.j["api_base_url"] == "https://apps.example.com/v1")

            let r = try await api.post("/v1/apps/\(id)/site", ##"{"title":"Web","default_language":"zh-Hans","chat_color_theme":"#1C64F2","privacy_policy":"https://x.example/p","custom_disclaimer":"ok","show_workflow_steps":false,"prompt_public":true}"##, token: owner)
            #expect(r.status == 200, "\(r.text)")
            #expect(r.j["title"] == "Web" && r.j["default_language"] == "zh-Hans" && r.j["chat_color_theme"] == "#1C64F2")
            #expect(r.j["show_workflow_steps"] == false && r.j["prompt_public"] == true && r.j["access_token"]?.string == code)
            #expect(r.j["app_id"]?.string == id)
            let kept = try await api.post("/v1/apps/\(id)/site", #"{"copyright":"me"}"#, token: owner)
            #expect(kept.j["title"] == "Web" && kept.j["copyright"] == "me")
            for bad in [#"{"default_language":"xx"}"#, #"{"chat_color_theme":"red"}"#, #"{"privacy_policy":"javascript:alert(1)"}"#,
                        json(["custom_disclaimer": .string(String(repeating: "d", count: 513))]),
                        json(["input_placeholder": .string(String(repeating: "p", count: 65))]),
                        #"{"customize_token_strategy":"maybe"}"#, #"{"title":5}"#, #"{"show_workflow_steps":"no"}"#] {
                let b = try await api.post("/v1/apps/\(id)/site", bad, token: owner)
                #expect(b.status == 400 && b.errorCode == "bad_request", "\(bad): \(b.text)")
            }
            let reset = try await api.post("/v1/apps/\(id)/site/access-token-reset", token: owner)
            let newCode = reset.j["access_token"]?.string ?? ""
            #expect(newCode.count == 16 && newCode != code)
            var stored = ""
            for try await c in try await store.client.query("SELECT code FROM app_sites WHERE doc_id = \(id)", logger: store.logger)
                .decode(String.self) { stored = c }
            #expect(stored == newCode)
            // Switches answer the app; the same value changes nothing.
            let off = try await api.post("/v1/apps/\(id)/site-enable", #"{"enable_site":false}"#, token: owner)
            #expect(off.j["enable_site"] == false && off.j["enable_api"] == true)
            #expect(try await api.post("/v1/apps/\(id)/site-enable", #"{}"#, token: owner).status == 400)
            #expect(try await api.post("/v1/apps/\(id)/api-enable", #"{"enable_api":false}"#, token: owner).j["enable_api"] == false)
            #expect(try await api.get("/v1/apps", token: owner).j["data"]?.array?.first?["enable_api"] == false)

            // A copy gets its own site and none of the keys; a deleted app answers app_deleted.
            #expect(try await api.post("/v1/apps/\(id)/api-keys", token: owner).status == 201)
            let copy = try await api.post("/v1/apps/\(id)/copy", #"{"name":"Copied"}"#, token: owner)
            let cid = copy.j["id"]?.string ?? ""
            #expect(copy.j["site"]?["title"] == "Copied" && copy.j["site"]?["access_token"]?.string != newCode)
            #expect(try await api.get("/v1/apps/\(cid)/api-keys", token: owner).j["data"] == .array([]))
            #expect(try await api.delete("/v1/apps/\(cid)", token: owner).status == 204)
            #expect(try await api.post("/v1/apps/\(cid)/site", #"{"title":"x"}"#, token: owner).errorCode == "app_deleted")
            #expect(try await api.get("/v1/apps/\(cid)/api-keys", token: owner).errorCode == "app_deleted")
        }
    }

    @Test func apiKeysAreSealedAtRestAndFoundByTheirHash() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let editor = try await api.member("editor@example.com", role: "editor", inviter: owner).token
            let id = try await create(api, owner, name: "Keys")
            let created = try await api.post("/v1/apps/\(id)/api-keys", token: editor)
            #expect(created.status == 201)
            let token = created.j["token"]?.string ?? "", keyId = created.j["id"]?.string ?? ""
            #expect(token.hasPrefix("app-") && token.count == 28 && created.j["type"] == "app" && created.j["last_used_at"] == .null)
            // The row holds no plaintext: a sealed token and its SHA-256.
            var sealed = "", hash = ""
            for try await (s, h) in try await store.client.query("SELECT sealed_token, token_hash FROM app_api_keys WHERE id = \(keyId)",
                                                                 logger: store.logger).decode((String, String).self) { (sealed, hash) = (s, h) }
            #expect(!sealed.isEmpty && !sealed.contains(token) && !sealed.contains(String(token.dropFirst(4))))
            #expect(hash == Tokens.sha256(token))
            let found = try await store.apiKey(byHash: Tokens.sha256(token))
            #expect(found?.doc == id && found?.id == keyId)
            #expect(try await store.apiKey(byHash: Tokens.sha256("app-unknown")) == nil)
            // The list answers the full key (as Dify's app-key list), oldest first.
            let second = try await api.post("/v1/apps/\(id)/api-keys", token: owner).j["token"]?.string ?? ""
            let list = try await api.get("/v1/apps/\(id)/api-keys", token: editor).j["data"]?.array ?? []
            #expect(list.compactMap { $0["token"]?.string } == [token, second])
            // Another secrets key cannot read it: listed with an empty token; the hash still finds it.
            let other = PostgresStore(client: store.client, logger: store.logger, cipher: SecretsKey.random())
            #expect(try await other.apiKeys(id).map(\.token) == [nil, nil])
            #expect(try await other.apiKey(byHash: Tokens.sha256(token))?.id == keyId)
            // Ten at most.
            for _ in 0..<8 { #expect(try await api.post("/v1/apps/\(id)/api-keys", token: owner).status == 201) }
            let eleventh = try await api.post("/v1/apps/\(id)/api-keys", token: owner)
            #expect(eleventh.status == 400 && eleventh.errorCode == "max_keys_exceeded")
            #expect(try await api.delete("/v1/apps/\(id)/api-keys/\(keyId)", token: owner).status == 204)
            #expect(try await api.delete("/v1/apps/\(id)/api-keys/\(keyId)", token: owner).status == 404)
            #expect(try await store.apiKey(byHash: Tokens.sha256(token)) == nil)
            // A deleted app's keys no longer resolve.
            #expect(try await api.delete("/v1/apps/\(id)", token: owner).status == 204)
            #expect(try await store.apiKey(byHash: Tokens.sha256(second)) == nil)
        }
    }

    @Test func noSecretsKeyNoApiKeys() async throws {
        try await withServer(secretsKey: false) { api, _, _ in
            let owner = try await api.setupOwner()
            let id = try await create(api, owner, name: "Keyless")
            let r = try await api.post("/v1/apps/\(id)/api-keys", token: owner)
            #expect(r.status == 503 && r.errorCode == "secrets_key_missing")
            #expect(try await api.get("/v1/apps/\(id)/api-keys", token: owner).j["data"] == .array([]))
        }
    }

    @Test func annotationsRoundTripThroughDifysCsv() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let chat = try await create(api, owner, name: "Chat", mode: "advanced-chat")
            let wf = try await create(api, owner, name: "Flow")
            let wrong = try await api.get("/v1/apps/\(wf)/annotations", token: owner)
            #expect(wrong.status == 404 && wrong.errorCode == "app_not_found" && wrong.text.contains("advanced-chat"))
            let base = "/v1/apps/\(chat)/annotations"
            #expect(try await api.post(base, #"{"question":"q"}"#, token: owner).status == 400)
            #expect(try await api.post(base, #"{"answer":"a"}"#, token: owner).status == 400)
            #expect(try await api.post(base, #"{"question":"q","content":"from content"}"#, token: owner).j["answer"] == "from content")
            #expect(try await api.post(base, #"{"question":"q","answer":"a","message_id":"00000000-0000-4000-8000-000000000000"}"#,
                                       token: owner).status == 404)
            // A CSV as Dify's export writes it: BOM, header, quotes, commas, a line break inside a field.
            let csv = "\u{FEFF}Question,Answer\r\nplain,text\r\n\"with, comma\",\"with \"\"quotes\"\"\"\r\n\"multi\nline\",yes\r\nnan,skipped\r\n,empty\r\n"
            let imported = try await upload(api, "\(base)/batch-import", filename: "annotations-en-US.csv", csv, token: owner)
            #expect(imported.status == 200 && imported.j["record_count"] == 3 && imported.j["job_status"] == "waiting", "\(imported.text)")
            let job = imported.j["job_id"]?.string ?? ""
            let status = try await api.get("\(base)/batch-import-status/\(job)", token: owner)
            #expect(status.j["job_status"] == "completed" && status.j["error_msg"] == "" && status.j["job_id"]?.string == job)
            #expect(try await api.get("\(base)/batch-import-status/no-such-job", token: owner).status == 400)
            let exported = try await api.get("\(base)/export", token: owner).j["data"]?.array ?? []
            let pairs = Set(exported.compactMap { a -> String? in
                guard let q = a["question"]?.string, let ans = a["answer"]?.string else { return nil }
                return q + "|" + ans
            })
            #expect(pairs == ["plain|text", "with, comma|with \"quotes\"", "multi\nline|yes", "q|from content"])
            #expect(try await api.get("\(base)/count", token: owner).j["count"] == 4)
            // Refusals: Dify's messages, as 200 answers; transport errors with Dify's codes.
            let headerOnly = try await upload(api, "\(base)/batch-import", filename: "a.csv", "question,answer\r\n", token: owner)
            #expect(headerOnly.j["error_msg"]?.string?.contains("at least 1 valid annotation record") == true && headerOnly.j["job_id"] == nil)
            let oneColumn = try await upload(api, "\(base)/batch-import", filename: "a.csv", "question\nq\n", token: owner)
            #expect(oneColumn.j["error_msg"]?.string?.contains("at least 2 columns") == true)
            let longQ = try await upload(api, "\(base)/batch-import", filename: "a.csv", "q,a\n\(String(repeating: "x", count: 2001)),a\n", token: owner)
            #expect(longQ.j["error_msg"] == "Question at row 2 is too long. Maximum 2000 characters allowed.")
            #expect(try await upload(api, "\(base)/batch-import", filename: "a.txt", "q,a\nx,y\n", token: owner).status == 400)
            #expect(try await upload(api, "\(base)/batch-import", filename: "a.csv", "q,a\nx,y\n", token: owner, extraFile: true).errorCode == "too_many_files")
            let none = try await api.post("\(base)/batch-import", "", token: owner)
            #expect(none.status == 400 && none.errorCode == "no_file_uploaded")
            let big = try await upload(api, "\(base)/batch-import", filename: "a.csv", "q,a\n" + String(repeating: "x,y\n", count: 600_000), token: owner)
            #expect(big.status == 413)
            // List, search, pages (Dify's has_more: a full page), edit, delete some, clear.
            let page = try await api.get("\(base)?page=1&limit=2", token: owner).j
            #expect(page["total"] == 4 && page["has_more"] == true && page["data"]?.array?.count == 2 && page["limit"] == 2)
            let found = try await api.get("\(base)?keyword=QUOTES", token: owner).j
            #expect(found["total"] == 1 && found["data"]?.array?.first?["question"] == "with, comma")
            let some = (page["data"]?.array ?? []).compactMap { $0["id"]?.string }
            let first = some.first ?? ""
            let edited = try await api.post("\(base)/\(first)", #"{"question":"Q2","answer":"A2"}"#, token: owner)
            #expect(edited.j["question"] == "Q2" && edited.j["answer"] == "A2" && edited.j["hit_count"] == 0)
            #expect(try await api.post("\(base)/\(first)", #"{"question":"Q2"}"#, token: owner).status == 400)
            #expect(try await api.post("\(base)/no-such", #"{"question":"Q","answer":"A"}"#, token: owner).status == 404)
            let hits = try await api.get("\(base)/\(first)/hit-histories", token: owner).j
            #expect(hits["data"] == .array([]) && hits["total"] == 0 && hits["has_more"] == false)
            #expect(try await api.delete("\(base)?annotation_id=\(some[0])&annotation_id=\(some[1])&annotation_id=unknown", token: owner).status == 204)
            #expect(try await api.get("\(base)/count", token: owner).j["count"] == 2)
            #expect(try await api.delete("\(base)?annotation_id=", token: owner).status == 400)
            #expect(try await api.delete(base, token: owner).status == 204)
            #expect(try await api.get("\(base)/count", token: owner).j["count"] == 0)
        }
    }

    @Test func annotationReplySettingIsStoredAndJobsCompleteAtOnce() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let chat = try await create(api, owner, name: "Chat", mode: "advanced-chat")
            #expect(try await api.get("/v1/apps/\(chat)/annotation-setting", token: owner).j == .object(["enabled": false]))
            #expect(try await api.post("/v1/apps/\(chat)/annotation-reply/enable", #"{"score_threshold":0.9}"#, token: owner).status == 400)
            #expect(try await api.post("/v1/apps/\(chat)/annotation-reply/sideways", "{}", token: owner).status == 404)
            let enable = try await api.post("/v1/apps/\(chat)/annotation-reply/enable",
                                            #"{"score_threshold":0.9,"embedding_provider_name":"openai","embedding_model_name":"text-embedding-3-small"}"#,
                                            token: owner)
            #expect(enable.j["job_status"] == "waiting")
            let job = enable.j["job_id"]?.string ?? ""
            #expect(try await api.get("/v1/apps/\(chat)/annotation-reply/enable/status/\(job)", token: owner).j["job_status"] == "completed")
            #expect(try await api.get("/v1/apps/\(chat)/annotation-reply/disable/status/\(job)", token: owner).status == 400)
            let setting = try await api.get("/v1/apps/\(chat)/annotation-setting", token: owner).j
            #expect(setting["enabled"] == true && setting["score_threshold"]?.double == 0.9)
            #expect(setting["embedding_model"] == .object(["embedding_provider_name": "openai", "embedding_model_name": "text-embedding-3-small"]))
            let sid = setting["id"]?.string ?? ""
            #expect(try await api.post("/v1/apps/\(chat)/annotation-settings/\(sid)", #"{"score_threshold":0.95}"#, token: owner)
                        .j["score_threshold"]?.double == 0.95)
            #expect(try await api.post("/v1/apps/\(chat)/annotation-settings/other", #"{"score_threshold":0.95}"#, token: owner).status == 404)
            // Enabling again keeps the setting's id.
            _ = try await api.post("/v1/apps/\(chat)/annotation-reply/enable",
                                   #"{"score_threshold":0.8,"embedding_provider_name":"openai","embedding_model_name":"m2"}"#, token: owner)
            #expect(try await api.get("/v1/apps/\(chat)/annotation-setting", token: owner).j["id"]?.string == sid)
            let disable = try await api.post("/v1/apps/\(chat)/annotation-reply/disable", "{}", token: owner)
            let djob = disable.j["job_id"]?.string ?? ""
            #expect(try await api.get("/v1/apps/\(chat)/annotation-reply/disable/status/\(djob)", token: owner).j["job_status"] == "completed")
            #expect(try await api.get("/v1/apps/\(chat)/annotation-setting", token: owner).j == .object(["enabled": false]))
        }
    }

    @Test func publishSnapshotsTheExportAndVersionsListAsDify() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            let (editorId, editor) = try await api.member("editor@example.com", role: "editor", name: "Eddie", inviter: owner)
            let imported = try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(secretFlow)]), token: owner)
            let id = imported.j["app_id"]?.string ?? ""
            #expect(!id.isEmpty, "\(imported.text)")
            #expect(try await api.get("/v1/apps/\(id)/workflows/publish", token: owner).text == "null")
            #expect(try await api.get("/v1/apps/\(id)/workflows", token: owner).j["items"] == .array([]))
            #expect(try await api.post("/v1/apps/\(id)/workflows/publish", json(["marked_name": .string(String(repeating: "n", count: 21))]),
                                       token: owner).status == 400)
            let p1 = try await api.post("/v1/apps/\(id)/workflows/publish", #"{"marked_name":"v1","marked_comment":"first"}"#, token: owner)
            #expect(p1.j["result"] == "success" && (p1.j["created_at"]?.int ?? 0) > 1_700_000_000)
            // The version equals the export at publish time.
            let export = try await api.get("/v1/docs/\(id)/export?format=json", token: owner).j["workflow"] ?? .null
            let v1 = try await api.get("/v1/apps/\(id)/workflows/publish", token: owner).j
            #expect(v1["graph"] == export["graph"] && v1["features"] == export["features"])
            #expect(v1["environment_variables"] == export["environment_variables"] && v1["conversation_variables"] == export["conversation_variables"])
            #expect(v1["environment_variables"]?.array?.first?["value"] == "", "secret values never leave")
            #expect(v1["version_number"] == 1 && v1["marked_name"] == "v1" && v1["marked_comment"] == "first" && v1["tool_published"] == false)
            #expect(v1["created_by"]?["name"] == "Olivia" && v1["created_by"]?["email"] == "owner@example.com")
            #expect(v1["version"]?.string?.wholeMatch(of: #/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{6})?/#) != nil)
            #expect(v1["hash"]?.string?.count == 64)
            let v1id = v1["id"]?.string ?? ""

            try await edit(api, id, "two", token: editor)
            #expect(try await api.post("/v1/apps/\(id)/workflows/publish", "", token: editor).status == 200)
            let v2 = try await api.get("/v1/apps/\(id)/workflows/publish", token: owner).j
            let v2id = v2["id"]?.string ?? ""
            #expect(v2["version_number"] == 2 && v2["created_by"]?["id"]?.string == editorId && startDesc(v2["graph"]) == "two")
            #expect(v2["hash"] != v1["hash"])
            // Dify's list: the draft first (id = the app's), then newest first.
            let all = try await api.get("/v1/apps/\(id)/workflows", token: owner).j
            #expect((all["items"]?.array ?? []).compactMap { $0["id"]?.string } == [id, v2id, v1id] && all["has_more"] == false && all["limit"] == 10)
            let draft = all["items"]?.array?.first ?? .null
            #expect(draft["version"] == "draft" && draft["version_number"] == .null && draft["marked_name"] == "")
            #expect(draft["created_by"]?["name"] == "Olivia")
            func ids(_ q: String, _ token: String) async throws -> [String] {
                (try await api.get("/v1/apps/\(id)/workflows?\(q)", token: token).j["items"]?.array ?? []).compactMap { $0["id"]?.string }
            }
            #expect(try await ids("named_only=true", owner) == [v1id])
            #expect(try await ids("user_id=\(editorId)", editor) == [v2id])
            #expect(try await api.get("/v1/apps/\(id)/workflows?user_id=\(editorId)", token: owner).status == 403)
            #expect(try await ids("page=1&limit=2", owner) == [id, v2id])
            let p2 = try await api.get("/v1/apps/\(id)/workflows?page=2&limit=2", token: owner).j
            #expect((p2["items"]?.array ?? []).compactMap { $0["id"]?.string } == [v1id] && p2["has_more"] == false)
            #expect(try await api.get("/v1/apps/\(id)/workflows?limit=101", token: owner).status == 400)
            // Rename, delete rules, numbers never reused.
            let renamed = try await api.patch("/v1/apps/\(id)/workflows/\(v1id)", #"{"marked_comment":"edited"}"#, token: editor)
            #expect(renamed.j["marked_name"] == "v1" && renamed.j["marked_comment"] == "edited" && renamed.j["updated_by"]?["id"]?.string == editorId)
            #expect(try await api.patch("/v1/apps/\(id)/workflows/\(v1id)", "{}", token: owner).status == 400)
            #expect(try await api.patch("/v1/apps/\(id)/workflows/unknown", #"{"marked_name":"x"}"#, token: owner).status == 404)
            let inUse = try await api.delete("/v1/apps/\(id)/workflows/\(v2id)", token: owner)
            #expect(inUse.status == 400 && inUse.text.contains("currently in use"))
            #expect(try await api.delete("/v1/apps/\(id)/workflows/\(id)", token: owner).status == 400)
            #expect(try await api.delete("/v1/apps/\(id)/workflows/unknown", token: owner).status == 404)
            #expect(try await api.post("/v1/apps/\(id)/workflows/publish", "{}", token: owner).status == 200)
            #expect(try await api.delete("/v1/apps/\(id)/workflows/\(v2id)", token: owner).status == 204)
            #expect(try await api.post("/v1/apps/\(id)/workflows/publish", "{}", token: owner).status == 200)
            #expect(try await api.get("/v1/apps/\(id)/workflows/publish", token: owner).j["version_number"] == 4)
        }
    }

    @Test func restoreGoesThroughTheReplacementPathAndKeepsSecrets() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let editor = try await api.member("editor@example.com", role: "editor", inviter: owner).token
            let imported = try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(secretFlow)]), token: owner)
            let id = imported.j["app_id"]?.string ?? ""
            _ = try await api.post("/v1/apps/\(id)/workflows/publish", #"{"marked_name":"one"}"#, token: owner)
            let v1id = try await api.get("/v1/apps/\(id)/workflows/publish", token: owner).j["id"]?.string ?? ""
            try await edit(api, id, "changed", token: editor)
            _ = try await api.put("/v1/apps/\(id)", #"{"name":"Renamed"}"#, token: owner)
            // The editor restores (it never sees the secret): through its own client id, like POST /replace.
            let client = try await api.post("/v1/docs/\(id)/clients", token: editor).str("client")
            let body = #"{"client":"\#(client)","cseq":1}"#
            #expect(try await api.post("/v1/apps/\(id)/workflows/\(id)/restore", body, token: editor).status == 400)
            #expect(try await api.post("/v1/apps/\(id)/workflows/unknown/restore", body, token: editor).status == 404)
            let ownerClient = try await api.post("/v1/docs/\(id)/clients", token: owner).str("client")
            #expect(try await api.post("/v1/apps/\(id)/workflows/\(v1id)/restore", #"{"client":"\#(ownerClient)","cseq":1}"#, token: editor).status == 403,
                    "another account's client id")
            let r = try await api.post("/v1/apps/\(id)/workflows/\(v1id)/restore", body, token: editor)
            #expect(r.status == 200, "\(r.text)")
            #expect(r.j["result"] == "success" && r.j["replayed"] == false && (r.j["ops"]?.int ?? 0) >= 1 && r.j["next_cseq"]?.int == 1 + (r.j["ops"]?.int ?? 0))
            #expect(r.j["hash"]?.string?.count == 64)
            // A retry of the same request is answered as replayed.
            #expect(try await api.post("/v1/apps/\(id)/workflows/\(v1id)/restore", body, token: editor).j["replayed"] == true)
            let export = try await api.get("/v1/docs/\(id)/export?format=json&include_secret=true", token: owner).j
            #expect(startDesc(export["workflow"]?["graph"]) == "one")
            let env = export["workflow"]?["environment_variables"]?.array ?? []
            #expect(env.first(where: { $0["name"] == "api_key" })?["value"] == "sk-original-secret", "the secret survived the restore")
            // The app row and the published version are untouched (Dify's restore writes the draft only).
            #expect(try await api.get("/v1/apps/\(id)", token: owner).j["name"] == "Renamed")
            #expect(try await api.get("/v1/apps/\(id)/workflows/publish", token: owner).j["id"]?.string == v1id)
        }
    }

    @Test func statisticsAndLogsAnswerDifysEmptyShapes() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let normal = try await api.member("normal@example.com", role: "normal", inviter: owner).token
            let wf = try await create(api, owner, name: "Flow")
            let chat = try await create(api, owner, name: "Chat", mode: "advanced-chat")
            for path in ["workflow/statistics/daily-conversations", "workflow/statistics/daily-terminals", "workflow/statistics/token-costs",
                         "workflow/statistics/average-app-interactions", "statistics/daily-messages", "statistics/token-costs"] {
                let r = try await api.get("/v1/apps/\(wf)/\(path)?start=2026-10-01%2000:00&end=2026-10-19%2023:59", token: normal)
                #expect(r.status == 200 && r.j == .object(["data": .array([])]), "\(path): \(r.text)")
            }
            for path in ["statistics/daily-conversations", "statistics/daily-end-users", "statistics/average-session-interactions",
                         "statistics/user-satisfaction-rate", "statistics/tokens-per-second"] {
                #expect(try await api.get("/v1/apps/\(chat)/\(path)", token: normal).j == .object(["data": .array([])]), "\(path)")
            }
            #expect(try await api.get("/v1/apps/\(wf)/statistics/average-session-interactions", token: owner).errorCode == "app_not_found")
            #expect(try await api.get("/v1/apps/\(chat)/workflow/statistics/average-app-interactions", token: owner).errorCode == "app_not_found")
            #expect(try await api.get("/v1/apps/\(chat)/statistics/average-response-time", token: owner).errorCode == "app_not_found")
            #expect(try await api.get("/v1/apps/\(wf)/statistics/daily-messages?start=yesterday", token: owner).status == 400)
            #expect(try await api.get("/v1/apps/\(wf)/statistics/daily-messages?start=2026-10-19%2000:00&end=2026-10-01%2000:00", token: owner).status == 400)
            let logs = try await api.get("/v1/apps/\(wf)/workflow-app-logs?page=2&limit=25&status=failed&keyword=x", token: normal).j
            #expect(logs == .object(["page": 2, "limit": 25, "total": 0, "has_more": false, "data": .array([])]))
            #expect(try await api.get("/v1/apps/\(wf)/workflow-app-logs?status=weird", token: owner).status == 400)
            #expect(try await api.get("/v1/apps/\(chat)/workflow-app-logs", token: owner).errorCode == "app_not_found")
            #expect(try await api.get("/v1/apps/\(wf)/workflow-runs/00000000-0000-4000-8000-000000000000", token: owner).status == 404)
            #expect(try await api.get("/v1/apps/\(wf)/workflow-runs/00000000-0000-4000-8000-000000000000/node-executions", token: owner).j
                        == .object(["data": .array([])]))
            let chats = try await api.get("/v1/apps/\(chat)/chat-conversations?annotation_status=annotated&sort_by=-created_at", token: owner).j
            #expect(chats == .object(["page": 1, "limit": 20, "total": 0, "has_more": false, "data": .array([])]))
            #expect(try await api.get("/v1/apps/\(chat)/chat-conversations?sort_by=name", token: owner).status == 400)
            #expect(try await api.get("/v1/apps/\(wf)/chat-conversations", token: owner).errorCode == "app_not_found")
            #expect(try await api.get("/v1/apps/\(chat)/chat-conversations/00000000-0000-4000-8000-000000000000", token: owner).status == 404)
            #expect(try await api.get("/v1/apps/\(chat)/chat-messages?conversation_id=00000000-0000-4000-8000-000000000000", token: owner).status == 404)
            #expect(try await api.get("/v1/apps/\(chat)/chat-messages", token: owner).status == 400)
        }
    }

    @Test func migrationGivesOlderAppsTheirSites() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let a = try await create(api, owner, name: "Old A")
            let b = try await create(api, owner, name: "Old B")
            _ = try await api.delete("/v1/apps/\(b)", token: owner)
            // An older server: no sites (the columns of `apps` came with their defaults).
            _ = try await store.client.query("DELETE FROM app_sites", logger: store.logger)
            #expect(try await api.get("/v1/apps/\(a)", token: owner).j["site"] == .null)
            #expect(try await store.backfillSites() == 2, "deleted apps keep their rows too")
            #expect(try await store.backfillSites() == 0)
            let app = try await api.get("/v1/apps/\(a)", token: owner).j
            #expect(app["site"]?["title"] == "Old A" && app["site"]?["access_token"]?.string?.count == 16)
            #expect(app["enable_site"] == true && app["enable_api"] == true)
            // Migrating twice changes nothing.
            try await store.migrate()
            #expect(try await api.get("/v1/apps/\(a)", token: owner).j["site"]?["access_token"] == app["site"]?["access_token"])
        }
    }
}
