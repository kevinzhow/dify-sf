import CollabCore
import CollabStore
import Foundation
import HTTPTypes
import Testing
import VaporTesting
@testable import CollabServer

/// Accounts without a database: Dify's password scheme and rule, tokens, roles, the login rate limit.
@Suite("Accounts")
struct AccountsTests {
    @Test func passwordHashesAreDifys() throws {
        // Dify's libs/password.py: base64(hexlify(pbkdf2_hmac("sha256", pw, salt, 10000))) for salt = bytes(range(16)).
        let salt = Array(UInt8(0)...UInt8(15))
        let expected = "OTkwMTVhM2UyNzE5NGNhNWU2ODNiNjA4NjZjMDA1M2ZmZmFhNmI5YmE1NmMxMTc5MzUxZTVkNTI4NmY2NmExYg=="
        #expect(try Passwords.hash("Dify-pass-1", salt: salt) == expected)
        #expect(Passwords.verify("Dify-pass-1", hash: expected, salt: "AAECAwQFBgcICQoLDA0ODw=="))
        #expect(!Passwords.verify("Dify-pass-2", hash: expected, salt: "AAECAwQFBgcICQoLDA0ODw=="))
        #expect(!Passwords.verify("Dify-pass-1", hash: "garbage", salt: "AAECAwQFBgcICQoLDA0ODw=="))
        let (h, s) = try Passwords.hash("another-1")
        #expect(Passwords.verify("another-1", hash: h, salt: s) && Data(base64Encoded: s)?.count == 16)
        let (h2, s2) = try Passwords.hash("another-1")
        #expect(h2 != h && s2 != s)  // fresh salt every time
    }

    @Test func thePasswordRuleIsDifys() {
        // Same answers as Python's re.match(r"^(?=.*[a-zA-Z])(?=.*\d).{8,}$", pw).
        for (pw, ok) in [("abcdefg1", true), ("abcdefgh", false), ("12345678", false), ("abc1234", false), ("ab c1234", true),
                         ("pässwörd1", true), ("abcdefg\u{661}", true), ("abcdefg\n1", false)] {
            #expect(Passwords.isValid(pw) == ok, "\(pw)")
        }
    }

    @Test func tokensAreOpaqueAndStoredHashed() {
        let t = Tokens.random()
        #expect(t.count == 43 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(Tokens.random() != t)
        let h = Tokens.sha256(t)
        #expect(h.count == 64 && h != t && Tokens.sha256(t) == h)
        #expect(Tokens.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func rolesAreDifys() {
        #expect(Role.allCases.filter(\.canEdit) == [.owner, .admin, .editor])
        #expect(Role.allCases.filter(\.isPrivileged) == [.owner, .admin])
        #expect(Role(rawValue: "dataset_operator") == .datasetOperator)
    }

    @Test func theLoginRateLimitIsDifys() async throws {
        let limiter = LoginLimiter(maxFailures: 5, lockoutSeconds: 1)
        for _ in 0..<5 { await limiter.recordFailure("a@x.io") }
        #expect(await !limiter.isLocked("a@x.io"))  // Dify: locked when the count is MORE than 5
        await limiter.recordFailure("a@x.io")
        #expect(await limiter.isLocked("a@x.io"))
        #expect(await !limiter.isLocked("b@x.io"))
        await limiter.reset("a@x.io")
        #expect(await !limiter.isLocked("a@x.io"))
        for _ in 0..<6 { await limiter.recordFailure("a@x.io") }
        try await Task.sleep(for: .milliseconds(1100))
        #expect(await !limiter.isLocked("a@x.io"))  // the window passed
    }
}

private let docBody = #"{"template":"example"}"#
private func ops(_ client: String, cseq: Int = 1, value: String = "x") -> String {
    #"{"client":"\#(client)","ops":[{"cseq":\#(cseq),"base":0,"op":{"t":"setField","node":"llm","field":{"k":"config","path":["prompt"]},"value":"\#(value)"}}]}"#
}

