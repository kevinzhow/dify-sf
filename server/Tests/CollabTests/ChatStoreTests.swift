import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import PostgresNIO
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

@Suite("Chatflow turn transactions", .enabled(if: testDbHost != nil))
struct ChatStoreTests {
    static func withChatStore(_ body: @escaping @Sendable (PostgresStore, String, String) async throws -> Void) async throws {
        try await withStore { store, logger in
            let config = humanInputTestConfig()
            let routes = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: config, logger: logger),
                store: store, config: config, logger: logger)
            try await withApp(configure: { try routes.register(on: $0) }) { app in
                try await app.testing { client in
                    let api = API(client: client); let token = try await api.setupOwner()
                    let id = try await api.post("/v1/docs/import", ChatRunTests.yaml, token: token).str("id")
                    let account = try #require(try await store.members().first?.id)
                    try await body(store, id, account)
                }
            }
        }
    }
    static func turn(app: String, account: String, conversation: String = UUID().uuidString.lowercased(), parent: String? = nil)
        -> (StoredChatConversation, StoredChatMessage, StoredWorkflowRun, String) {
        let now = Date(), run = UUID().uuidString.lowercased(), lease = UUID().uuidString.lowercased()
        let c = StoredChatConversation(id: conversation, docId: app, accountId: account, inputs: "{}", variables: "{}", at: now)
        let m = StoredChatMessage(id: UUID().uuidString.lowercased(), docId: app, conversationId: conversation, accountId: account,
            parentMessageId: parent, workflowRunId: run, query: "q", inputs: "{}", files: "[]", at: now)
        let r = StoredWorkflowRun(id: run, docId: app, docSeq: 1, workflowId: app, type: "chat", triggeredFrom: "debugging",
            version: "draft", graph: "{}", inputs: "{}", status: "running", createdBy: account, createdAt: now)
        return (c, m, r, lease)
    }
    @Test func concurrentSendsHaveExactlyOneWinner() async throws {
        try await Self.withChatStore { store, app, account in
            let cid = UUID().uuidString.lowercased()
            let turns = [Self.turn(app: app, account: account, conversation: cid), Self.turn(app: app, account: account, conversation: cid)]
            let results = try await withThrowingTaskGroup(of: Bool.self) { group in
                for (c, m, r, lease) in turns {
                    group.addTask {
                        do { _ = try await store.beginChatTurn(conversation: c, message: m, run: r, lease: lease, create: true); return true }
                        catch ChatStoreError.busy { return false }
                    }
                }
                var results: [Bool] = []; for try await result in group { results.append(result) }; return results
            }
            #expect(results.filter { $0 }.count == 1)
            #expect(try await store.chatMessages(doc: app, conversation: cid, account: account).count == 1)
            #expect(try await store.chatConversation(doc: app, id: cid, account: "another-account") == nil)
            #expect(try await store.chatMessages(doc: app, conversation: cid, account: "another-account").isEmpty)
        }
    }
    @Test func invalidParentRollsBackConversationMessageAndWorkflow() async throws {
        try await Self.withChatStore { store, app, account in
            let (c, m, r, lease) = Self.turn(app: app, account: account, parent: UUID().uuidString.lowercased())
            do { _ = try await store.beginChatTurn(conversation: c, message: m, run: r, lease: lease, create: true); Issue.record("foreign parent accepted") }
            catch ChatStoreError.invalidParent {}
            #expect(try await store.chatConversation(doc: app, id: c.id, account: account) == nil)
            #expect(try await store.workflowRun(id: r.id) == nil)
            #expect(try await store.chatMessage(runId: r.id) == nil)
        }
    }
    @Test func abandonedTurnRetainsProgressAndCannotOverwriteItsRetry() async throws {
        try await Self.withChatStore { store, app, account in
            let (c, m, r, lease) = Self.turn(app: app, account: account)
            _ = try await store.beginChatTurn(conversation: c, message: m, run: r, lease: lease, create: true)
            #expect(try await store.saveChatProgress(runId: r.id, lease: lease, answer: "partial", reasoning: "{}", files: "[]", metadata: "{}"))
            _ = try await store.client.query("UPDATE app_chat_conversations SET lease_until = clock_timestamp() - interval '1 second' WHERE active_run_id = \(r.id)", logger: store.logger)
            #expect(try await store.expireChatLeases() == [r.id])
            #expect(try await store.workflowRun(id: r.id)?.status == "failed")
            #expect(try await store.chatMessage(runId: r.id)?.answer == "partial")
            #expect(try await store.renewChatLease(runId: r.id, lease: lease) == false)
            let (next, msg, run, newLease) = Self.turn(app: app, account: account, conversation: c.id, parent: m.id)
            _ = try await store.beginChatTurn(conversation: next, message: msg, run: run, lease: newLease, create: false)
            #expect(try await store.saveChatProgress(runId: r.id, lease: lease, answer: "zombie", reasoning: "{}", files: "[]", metadata: "{}") == false)
            do {
                try await store.finishWorkflowRun(id: r.id, status: "succeeded", outputs: "{}", error: nil, elapsedTime: 1,
                    totalTokens: 0, totalSteps: 1, exceptionsCount: 0, finishedAt: Date(), chatLease: lease)
                Issue.record("obsolete engine overwrote its terminal state")
            } catch {}
            #expect(try await store.workflowRun(id: r.id)?.status == "failed")
            #expect(try await store.chatConversation(doc: app, id: c.id, account: account)?.activeRunId == run.id)
        }
    }
}

