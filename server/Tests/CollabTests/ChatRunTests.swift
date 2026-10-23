import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Durable Chatflow console", .enabled(if: testDbHost != nil))
struct ChatRunTests {
    static let yaml = """
    app:
      mode: advanced-chat
      name: durable-chat
    kind: app
    version: 0.3.1
    workflow:
      conversation_variables: []
      environment_variables: []
      features: {}
      graph:
        edges:
        - {id: e1, source: start, sourceHandle: source, target: answer, targetHandle: target}
        nodes:
        - id: start
          data: {title: Start, type: start, variables: []}
        - id: answer
          data: {title: Answer, type: answer, answer: 'Query={{#sys.query#}}'}
    """

    @Test func twoTurnsPersistAndForeignParentIsRejected() async throws {
        try await withStore { store, logger in
            let config = humanInputTestConfig()
            let routes = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: config, logger: logger),
                store: store, config: config, logger: logger)
            try await withApp(configure: { try routes.register(on: $0) }) { application in
                try await application.testing { client in
                    let api = API(client: client)
                    let owner = try await api.setupOwner()
                    let app = try await api.post("/v1/docs/import", Self.yaml, token: owner).str("id")
                    let first = try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run",
                        #"{"query":"one","inputs":{}}"#, token: owner)
                    #expect(first.status == 200)
                    let frames = HumanInputRunTests.frames(first.text)
                    let conversation = try #require(frames.first?["conversation_id"]?.string)
                    let message = try #require(frames.first?["message_id"]?.string)
                    #expect(frames.filter { $0["event"]?.string == "message" }.compactMap { $0["answer"]?.string }.joined() == "Query=one")
                    #expect(frames.last?["event"]?.string == "message_end")
                    let secondBody: JSONValue = ["query": "two", "inputs": [:], "conversation_id": .string(conversation), "parent_message_id": .string(message)]
                    let second = try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", secondBody.compactJSON(), token: owner)
                    #expect(second.status == 200)
                    let history = try await store.chatMessages(doc: app, conversation: conversation, account: try #require((try await store.workflowRun(id: frames.first?["workflow_run_id"]?.string ?? ""))?.createdBy))
                    #expect(history.count == 2)
                    #expect(Set(history.map(\.answer)) == Set(["Query=one", "Query=two"]))
                    #expect(history.first?.parentMessageId == message)
                    var bad = secondBody.object ?? [:]; bad["parent_message_id"] = .string(UUID().uuidString)
                    let rejected = try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", JSONValue.object(bad).compactJSON(), token: owner)
                    #expect(rejected.status == 400)
                    #expect(try await store.chatMessage(runId: history[0].workflowRunId)?.answer == "Query=two")
                }
            }
        }
    }
}

extension ChatRunTests {
    @Test func anotherRealEditorCannotReadOrStopThePrivateConversation() async throws {
        try await withHumanInputServer { api, _, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.yaml, token: owner).str("id")
            let response = try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", #"{"query":"private","inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(response.text)
            let cid = try #require(frames.first?["conversation_id"]?.string)
            let run = try #require(frames.first?["workflow_run_id"]?.string)
            let editor = try await api.member("other-editor@example.com", role: "editor", name: "Other", inviter: owner)
            for path in ["/v1/apps/\(app)/chat-messages?conversation_id=\(cid)",
                         "/v1/apps/\(app)/advanced-chat/workflows/draft/conversation-variables?conversation_id=\(cid)",
                         "/v1/apps/\(app)/workflow-runs/\(run)", "/v1/apps/\(app)/workflow-runs/\(run)/node-executions",
                         "/v1/apps/\(app)/workflows/draft/nodes/answer/last-run",
                         "/v1/workflow/\(run)/events?include_state_snapshot=true"] {
                #expect(try await api.get(path, token: editor.token).status == 404, "private endpoint: \(path)")
            }
            #expect(try await api.post("/v1/apps/\(app)/chat-messages/\(run)/stop", "{}", token: editor.token).status == 404)
            #expect(try await api.post("/v1/apps/\(app)/workflow-runs/tasks/\(run)/stop", "{}", token: editor.token).status == 404)
            #expect(try await api.get("/v1/apps/\(app)/workflow-runs", token: editor.token).list("data").isEmpty)
            let replay = try await api.get("/v1/workflow/\(run)/events?include_state_snapshot=true", token: owner)
            #expect(HumanInputRunTests.frames(replay.text).map { $0["event"]?.string } == ["message_replace", "workflow_finished", "message_end"])
            #expect(try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", #"{"query":"anonymous","inputs":{}}"#).status == 401)
        }
    }