/// Accounts against Postgres and the real routes (protocol 1.8), each test on a fresh database.
@Suite("Accounts routes", .enabled(if: testDbHost != nil))
struct AuthRouteTests {
    @Test func setupHappensOnce() async throws {
        try await withServer { api, _, _ in
            #expect(try await api.get("/v1/setup").json["step"] == .string("not_started"))
            let weak = try await api.post("/v1/setup", #"{"email":"o@example.com","name":"O","password":"short1"}"#)
            #expect(weak.status == 400 && weak.errorCode == "invalid_password")
            #expect(try await api.post("/v1/setup", #"{"email":"not-an-email","name":"O","password":"owner-pass-1"}"#).status == 400)
            let ok = try await api.post("/v1/setup", #"{"email":"Owner@Example.com","name":"Olivia","password":"owner-pass-1","timezone":"Europe/Berlin","language":"en-US"}"#)
            #expect(ok.status == 201 && !ok.str("access_token").isEmpty && !ok.str("refresh_token").isEmpty)
            let account = ok.obj("account")
            #expect(account["role"] == .string("owner") && account["email"] == .string("Owner@Example.com") && account["name"] == .string("Olivia"))
            #expect(account["timezone"] == .string("Europe/Berlin") && account["interface_language"] == .string("en-US"))
            #expect(account["id"] != nil && account["created_at"] != nil)
            #expect(try await api.get("/v1/setup").json["step"] == .string("finished"))
            let again = try await api.post("/v1/setup", #"{"email":"x@example.com","name":"X","password":"owner-pass-1"}"#)
            #expect(again.status == 409 && again.errorCode == "setup_done")
        }
    }

    @Test func loginSucceedsAndFailsTheSameWayForUnknownEmails() async throws {
        try await withServer { api, _, _ in
            _ = try await api.setupOwner(email: "owner@example.com", password: "owner-pass-1")
            let ok = try await api.post("/v1/auth/login", #"{"email":"OWNER@example.com","password":"owner-pass-1","remember_me":true}"#)
            #expect(ok.status == 200 && !ok.str("access_token").isEmpty && ok.obj("account")["role"] == .string("owner"))
            #expect(try await api.get("/v1/account", token: ok.str("access_token")).str("email") == "owner@example.com")
            let wrong = try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"wrong-pass-1"}"#)
            let unknown = try await api.post("/v1/auth/login", #"{"email":"nobody@example.com","password":"wrong-pass-1"}"#)
            #expect(wrong.status == 401 && wrong.errorCode == "invalid_credentials")
            #expect(unknown.status == wrong.status && unknown.text == wrong.text)
            #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com"}"#).status == 401)
        }
    }

    @Test func repeatedFailuresLockTheEmail() async throws {
        var cfg = ServerConfig.defaults
        cfg.loginLockoutSeconds = 2
        try await withServer(config: cfg) { api, _, _ in
            _ = try await api.setupOwner(email: "owner@example.com", password: "owner-pass-1")
            for _ in 0..<6 {
                #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"bad-pass-1"}"#).status == 401)
            }
            let locked = try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#)
            #expect(locked.status == 429 && locked.errorCode == "login_rate_limited")
            try await Task.sleep(for: .milliseconds(2200))
            #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#).status == 200)
        }
    }

    @Test func refreshRotatesAndLogoutRevokes() async throws {
        try await withServer { api, _, _ in
            _ = try await api.setupOwner(email: "owner@example.com", password: "owner-pass-1")
            let login = try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#)
            let (a1, r1) = (login.str("access_token"), login.str("refresh_token"))
            let next = try await api.post("/v1/auth/refresh", #"{"refresh_token":"\#(r1)"}"#)
            #expect(next.status == 200)
            let (a2, r2) = (next.str("access_token"), next.str("refresh_token"))
            #expect(!a2.isEmpty && a2 != a1 && r2 != r1)
            // The old refresh token is spent; the new pair works; the old access token lives until it expires (Dify's JWT).
            let reused = try await api.post("/v1/auth/refresh", #"{"refresh_token":"\#(r1)"}"#)
            #expect(reused.status == 401 && reused.errorCode == "unauthorized")
            #expect(try await api.get("/v1/account", token: a2).status == 200)
            #expect(try await api.get("/v1/account", token: a1).status == 200)
            #expect(try await api.post("/v1/auth/refresh", #"{"refresh_token":"garbage"}"#).status == 401)

            // Another sign-in (another device) is a separate session.
            let other = try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#)
            // Logout revokes every token of the session: also the pre-refresh access token and the current refresh token.
            #expect(try await api.post("/v1/auth/logout", token: a2).status == 204)
            #expect(try await api.get("/v1/account", token: a2).status == 401)
            #expect(try await api.get("/v1/account", token: a1).status == 401)
            #expect(try await api.post("/v1/auth/refresh", #"{"refresh_token":"\#(r2)"}"#).status == 401)
            #expect(try await api.get("/v1/account", token: other.str("access_token")).status == 200)
            #expect(try await api.post("/v1/auth/logout").status == 401)
        }
    }

    @Test func everyProtectedEndpointNeedsAToken() async throws {
        try await withServer { api, store, _ in
            let owner = try await api.setupOwner()
            let doc = "t-auth-\(UUID().uuidString.lowercased().prefix(8))"
            #expect(try await api.put("/v1/docs/\(doc)", docBody, token: owner).status == 201)
            let comment = try await api.post("/v1/docs/\(doc)/comments", #"{"position_x":1,"position_y":2,"content":"c"}"#, token: owner).str("id")
            let d = "/v1/docs/\(doc)"
            let protected: [(HTTPRequest.Method, String)] = [
                (.post, "/v1/auth/logout"), (.get, "/v1/account"), (.put, "/v1/account/name"), (.put, "/v1/account/password"),
                (.get, "/v1/workspace/members"), (.post, "/v1/workspace/members/invite-email"),
                (.put, "/v1/workspace/members/x/update-role"), (.delete, "/v1/workspace/members/x"),
                (.post, "/v1/docs"), (.put, d), (.get, d), (.post, "/v1/docs/import"), (.put, "\(d)/import"), (.get, "\(d)/export"),
                (.get, "\(d)/meta"), (.post, "\(d)/secrets"), (.get, "\(d)/snapshot"), (.post, "\(d)/clients"), (.get, "\(d)/clients"),
                (.put, "\(d)/clients/c1"), (.post, "\(d)/ops"), (.get, "\(d)/events"), (.get, "\(d)/comments"), (.post, "\(d)/comments"),
                (.get, "\(d)/comments/mention-users"), (.get, "\(d)/comments/\(comment)"), (.put, "\(d)/comments/\(comment)"),
                (.delete, "\(d)/comments/\(comment)"), (.post, "\(d)/comments/\(comment)/resolve"), (.post, "\(d)/comments/\(comment)/replies"),
                (.put, "\(d)/comments/\(comment)/replies/r"), (.delete, "\(d)/comments/\(comment)/replies/r"),
            ]
            for (m, p) in protected {
                let none = try await api.send(m, p, "{}")
                #expect(none.status == 401 && none.errorCode == "unauthorized", "\(m) \(p): \(none.status) \(none.text)")
                #expect(try await api.send(m, p, "{}", token: "not-a-token").status == 401, "\(m) \(p) with a bad token")
                #expect(try await api.send(m, p, "{}", headers: [("Authorization", "Basic \(owner)")]).status == 401, "\(m) \(p) basic")
            }
            // The token goes in the header; `?access_token=` is for the event stream only.
            #expect(try await api.get("\(d)/snapshot?access_token=\(owner)").status == 401)
            // Public: health, setup, login, refresh, activation.
            #expect(try await api.get("/v1/setup").status == 200)
            #expect(try await api.post("/v1/activate/check", #"{"token":"nope"}"#).json["is_valid"] == .bool(false))
            #expect(try await api.get("/v1/activate/check?token=nope").json["is_valid"] == .bool(false))
            #expect(try await store.documentHead(doc) == 0)
        }
    }

    @Test func rolesDecideWhoWritesAndWhoSeesSecrets() async throws {
        try await withServer { api, _, registry in
            let owner = try await api.setupOwner()
            let (_, admin) = try await api.member("admin@example.com", role: "admin", inviter: owner)
            let (_, editor) = try await api.member("editor@example.com", role: "editor", inviter: owner)
            let (_, normal) = try await api.member("normal@example.com", role: "normal", inviter: owner)
            let (_, operatorToken) = try await api.member("ops@example.com", role: "dataset_operator", inviter: owner)
            let doc = "t-roles-\(UUID().uuidString.lowercased().prefix(8))"
            let d = "/v1/docs/\(doc)"
            #expect(try await api.put(d, docBody, token: normal).status == 403)
            #expect(try await api.put(d, docBody, token: editor).status == 201)

            for (who, token) in [("normal", normal), ("dataset_operator", operatorToken)] {
                // Read-only: the whole batch is refused, nothing is applied; reads and the stream work.
                let refused = try await api.post("\(d)/ops", ops("ro-\(who)"), token: token)
                #expect(refused.status == 403 && refused.errorCode == "forbidden", "\(who)")
                #expect(try await api.get("\(d)/snapshot", token: token).json["seq"] == .int(0))
                #expect(try await api.get("\(d)/export?format=json", token: token).status == 200)
                #expect(try await api.get("\(d)/meta", token: token).status == 200)
                #expect(try await api.get("\(d)/comments", token: token).status == 200)
                #expect(try await api.post("\(d)/clients", token: token).status == 201)  // needed to stream as a client
                #expect(try await api.post("\(d)/comments", #"{"position_x":1,"position_y":2,"content":"c"}"#, token: token).status == 403)
                #expect(try await api.post("\(d)/secrets", #"{"value":"v"}"#, token: token).status == 403)
                #expect(try await api.put("\(d)/import", "app: {}", token: token).status == 403)
                #expect(try await api.post("/v1/workspace/members/invite-email", #"{"emails":["z@example.com"],"role":"normal"}"#,
                                           token: token).status == 403)
            }
            let stream = try await api.client.send(.get, headers: [.authorization: "Bearer \(normal)"], to: "\(d)/events")
            #expect(stream.status.code == 200)
            await registry.finishAll()
            #expect(try await stream.body.requireString().contains("event: ready"))

            #expect(try await api.post("\(d)/ops", ops("ed"), token: editor).status == 200)
            #expect(try await api.post("\(d)/ops", ops("ad", value: "y"), token: admin).status == 200)
            // Secrets in an export: owner and admin only.
            #expect(try await api.get("\(d)/export?include_secret=true", token: editor).status == 403)
            #expect(try await api.get("\(d)/export?include_secret=true", token: admin).status == 200)
            #expect(try await api.get("\(d)/export?include_secret=true", token: owner).status == 200)
            // Member management: privileged only; anyone lists.
            #expect(try await api.post("/v1/workspace/members/invite-email", #"{"emails":["z@example.com"],"role":"normal"}"#,
                                       token: editor).status == 403)
            #expect(try await api.post("/v1/workspace/members/invite-email", #"{"emails":["z@example.com"],"role":"normal"}"#,
                                       token: admin).status == 201)
            let members = try await api.get("/v1/workspace/members", token: normal)
            #expect(members.status == 200 && members.list("accounts").count == 6)
        }
    }

    @Test func invitationsActivateAccounts() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner(name: "Olivia")
            let bad = try await api.post("/v1/workspace/members/invite-email", #"{"emails":["a@example.com"],"role":"owner"}"#, token: owner)
            #expect(bad.status == 400 && bad.errorCode == "invalid_role")
            let inv = try await api.post("/v1/workspace/members/invite-email",
                                         #"{"emails":["Bo@Example.com","not-an-email","owner@example.com"],"role":"editor"}"#, token: owner)
            #expect(inv.status == 201)
            let results = inv.list("invitation_results").map { r -> [String: Value] in if case .map(let m) = r { return m }; return [:] }
            #expect(results.map { $0["status"] } == [.string("success"), .string("failed"), .string("already_member")])
            guard case .string(let url)? = results[0]["url"], let token = url.split(separator: "token=").last.map(String.init) else {
                Issue.record("no link: \(inv.text)"); return
            }
            #expect(url.hasPrefix("/activate?email=Bo%40Example.com&token="))
            // Pending until activated.
            let pending = try await api.get("/v1/workspace/members", token: owner).list("accounts")
            #expect(pending.contains { if case .map(let m) = $0 { return m["email"] == .string("Bo@Example.com") && m["status"] == .string("pending") && m["role"] == .string("editor") }; return false })
            let check = try await api.post("/v1/activate/check", #"{"token":"\#(token)"}"#)
            #expect(check.json["is_valid"] == .bool(true) && check.obj("data")["email"] == .string("Bo@Example.com")
                    && check.obj("data")["workspace_name"] == .string("Olivia's Workspace")
                    && check.obj("data")["requires_setup"] == .bool(true) && check.obj("data")["account_status"] == .string("pending"))
            // Without a password nobody signs in.
            #expect(try await api.post("/v1/auth/login", #"{"email":"bo@example.com","password":"anything-1"}"#).status == 401)
            let weak = try await api.post("/v1/activate", #"{"token":"\#(token)","name":"Bo","password":"weak"}"#)
            #expect(weak.status == 400 && weak.errorCode == "invalid_password")
            let act = try await api.post("/v1/activate", #"{"token":"\#(token)","name":"Bo","password":"bo-pass-123","interface_language":"en-US"}"#)
            #expect(act.status == 200 && act.obj("account")["role"] == .string("editor") && act.obj("account")["name"] == .string("Bo"))
            #expect(act.obj("account")["interface_language"] == .string("en-US"))
            #expect(try await api.post("/v1/activate/check", #"{"token":"\#(token)"}"#).json["is_valid"] == .bool(false))
            let twice = try await api.post("/v1/activate", #"{"token":"\#(token)","name":"Bo","password":"bo-pass-123"}"#)
            #expect(twice.status == 400 && twice.errorCode == "invalid_token")
            #expect(try await api.post("/v1/auth/login", #"{"email":"bo@example.com","password":"bo-pass-123"}"#).status == 200)
            #expect(try await api.post("/v1/workspace/members/invite-email", #"{"emails":["bo@example.com"],"role":"normal"}"#, token: owner)
                .list("invitation_results").first == .map(["email": .string("bo@example.com"), "status": .string("already_member"),
                                                            "message": .string("Account already in workspace.")]))

            // Dify's other way in: sign in with the invitation token, which sets the password.
            let inv2 = try await api.post("/v1/workspace/members/invite-email", #"{"emails":["cy@example.com"],"role":"normal"}"#, token: owner)
            guard case .map(let r2)? = inv2.list("invitation_results").first, case .string(let url2)? = r2["url"],
                  let token2 = url2.split(separator: "token=").last.map(String.init) else { Issue.record("no link"); return }
            #expect(try await api.post("/v1/auth/login", #"{"email":"cy@example.com","password":"cy-pass-123","invite_token":"wrong"}"#).status == 401)
            let viaLogin = try await api.post("/v1/auth/login", #"{"email":"cy@example.com","password":"cy-pass-123","invite_token":"\#(token2)"}"#)
            #expect(viaLogin.status == 200 && viaLogin.obj("account")["role"] == .string("normal"))
            #expect(try await api.post("/v1/auth/login", #"{"email":"cy@example.com","password":"cy-pass-123"}"#).status == 200)
        }
    }

    @Test func theOwnerStaysAndRemovedMembersLoseAccess() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let ownerId = try await api.get("/v1/account", token: owner).str("id")
            let (adminId, admin) = try await api.member("admin@example.com", role: "admin", inviter: owner)
            let (editorId, editor) = try await api.member("editor@example.com", role: "editor", name: "Ed", password: "editor-pass-1", inviter: owner)
            let m = "/v1/workspace/members"
            #expect(try await api.delete("\(m)/\(ownerId)", token: admin).status == 403)
            #expect(try await api.put("\(m)/\(ownerId)/update-role", #"{"role":"normal"}"#, token: admin).status == 403)
            #expect(try await api.put("\(m)/\(editorId)/update-role", #"{"role":"owner"}"#, token: owner).errorCode == "invalid_role")
            #expect(try await api.delete("\(m)/\(ownerId)", token: owner).errorCode == "cannot_operate_self")
            #expect(try await api.put("\(m)/\(adminId)/update-role", #"{"role":"normal"}"#, token: admin).errorCode == "cannot_operate_self")
            #expect(try await api.put("\(m)/nobody/update-role", #"{"role":"normal"}"#, token: owner).status == 404)
            // A role change takes effect on the next request.
            #expect(try await api.put("\(m)/\(editorId)/update-role", #"{"role":"normal"}"#, token: admin).status == 200)
            #expect(try await api.put("/v1/docs/t-x-\(UUID().uuidString.prefix(6))", docBody, token: editor).status == 403)
            // Removal revokes the sessions; the account can no longer sign in to the workspace.
            #expect(try await api.delete("\(m)/\(editorId)", token: admin).status == 200)
            #expect(try await api.get("/v1/account", token: editor).status == 401)
            let login = try await api.post("/v1/auth/login", #"{"email":"editor@example.com","password":"editor-pass-1"}"#)
            #expect(login.status == 403 && login.errorCode == "forbidden")
            #expect(try await api.delete("\(m)/\(editorId)", token: admin).status == 404)
            let roles = try await api.get(m, token: owner).list("accounts").map { v -> Value? in if case .map(let x) = v { return x["role"] }; return nil }
            #expect(roles == [.string("owner"), .string("admin")])
        }
    }

    @Test func clientIdsBelongToTheirAccount() async throws {
        try await withServer { api, _, registry in
            let owner = try await api.setupOwner(name: "Olivia")
            let ownerId = try await api.get("/v1/account", token: owner).str("id")
            let (editorId, editor) = try await api.member("ed@example.com", role: "editor", name: "Ed", inviter: owner)
            let doc = "t-cid-\(UUID().uuidString.lowercased().prefix(8))"
            let d = "/v1/docs/\(doc)"
            #expect(try await api.put(d, docBody, token: owner).status == 201)
            let issued = try await api.post("\(d)/clients", #"{"name":"ignored"}"#, token: owner)
            #expect(issued.status == 201 && issued.json["account"] == .string(ownerId) && issued.json["name"] == .string("Olivia"))
            let mine = issued.str("client")
            // Someone else's client id: 403, nothing applied.
            let foreign = try await api.post("\(d)/ops", ops(mine), token: editor)
            #expect(foreign.status == 403 && foreign.errorCode == "forbidden")
            #expect(try await api.post("\(d)/ops", ops(mine), token: owner).status == 200)
            // A self-chosen id belongs to the first account that uses it.
            #expect(try await api.post("\(d)/ops", ops("ed-tab", value: "e"), token: editor).status == 200)
            #expect(try await api.post("\(d)/ops", ops("ed-tab", cseq: 2, value: "o"), token: owner).status == 403)
            #expect(try await api.put("\(d)/clients/ed-tab", token: owner).status == 403)
            let bound = try await api.put("\(d)/clients/olivia-2", #"{"name":"ignored"}"#, token: owner)
            #expect(bound.status == 200 && bound.json["name"] == .string("Olivia"))
            // The directory names accounts.
            let dir = try await api.get("\(d)/clients", token: editor).obj("clients")
            #expect(dir[mine] == .map(["account": .string(ownerId), "name": .string("Olivia")]))
            #expect(dir["olivia-2"] == .map(["account": .string(ownerId), "name": .string("Olivia")]))
            #expect(dir["ed-tab"] == .map(["account": .string(editorId), "name": .string("Ed")]))
            // A stream with someone else's client id (its `committed` map) is refused; unbound ids stay unbound.
            #expect(try await api.get("\(d)/events?client=\(mine)", token: editor).status == 403)
            let s = try await api.client.send(.get, headers: [.authorization: "Bearer \(editor)"], to: "\(d)/events?client=free-id")
            #expect(s.status.code == 200)
            await registry.finishAll()
            _ = try await s.body.requireString()
            #expect(try await api.get("\(d)/clients", token: editor).obj("clients")["free-id"] == nil)
            // Conflict notices name the author's account.
            let conflict = try await api.post("\(d)/ops", ops("ed-tab", cseq: 2, value: "late"), token: editor)
            #expect(conflict.text.contains(#""byName":"Olivia""#))
        }
    }

    @Test func commentsBelongToAccountsNotClients() async throws {
        try await withServer { api, _, _ in
            _ = try await api.setupOwner(email: "owner@example.com", name: "Olivia", password: "owner-pass-1")
            // Two sign-ins of one account (two devices, two client ids): one author.
            let login = #"{"email":"owner@example.com","password":"owner-pass-1"}"#
            let laptop = try await api.post("/v1/auth/login", login).str("access_token")
            let phone = try await api.post("/v1/auth/login", login).str("access_token")
            let doc = "t-cmt-\(UUID().uuidString.lowercased().prefix(8))"
            let d = "/v1/docs/\(doc)"
            #expect(try await api.put(d, docBody, token: laptop).status == 201)
            let c1 = try await api.post("\(d)/clients", token: laptop).str("client")
            let c2 = try await api.post("\(d)/clients", token: phone).str("client")
            #expect(c1 != c2)
            let made = try await api.post("\(d)/comments", #"{"position_x":1,"position_y":2,"content":"from the laptop"}"#, token: laptop)
            let id = made.str("id")
            let edited = try await api.put("\(d)/comments/\(id)", #"{"content":"edited on the phone"}"#, token: phone)
            #expect(edited.status == 200 && edited.json["created_by"] == made.json["created_by"])
            #expect(try await api.delete("\(d)/comments/\(id)", token: phone).status == 204)
            let dir = try await api.get("\(d)/clients", token: phone).obj("clients")
            #expect(dir[c1] == dir[c2] && dir.count == 2)
        }
    }

    @Test func theEventStreamTakesTheHeaderOrTheQueryParameter() async throws {
        try await withServer { api, _, registry in
            let owner = try await api.setupOwner()
            let doc = "t-sse-\(UUID().uuidString.lowercased().prefix(8))"
            #expect(try await api.put("/v1/docs/\(doc)", docBody, token: owner).status == 201)
            #expect(try await api.get("/v1/docs/\(doc)/events").status == 401)
            #expect(try await api.get("/v1/docs/\(doc)/events?access_token=nope").status == 401)
            let viaHeader = try await api.client.send(.get, headers: [.authorization: "Bearer \(owner)"], to: "/v1/docs/\(doc)/events")
            let viaQuery = try await api.client.send(.get, to: "/v1/docs/\(doc)/events?proto=1.8&access_token=\(owner)")
            #expect(viaHeader.status.code == 200 && viaQuery.status.code == 200)
            await registry.finishAll()
            for s in [viaHeader, viaQuery] {
                let text = try await s.body.requireString()
                #expect(text.contains("event: snapshot") && text.contains("event: ready"))
            }
        }
    }

    @Test func accountSettings() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner(email: "owner@example.com", password: "owner-pass-1")
            let me = try await api.get("/v1/account", token: owner)
            #expect(Set(me.json.keys).isSuperset(of: ["id", "email", "name", "role", "created_at"]))
            #expect(try await api.put("/v1/account/name", #"{"name":"ab"}"#, token: owner).status == 400)
            #expect(try await api.put("/v1/account/name", #"{"name":"Olivia Owner"}"#, token: owner).json["name"] == .string("Olivia Owner"))
            #expect(try await api.get("/v1/account", token: owner).str("name") == "Olivia Owner")
            let wrong = try await api.put("/v1/account/password", #"{"password":"nope-1234","new_password":"next-pass-1","repeat_new_password":"next-pass-1"}"#, token: owner)
            #expect(wrong.status == 400 && wrong.errorCode == "invalid_password")
            #expect(try await api.put("/v1/account/password", #"{"password":"owner-pass-1","new_password":"next-pass-1","repeat_new_password":"other-pass-1"}"#, token: owner).status == 400)
            #expect(try await api.put("/v1/account/password", #"{"password":"owner-pass-1","new_password":"weak","repeat_new_password":"weak"}"#, token: owner).status == 400)
            #expect(try await api.put("/v1/account/password", #"{"password":"owner-pass-1","new_password":"next-pass-1","repeat_new_password":"next-pass-1"}"#, token: owner).status == 204)
            #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#).status == 401)
            #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"next-pass-1"}"#).status == 200)
        }
    }
}