extension ChatStoreTests {
    @Test func stopAndCompletionAreCompetingTerminalTransitions() async throws {
        try await Self.withChatStore { store, app, account in
            let (c, m, r, lease) = Self.turn(app: app, account: account)
            _ = try await store.beginChatTurn(conversation: c, message: m, run: r, lease: lease, create: true)
            try await store.finishWorkflowRun(id: r.id, status: "succeeded", outputs: #"{"answer":"done"}"#, error: nil,
                elapsedTime: 1, totalTokens: 7, totalSteps: 3, exceptionsCount: 0, finishedAt: Date(), chatLease: lease)
            #expect(try await store.stopChatTurn(runId: r.id, error: "late stop", at: Date()) == false)
            #expect(try await store.workflowRun(id: r.id)?.status == "succeeded")
            #expect(try await store.chatMessage(runId: r.id)?.status == "normal")
            let (next, msg, run, newLease) = Self.turn(app: app, account: account, conversation: c.id, parent: m.id)
            _ = try await store.beginChatTurn(conversation: next, message: msg, run: run, lease: newLease, create: false)
            #expect(try await store.chatMessageCount(doc: app, conversation: c.id, account: account) == 2)
            #expect(try await store.stopChatTurn(runId: run.id, error: "stop", at: Date()))
            #expect(try await store.stopChatTurn(runId: run.id, error: "again", at: Date()) == false)
            #expect(try await store.chatConversation(doc: app, id: c.id, account: account)?.activeRunId == nil)
            do {
                try await store.finishWorkflowRun(id: run.id, status: "succeeded", outputs: "{}", error: nil, elapsedTime: 1,
                    totalTokens: 0, totalSteps: 1, exceptionsCount: 0, finishedAt: Date(), chatLease: newLease)
                Issue.record("stopped engine rewrote its result")
            } catch {}
            #expect(try await store.workflowRun(id: run.id)?.status == "stopped")
            // A delayed preparation failure has no engine lease yet; it still must not rewrite a stop that won.
            try await store.finishWorkflowRun(id: run.id, status: "failed", outputs: nil, error: "late preparation error", elapsedTime: 0,
                totalTokens: 0, totalSteps: 0, exceptionsCount: 0, finishedAt: Date())
            #expect(try await store.workflowRun(id: run.id)?.status == "stopped")
        }
    }
}


extension ChatStoreTests {
    @Test func aPartialVariableUpdatePreservesOtherDurableValues() async throws {
        try await Self.withChatStore { store, app, account in
            var (conversation, message, run, lease) = Self.turn(app: app, account: account)
            conversation.variables = #"{"first":"original","other":"keep"}"#
            _ = try await store.beginChatTurn(conversation: conversation, message: message, run: run, lease: lease, create: true)
            #expect(try await store.saveChatProgress(runId: run.id, lease: lease, answer: "", reasoning: "{}", files: "[]", metadata: "{}",
                variables: #"{"first":"updated"}"#))
            let saved = try #require(try await store.chatConversation(doc: app, id: conversation.id, account: account))
            let values = try JSONValue.parse(saved.variables)
            #expect(values["first"] == "updated" && values["other"] == "keep")
        }
    }
}