    @Test func iterationAssignmentsPersistForNextTurnWithoutChangingTheParentsLocalPool() async throws {
        let yaml = """
        app: {mode: advanced-chat, name: scoped-conversation}
        kind: app
        version: 0.3.1
        workflow:
          environment_variables: []
          conversation_variables:
          - {id: c30af82d-b2ec-417d-a861-4dd78584faa4, name: answer, value_type: string, value: ''}
          - {id: 6007dd01-6482-468d-990e-8313fc5b8731, name: items, value_type: 'array[string]', value: [one]}
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: iter, targetHandle: target}
            - {id: e2, source: iter, sourceHandle: source, target: answer, targetHandle: target}
            - {id: e3, source: child, sourceHandle: source, target: assign, targetHandle: target}
            nodes:
            - id: start
              data: {type: start, title: Start, variables: []}
            - id: iter
              data:
                type: iteration
                title: Iteration
                start_node_id: child
                iterator_selector: [conversation, items]
                output_selector: [conversation, answer]
                is_parallel: false
            - id: child
              parentId: iter
              type: custom-iteration-start
              data: {type: iteration-start, title: Child}
            - id: assign
              parentId: iter
              data:
                type: assigner
                title: Assigner
                assigned_variable_selector: [conversation, answer]
                write_mode: over-write
                input_variable_selector: [sys, query]
            - id: answer
              data: {type: answer, title: Answer, answer: '{{#conversation.answer#}}'}
        """
        try await withHumanInputServer { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", yaml, token: owner).str("id")
            let first = try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", #"{"query":"first","inputs":{}}"#, token: owner)
            let frames = HumanInputRunTests.frames(first.text)
            let cid = try #require(frames.first?["conversation_id"]?.string)
            let mid = try #require(frames.first?["message_id"]?.string)
            #expect(frames.last?["event"]?.string == "message_end")
            #expect(frames.filter { $0["event"]?.string == "message" }.compactMap { $0["answer"]?.string }.joined() == "")
            let variables = try await api.get("/v1/apps/\(app)/advanced-chat/workflows/draft/conversation-variables?conversation_id=\(cid)", token: owner)
            let variableData = try JSONValue.parse(variables.text)
            #expect(variableData["data"]?.array?.contains { $0["name"]?.string == "answer" && $0["value"]?.string == "first" } == true)
            let body: JSONValue = ["query": "second", "inputs": [:], "conversation_id": .string(cid), "parent_message_id": .string(mid)]
            let second = try await api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", body.compactJSON(), token: owner)
            let next = HumanInputRunTests.frames(second.text)
            #expect(next.filter { $0["event"]?.string == "message" }.compactMap { $0["answer"]?.string }.joined() == "first")
            let run = try #require(next.first?["workflow_run_id"]?.string)
            #expect(try await store.workflowRun(id: run)?.status == "succeeded")
        }
    }
}

extension ChatRunTests {
    @Test func committedButNotYetPublishedTextIsNotDuplicatedByReconnect() async throws {
        var config = ServerConfig.defaults; config.testDefect = "slowChatPublication"
        try await withHumanInputServer(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", Self.yaml, token: owner).str("id")
            async let original = api.post("/v1/apps/\(app)/advanced-chat/workflows/draft/run", #"{"query":"snapshot-race","inputs":{}}"#, token: owner)
            var runId: String?
            for _ in 0..<100 {
                let runs = try await store.workflowRuns(doc: app, triggeredFrom: "debugging", status: nil, limit: 1, lastId: nil)
                if let run = runs?.runs.first, let message = try await store.chatMessage(runId: run.id), message.answer == "Query=snapshot-race" {
                    runId = run.id; break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let run = try #require(runId)
            let replay = try await api.get("/v1/workflow/\(run)/events?include_state_snapshot=true", token: owner)
            let frames = HumanInputRunTests.frames(replay.text)
            let replacement = frames.first { $0["event"]?.string == "message_replace" }?["answer"]?.string ?? ""
            let live = frames.filter { $0["event"]?.string == "message" }.compactMap { $0["answer"]?.string }.joined()
            #expect(replacement + live == "Query=snapshot-race")
            #expect(frames.last?["event"]?.string == "message_end")
            let originalResponse = try await original
            #expect(originalResponse.status == 200)
        }
    }
}

@Suite("Chatflow reconnect cursors")
struct ChatReconnectCursorTests {
    @Test func coveredReasoningKeepsItsFinalMarkerWithoutRepeatingTheText() throws {
        let m = StoredChatMessage(id: "m", docId: "a", conversationId: "c", accountId: "u", parentMessageId: nil,
            workflowRunId: "r", query: "q", inputs: "{}", files: "[]", at: Date())
        var stored = m; stored.answer = "中文"; stored.reasoning = #"{"llm":"思考"}"#
        let snapshot = SnapshotFrames(frames: [], nodeIds: [], formIds: [], pauseGeneration: nil, chat: stored)
        let f: JSONValue = ["event": "reasoning_chunk", "data": ["node_id": "llm", "reasoning": "思考", "is_final": true]]
        let replay = try #require(CollabServer.Routes.reconcileChatFrame(RunExecution.sse(f), snapshot: snapshot, answerOffset: nil,
            reasoning: ChatReasoningCursor(nodeId: "llm", bytes: "思考".utf8.count)))
        let value = try #require(HumanInputRunTests.frames(replay).first)
        #expect(value["data"]?["reasoning"] == "" && value["data"]?["is_final"] == true)
        #expect(CollabServer.Routes.reconcileChatFrame("data: {}\n\n", snapshot: snapshot, answerOffset: "中文".utf8.count, reasoning: nil) == nil)
        #expect(CollabServer.Routes.reconcileChatFrame("data: {}\n\n", snapshot: snapshot, answerOffset: "中文新".utf8.count, reasoning: nil) != nil)
    }
}
