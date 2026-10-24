import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Published application runtime", .enabled(if: testDbHost != nil))
struct PublicRunTests {
    static func fixture(_ api: API, _ store: PostgresStore) async throws -> (String, String, String, String) {
        let owner = try await api.setupOwner()
        let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(ToolRouteTests.childYAML)]).compactJSON(), token: owner)
        let app = try #require(imported.j["app_id"]?.string)
        #expect(try await api.post("/v1/apps/\(app)/workflows/publish", "{}", token: owner).status == 200)
        let key = try await api.post("/v1/apps/\(app)/api-keys", "{}", token: owner).str("token")
        let site = try #require(try await store.siteJSON(app))
        let code = try #require(try JSONValue.parse(site)["code"]?.string)
        return (owner, app, key, code)
    }
    @Test func publishedRevisionCallerIsolationAndRevocation() async throws {
        try await withServerAndRoutes { api, store, _ in
            let (owner, app, key, code) = try await Self.fixture(api, store)
            #expect(!key.isEmpty)
            #expect(try await api.post("/v1/workflows/run", #"{"inputs":{"q":"hello"},"response_mode":"blocking","user":"alice"}"#, token: owner).status == 401)
            #expect(try await api.post("/v1/workflows/run", #"{"inputs":{"q":"hello"}}"#, token: key).status == 400)
            let first = try await api.post("/v1/workflows/run", #"{"inputs":{"q":"hello"},"response_mode":"blocking","user":"alice"}"#, token: key)
            #expect(first.status == 200, "\(first.text)")
            #expect(first.j["data"]?["status"] == "succeeded" && first.j["data"]?["outputs"]?["q"] == "hello")
            let id = try #require(first.j["workflow_run_id"]?.string)
            let run = try #require(try await store.workflowRun(id: id))
            #expect(run.endUserId != nil && run.createdByRole == "end_user" && run.triggeredFrom == "app-run" && run.version != "draft")
            #expect(run.workflowId == (try await store.latestVersion(app))?.id)
            #expect(try await api.get("/v1/workflows/run/\(id)?user=bob", token: key).status == 404)
            #expect(try await api.get("/v1/workflows/run/\(id)?user=alice", token: key).status == 200)
            let secondKey = try await api.post("/v1/apps/\(app)/api-keys", "{}", token: owner)
            #expect(try await api.get("/v1/workflows/run/\(id)?user=alice", token: secondKey.str("token")).status == 404)
            let events = try await api.get("/v1/workflow/\(id)/events?user=alice&include_state_snapshot=true", token: key)
            #expect(events.status == 200 && events.text.contains("workflow_finished") && !events.text.contains("owner@example.com"))
            #expect(try await api.get("/v1/workflow/\(id)/events?user=bob", token: key).status == 404)
            let client = try await api.post("/v1/docs/\(app)/clients", token: owner).str("client")
            let edit: JSONValue = ["client": .string(client), "ops": [["cseq": 1, "base": 0, "op": ["t": "setField", "node": "end", "field": ["k": "config", "path": ["outputs"]],
                "value": [["variable": "new", "value_selector": ["start", "q"]]]]]]]
            #expect(try await api.post("/v1/docs/\(app)/ops", edit.compactJSON(), token: owner).status == 200)
            let beforePublish = try await api.post("/v1/workflows/run", #"{"inputs":{"q":"old"},"response_mode":"blocking","user":"alice"}"#, token: key)
            #expect(beforePublish.j["data"]?["outputs"]?["q"] == "old" && beforePublish.j["data"]?["outputs"]?["new"] == nil)
            #expect(try await api.post("/v1/apps/\(app)/workflows/publish", "{}", token: owner).status == 200)
            let afterPublish = try await api.post("/v1/workflows/run", #"{"inputs":{"q":"new"},"response_mode":"blocking","user":"alice"}"#, token: key)
            #expect(afterPublish.j["data"]?["outputs"]?["new"] == "new")
            #expect(try await store.workflowRun(id: id)?.workflowId == run.workflowId)
            let passport = try await api.send(.get, "/v1/passport", headers: [("X-App-Code", code)])
            #expect(passport.status == 200 && !passport.str("access_token").isEmpty, "\(passport.text)")
            #expect(try await api.get("/v1/parameters", token: passport.str("access_token")).status == 200)
            #expect(try await api.get("/v1/account", token: passport.str("access_token")).status == 401)
            #expect(try await api.post("/v1/apps/\(app)/site/access-token-reset", "{}", token: owner).status == 200)
            #expect(try await api.get("/v1/parameters", token: passport.str("access_token")).status == 401)
            let keys = try await api.get("/v1/apps/\(app)/api-keys", token: owner)
            let keyId = try #require(keys.j["data"]?.array?.first { $0["token"]?.string == key }?["id"]?.string)
            #expect(try await api.delete("/v1/apps/\(app)/api-keys/\(keyId)", token: owner).status == 204)
            #expect(try await api.get("/v1/workflows/run/\(id)?user=alice", token: key).status == 401)
        }
    }
    @Test func monitoringCountsPublishedRunsAndUsageButExcludesDebugging() async throws {
        try await withFakeDaemon { daemon,_ in
            try await withServer(config:runtimeConfig(daemon:daemon)) { api,store,_ in
                let (owner,_,app)=try await RunRouteTests.fixture(api)
                #expect(try await api.post("/v1/apps/\(app)/workflows/publish","{}",token:owner).status==200)
                let key=try await api.post("/v1/apps/\(app)/api-keys","{}",token:owner).str("token")
                for user in ["alice","bob","alice"] {
                    let answer=try await api.post("/v1/workflows/run",JSONValue.object(["inputs":["q":"hi published"],"user":.string(user),"response_mode":"blocking"]).compactJSON(),token:key)
                    #expect(answer.status==200 && answer.j["data"]?["total_tokens"]==8,"\(answer.text)")
                }
                let variables=try await api.get("/v1/apps/\(app)/workflows/draft/nodes/llm/variables",token:owner)
                #expect(variables.j["items"]?.array?.isEmpty==true,"Published runs must not overwrite debugger variables")
                #expect(try await api.post("/v1/apps/\(app)/workflows/draft/run",#"{"inputs":{"q":"hi debug"}}"#,token:owner).status==200)
                let logs=try await api.get("/v1/apps/\(app)/workflow-app-logs?limit=2",token:owner)
                #expect(logs.status==200 && logs.j["total"]==3 && logs.j["has_more"]==true && logs.j["data"]?.array?.count==2,"\(logs.text)")
                #expect(logs.j["data"]?.array?.allSatisfy{$0["created_by_role"]=="end_user" && $0["created_from"]=="service-api" && $0["workflow_run"]?["total_tokens"]==8}==true)
                let next=try await api.get("/v1/apps/\(app)/workflow-app-logs?page=2&limit=2",token:owner)
                #expect(next.j["data"]?.array?.count==1 && next.j["has_more"]==false)
                #expect(try await api.get("/v1/apps/\(app)/workflow-app-logs?status=failed",token:owner).j["total"]==0)
                for (path,field,value) in [("daily-conversations","runs",3),("daily-terminals","terminal_count",2),("token-costs","token_count",24)] {
                    let answer=try await api.get("/v1/apps/\(app)/workflow/statistics/\(path)",token:owner)
                    #expect(answer.status==200 && answer.j["data"]?.array?.first?[field] == .int(value),"\(answer.text)")
                }
                let interactions=try await api.get("/v1/apps/\(app)/workflow/statistics/average-app-interactions",token:owner)
                #expect(interactions.j["data"]?.array?.first?["interactions"]?.double==1.5)
                let before=try await api.get("/v1/apps/\(app)/workflow/statistics/daily-conversations?end=2000-01-01%2000:00",token:owner)
                #expect(before.j["data"]?.array?.isEmpty==true)
                let run=try #require(logs.j["data"]?.array?.first?["workflow_run"]?["id"]?.string)
                let detail=try await api.get("/v1/apps/\(app)/workflow-runs/\(run)",token:owner)
                #expect(detail.j["created_by_role"]=="end_user" && detail.j["created_by_account"] == .null)
                #expect(try await store.workflowRun(id:run)?.endUserId != nil)
            }
        }
    }

    @Test func chatStatisticsUseActualMessageUsageAndOriginalModeGuards() async throws {
        try await withFakeDaemon { daemon,_ in
            try await withServer(config:runtimeConfig(daemon:daemon)) { api,_,_ in
                let (owner,_,_)=try await runtimeFixture(api)
                let yaml = #"""
                {"kind":"app","version":"0.3.1","app":{"mode":"advanced-chat","name":"Chat statistics"},"workflow":{"environment_variables":[],"conversation_variables":[],"features":{},"graph":{"nodes":[
                    {"id":"start","data":{"type":"start","title":"Start","variables":[{"variable":"q","type":"text-input","required":true}]}},
                    {"id":"llm","data":{"type":"llm","title":"LLM","model":{"provider":"langgenius/openai_api_compatible/openai_api_compatible","name":"stub-chat","mode":"chat","completion_params":{}},"prompt_template":[{"role":"user","text":"{{#start.q#}}"}],"context":{"enabled":false,"variable_selector":[]},"vision":{"enabled":false}}},
                    {"id":"answer","data":{"type":"answer","title":"Answer","answer":"{{#llm.text#}}"}}],"edges":[{"id":"a","source":"start","sourceHandle":"source","target":"llm","targetHandle":"target"},{"id":"b","source":"llm","sourceHandle":"source","target":"answer","targetHandle":"target"}]}}}
                """#
                let app=try await api.post("/v1/apps/imports",JSONValue.object(["mode":"yaml-content","yaml_content":.string(yaml)]).compactJSON(),token:owner).str("app_id")
                #expect(try await api.post("/v1/apps/\(app)/workflows/publish","{}",token:owner).status == 200)
                let key=try await api.post("/v1/apps/\(app)/api-keys","{}",token:owner).str("token")
                let first=try await api.post("/v1/chat-messages",#"{"query":"first","inputs":{"q":"hi published"},"user":"alice","response_mode":"blocking"}"#,token:key)
                #expect(first.status == 200,"\(first.text)")
                let message=try #require(first.j["message_id"]?.string)
                #expect(try await api.post("/v1/apps/\(app)/feedbacks",JSONValue.object(["message_id":.string(message),"rating":"like"]).compactJSON(),token:owner).status == 200)
                // The engine measures the actual invocation, rather than trusting the daemon fixture's 0.1s.
                let latency=try #require(first.j["metadata"]?["usage"]?["latency"]?.double)
                let expectedTPS=latency==0 ? 0 : (3/latency*10000).rounded()/10000
                // Dify exposes this latency chart only for completion apps, not advanced-chat.
                #expect(try await api.get("/v1/apps/\(app)/statistics/average-response-time",token:owner).status == 404)
                for (path,field,value) in [("daily-messages","message_count",1.0),("token-costs","token_count",8.0),
                        ("tokens-per-second","tps",expectedTPS),("user-satisfaction-rate","rate",1000.0)] {
                    let response=try await api.get("/v1/apps/\(app)/statistics/\(path)",token:owner)
                    #expect(response.status == 200 && response.j["data"]?.array?.first?[field]?.double == value,"\(path): \(response.text)")
                }
                let rejected=try await api.post("/v1/chat-messages",#"{"query":"failed","inputs":{"q":"[[fail]]"},"user":"alice","response_mode":"blocking"}"#,token:key)
                #expect(rejected.status == 400 && rejected.j["error"]?["code"] == "workflow_run_failed","\(rejected.text)")

            }
        }
    }

}
