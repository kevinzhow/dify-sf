import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Published file, human input and chat boundaries", .enabled(if:testDbHost != nil))
struct PublicBoundaryTests {
    static func key(_ api:API,_ app:String,_ owner:String) async throws -> String {
        #expect(try await api.post("/v1/apps/\(app)/workflows/publish","{}",token:owner).status == 200)
        return try await api.post("/v1/apps/\(app)/api-keys","{}",token:owner).str("token")
    }
    @Test func uploadedFileReferencesBelongToTheirPublishedUser() async throws {
        var config=ServerConfig.defaults
        config.files.directory="/work/.build/public-files-"+UUID().uuidString
        config.files.signingKey=Data(repeating:17,count:48).base64EncodedString()
        config.files.externalURL="https://files.fixture.invalid"
        try await withServer(config:config) { api,store,_ in
            let owner=try await api.setupOwner()
            let yaml=ToolRouteTests.childYAML.replacingOccurrences(of:"type: text-input",with:"type: file")
            let app=try await api.post("/v1/docs/import",yaml,token:owner).str("id")
            let key=try await Self.key(api,app,owner)
            let multipart="--fixture\r\nContent-Disposition: form-data; name=\"user\"\r\n\r\nalice\r\n--fixture\r\nContent-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\nContent-Type: text/plain\r\n\r\nhello visitor\r\n--fixture--\r\n"
            let uploaded=try await api.send(.post,"/v1/files/upload",multipart,token:key,headers:[("Content-Type","multipart/form-data; boundary=fixture")])
            #expect(uploaded.status == 201,"\(uploaded.text)")
            let file=try #require(uploaded.j["id"]?.string)
            let stored=try #require(try await store.uploadFile(id:file,workspace:uploadWorkspaceId))
            #expect(stored.endUserId != nil && uploaded.j["created_by"] == .string(stored.endUserId!))
            let mapping:JSONValue=["type":"document","transfer_method":"local_file","upload_file_id":.string(file)]
            let accepted=try await api.post("/v1/workflows/run",JSONValue.object(["inputs":["q":mapping],"user":"alice","response_mode":"blocking"]).compactJSON(),token:key)
            #expect(accepted.status == 200 && accepted.j["data"]?["status"] == "succeeded","\(accepted.text)")
            let rejected=try await api.post("/v1/workflows/run",JSONValue.object(["inputs":["q":mapping],"user":"bob","response_mode":"blocking"]).compactJSON(),token:key)
            #expect(rejected.status == 400,"\(rejected.text)")
            #expect(try await api.get("/v1/files/\(file)/preview?user=alice",token:key).status == 200)
            #expect(try await api.get("/v1/files/\(file)/preview?user=bob",token:key).status == 404)
        }
    }
    @Test func publicHumanPauseRejectsForeignAnswersAndResumesUnderItsExecutor() async throws {
        var config=ServerConfig.defaults;config.humanInputWebEnabled=true
        try await withServerAndRoutes(config:config) { api,store,routes in
            let owner=try await api.setupOwner()
            let yaml=HumanInputRunTests.appYAML().replacingOccurrences(of:"type: human-input",with:"type: human-input\n        delivery_methods: [{type: webapp, enabled: true}]")
            let app=try await api.post("/v1/docs/import",yaml,token:owner).str("id")
            let key=try await Self.key(api,app,owner)
            let paused=try await api.post("/v1/workflows/run",#"{"inputs":{},"user":"alice","response_mode":"blocking"}"#,token:key)
            #expect(paused.status == 200 && paused.j["data"]?["status"] == "paused","\(paused.text)")
            let run=try #require(paused.j["workflow_run_id"]?.string)
            let forms=try await store.humanInputForms(workflowRunId:run)
            let form=try #require(forms.first)
            #expect(form.recipientType == .webapp && form.displayInUi)
            #expect(try await api.get("/v1/form/human_input/\(form.token)?user=bob",token:key).status == 404)
            #expect(try await api.get("/v1/form/human_input/\(form.token)",token:owner).status == 404)
            #expect(try await api.get("/v1/form/human_input/\(form.token)?user=alice",token:key).status == 200)
            #expect(try await api.post("/v1/workflows/tasks/\(run)/stop",#"{"user":"bob"}"#,token:key).status == 404)
            let answer = #"{"inputs":{"reply":"approved"},"action":"approve"}"#
            #expect(try await api.post("/v1/form/human_input/\(form.token)?user=bob",answer,token:key).status == 404)
            #expect(try await api.post("/v1/form/human_input/\(form.token)?user=alice",answer,token:key).status == 200)
            for _ in 0..<100 {
                if try await store.workflowRun(id:run)?.status == "succeeded", await routes.runChannels.existing(run) == nil { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            let finished=try #require(try await store.workflowRun(id:run))
            let outputs=try JSONValue.parse(finished.outputs ?? "{}")
            #expect(finished.status == "succeeded" && outputs["reply"] == "approved")
            #expect(finished.endUserId != nil && finished.executionAccountId == finished.createdBy)
            #expect(await routes.runChannels.existing(run) == nil)
        }
    }
    @Test func publicChatHistoryAndParentMessagesCannotCrossUsers() async throws {
        try await withServer { api,store,_ in
            let owner=try await api.setupOwner()
            let app=try await api.post("/v1/docs/import",ChatRunTests.yaml,token:owner).str("id")
            let key=try await Self.key(api,app,owner)
            let first=try await api.post("/v1/chat-messages",#"{"query":"one","inputs":{},"user":"alice","response_mode":"blocking"}"#,token:key)
            #expect(first.status == 200 && first.j["answer"] == "Query=one","\(first.text)")
            let conversation=try #require(first.j["conversation_id"]?.string),message=try #require(first.j["message_id"]?.string)
            var second:JSONObject=["query":"two","inputs":[:],"user":"alice","response_mode":"blocking","conversation_id":.string(conversation),"parent_message_id":.string(message)]
            #expect(try await api.post("/v1/chat-messages",JSONValue.object(second).compactJSON(),token:key).j["answer"] == "Query=two")
            second["user"]="bob"
            #expect(try await api.post("/v1/chat-messages",JSONValue.object(second).compactJSON(),token:key).status == 404)
            #expect(try await api.get("/v1/messages?conversation_id=\(conversation)&user=bob",token:key).status == 404)
            #expect(try await api.get("/v1/messages?conversation_id=\(conversation)&user=alice",token:key).j["data"]?.array?.count == 2)
            #expect(try await api.get("/v1/conversations?user=bob",token:key).j["data"]?.array?.isEmpty == true)
            let page=try await api.get("/v1/messages?conversation_id=\(conversation)&user=alice&limit=1",token:key)
            #expect(page.j["has_more"] == true && page.j["data"]?.array?.count == 1)
            let cursor=try #require(page.j["data"]?.array?.first?["id"]?.string)
            let older=try await api.get("/v1/messages?conversation_id=\(conversation)&user=alice&limit=1&first_id=\(cursor)",token:key)
            #expect(older.j["has_more"] == false && older.j["data"]?.array?.first?["query"] == "one")
            #expect(try await api.get("/v1/messages?conversation_id=\(conversation)&user=alice&limit=1&first_id=\(UUID().uuidString)",token:key).status == 404)
            #expect(try await api.get("/v1/conversations?user=alice&last_id=\(conversation)&limit=1",token:key).j["data"]?.array?.isEmpty == true)
            #expect(try await api.get("/v1/conversations?user=bob&last_id=\(conversation)&limit=1",token:key).status == 404)
            #expect(try await api.get("/v1/conversations?user=alice&limit=0",token:key).status == 400)
            let ownerId=try await api.get("/v1/account",token:owner).str("id")
            #expect(try await store.chatConversation(doc:app,id:conversation,account:ownerId) == nil)
            #expect(try await api.get("/v1/apps/\(app)/chat-conversations",token:owner).j["total"] == 1)
            #expect(try await api.get("/v1/apps/\(app)/chat-messages?conversation_id=\(conversation)",token:owner).j["data"]?.array?.count == 2)
        }
    }
    @Test func chatFilesHaveUsableLinksInLiveBlockingHistoryAndReconnect() async throws {
        var config=ServerConfig.defaults
        config.files.directory="/work/.build/public-chat-files-"+UUID().uuidString
        config.files.signingKey=Data(repeating:19,count:48).base64EncodedString()
        config.files.externalURL="https://files.fixture.invalid"
        try await withServer(config:config) { api,_,_ in
            let owner=try await api.setupOwner()
            let yaml=ChatRunTests.yaml.replacingOccurrences(of:"data: {title: Start, type: start, variables: []}",with:"data: {title: Start, type: start, variables: [{variable: attachment, type: file, required: true}]}")
                .replacingOccurrences(of:"Query={{#sys.query#}}",with:"{{#start.attachment#}}")
            let app=try await api.post("/v1/docs/import",yaml,token:owner).str("id"),key=try await Self.key(api,app,owner)
            let multipart="--fixture\r\nContent-Disposition: form-data; name=\"user\"\r\n\r\nalice\r\n--fixture\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chat.txt\"\r\nContent-Type: text/plain\r\n\r\nchat file\r\n--fixture--\r\n"
            let upload=try await api.send(.post,"/v1/files/upload",multipart,token:key,headers:[("Content-Type","multipart/form-data; boundary=fixture")]).str("id")
            let body:JSONValue=["query":"show this file","user":"alice","inputs":["attachment":["type":"document","transfer_method":"local_file","upload_file_id":.string(upload)]],"response_mode":"streaming"]
            let streamed=try await api.post("/v1/chat-messages",body.compactJSON(),token:key)
            let frames=HumanInputRunTests.frames(streamed.text),last=try #require(frames.last)
            #expect(last["event"] == "message_end" && last["files"]?.array?.first?["url"]?.string?.hasPrefix("https://files.fixture.invalid/files/") == true,"\(streamed.text)")
            let run=try #require(frames.first?["workflow_run_id"]?.string),conversation=try #require(frames.first?["conversation_id"]?.string)
            let replay=try await api.get("/v1/workflow/\(run)/events?user=alice&include_state_snapshot=true",token:key)
            #expect(HumanInputRunTests.frames(replay.text).last?["files"]?.array?.first?["url"]?.string?.isEmpty == false)
            let history=try await api.get("/v1/messages?conversation_id=\(conversation)&user=alice",token:key)
            #expect(history.j["data"]?.array?.first?["files"]?.array?.first?["url"]?.string?.isEmpty == false)
            var blocking=try #require(body.object);blocking["response_mode"]="blocking"
            let result=try await api.post("/v1/chat-messages",JSONValue.object(blocking).compactJSON(),token:key)
            #expect(result.status == 200 && result.j["files"]?.array?.first?["url"]?.string?.isEmpty == false,"\(result.text)")
        }
    }
    @Test func blockingPublicChatPauseUsesTheOriginalMessageEnvelope() async throws {
        var config=ServerConfig.defaults;config.humanInputWebEnabled=true
        try await withServer(config:config) { api,_,_ in
            let owner=try await api.setupOwner()
            let yaml = #"""
            {"kind":"app","version":"0.3.1","app":{"mode":"advanced-chat","name":"Chat approval"},"workflow":{"environment_variables":[],"conversation_variables":[],"features":{},"graph":{"nodes":[
                {"id":"start","data":{"type":"start","title":"Start","variables":[]}},
                {"id":"human","data":{"type":"human-input","title":"Approve","form_content":"Approve {{#$output.reply#}}","inputs":[{"type":"paragraph","output_variable_name":"reply"}],"user_actions":[{"id":"approve","title":"Approve","button_style":"primary"}],"delivery_methods":[{"type":"webapp","enabled":true}]}},
                {"id":"answer","data":{"type":"answer","title":"Answer","answer":"{{#human.reply#}}"}}],"edges":[{"id":"a","source":"start","sourceHandle":"source","target":"human","targetHandle":"target"},{"id":"b","source":"human","sourceHandle":"approve","target":"answer","targetHandle":"target"}]}}}
            """#
            let app=try await api.post("/v1/docs/import",yaml,token:owner).str("id"),key=try await Self.key(api,app,owner)
            let result=try await api.post("/v1/chat-messages",#"{"query":"approval","inputs":{},"user":"alice","response_mode":"blocking"}"#,token:key)
            #expect(result.status == 200 && result.j["event"] == "workflow_paused","\(result.text)")
            #expect(result.j["workflow_run_id"] == result.j["data"]?["workflow_run_id"] && result.j["message_id"] == result.j["data"]?["message_id"])
            #expect(result.j["data"]?["status"] == "paused" && result.j["conversation_id"]?.string?.isEmpty == false)
        }
    }

}
