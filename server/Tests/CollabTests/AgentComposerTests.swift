import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent inline composer transactions", .enabled(if: testDbHost != nil))
struct AgentComposerTests {
    static let nodeID = "inline-agent"
    static func path(_ app: String) -> String { "/v1/apps/\(app)/workflows/draft/nodes/\(nodeID)/agent-composer" }
    static func seed(_ api: API, _ store: PostgresStore) async throws -> (String, String, String) {
        let token = try await api.setupOwner()
        let account = try await api.get("/v1/account", token: token)
        let app = UUID().uuidString.lowercased()
        _ = try await store.createDocument(id: app, initial: Document(nodes: [Node(id: nodeID, type: "agent", title: "Inline", config: [
            "version": .string("2"), "agent_node_kind": .string("dify_agent"), "agent_task": .string("Original task"),
            "agent_declared_outputs": .list([])])]))
        return (token, account.str("id"), app)
    }
    static func payload(head: Int = 0, soul: JSONObject? = nil, key: String = UUID().uuidString.lowercased(), task: String = "New task") -> JSONValue {
        var body: JSONObject = ["variant": "workflow", "expected_seq": .int(head), "idempotency_key": .string(key),
            "save_strategy": "save_to_current_version", "node_job": ["workflow_prompt": .string(task), "declared_outputs": []]]
        body["agent_soul"] = .object(soul ?? AgentInlineConfig.empty)
        return .object(body)
    }

    @Test func configSecretsGraphAndReplayShareOneCommit() async throws {
        try await withServer { api, store, registry in
            let (token, account, app) = try await Self.seed(api, store)
            var soul = AgentInlineConfig.empty
            soul["env"] = ["variables": [["name": "PROJECT", "value": "fixture"]],
                           "secret_refs": [["name": "TOKEN", "value": "fixture-private-agent-secret"]]]
            let body = Self.payload(soul: soul)
            let saved = try await api.send(.put, Self.path(app), body.compactJSON(), token: token)
            #expect(saved.status == 200, "\(saved.text)")
            guard saved.status == 200 else { return }
            #expect(saved.json["document_seq"] == .int(3))
            #expect(!saved.text.contains("fixture-private-agent-secret"))
            let snap = try await registry.sequencer(app).currentSnapshot()
            #expect(snap.seq == 3 && snap.doc.nodes[Self.nodeID]?.config["agent_task"] == .string("New task"))
            let requestID = try #require(body["idempotency_key"]?.string)
            #expect(try await store.clientAccount(app, client: "agent-" + account + "-" + requestID) == account)
            let stored = try await store.currentAgentConfig(doc: app, node: Self.nodeID)
            let config = try #require(stored)
            #expect(config.revision == 1 && !config.soul.contains("fixture-private-agent-secret"))
            #expect(try await store.secrets(app).values.contains("fixture-private-agent-secret"))
            let replay = try await api.send(.put, Self.path(app), body.compactJSON(), token: token)
            #expect(replay.status == 200 && replay.json == saved.json)
            #expect(try await registry.sequencer(app).currentSnapshot().seq == 3)
            let afterReplay = try await store.currentAgentConfig(doc: app, node: Self.nodeID)
            #expect(afterReplay?.id == config.id)
            var conflict = try #require(body.object)
            conflict["node_job"] = ["workflow_prompt": "Different payload", "declared_outputs": []]
            let badReplay = try await api.send(.put, Self.path(app), JSONValue.object(conflict).compactJSON(), token: token)
            #expect(badReplay.status == 409 && badReplay.errorCode == "agent_idempotency_conflict")
            let stale = try await api.send(.put, Self.path(app), Self.payload().compactJSON(), token: token)
            #expect(stale.status == 409 && stale.errorCode == "agent_document_changed")
            let read = try await api.get(Self.path(app), token: token)
            let readJSON = try JSONValue.parse(read.text)
            #expect(read.status == 200 && readJSON["agent_soul"]?["env"]?["secret_refs"]?.array?.first?["value"] == "********")
            let soulRead = try #require(readJSON["agent_soul"]?.object)
            let second = try await api.send(.put, Self.path(app), Self.payload(head: 3, soul: soulRead, task: "Another task").compactJSON(), token: token)
            #expect(second.status == 200, "\(second.text)")
            let finalConfig = try await store.currentAgentConfig(doc: app, node: Self.nodeID)
            #expect(finalConfig?.revision == 2)
            #expect(try await store.secrets(app).count == 1, "masked edits preserve the original private secret reference")
        }
    }

    @Test func failedPrivateWriteRollsBackOpsSecretsAndSnapshot() async throws {
        try await withServer { api, store, registry in
            let (token, user, app) = try await Self.seed(api, store)
            let first = try await api.send(.put, Self.path(app), Self.payload().compactJSON(), token: token)
            #expect(first.status == 200, "\(first.text)")
            let old = try #require(try await store.currentAgentConfig(doc: app, node: Self.nodeID))
            var next = old
            next.id = UUID().uuidString.lowercased(); next.revision += 1
            let badReceipt = AgentComposerReceipt(requestID: "rollback", userID: user + "-wrong", nodeID: Self.nodeID,
                digest: "digest", response: "{}")
            let change = AgentConfigCommit(snapshot: next, expectedSnapshotId: old.id, receipt: badReceipt)
            do {
                _ = try await registry.sequencer(app).replace(client: "fixture-rollback", cseq: 1) { _, _ in
                    (.init(ops: [.setField(Self.nodeID, .config(["agent_task"]), .string("must roll back"))], metadata: nil,
                        secrets: ["rollback-secret": "must roll back"], agentConfig: change), true)
                }
                Issue.record("A failed private receipt must reject the entire document transaction")
            } catch { }
            let snapshot = try await registry.sequencer(app).currentSnapshot()
            #expect(snapshot.seq == 3 && snapshot.doc.nodes[Self.nodeID]?.config["agent_task"] == .string("New task"))
            let current = try await store.currentAgentConfig(doc: app, node: Self.nodeID)
            #expect(current?.id == old.id)
            #expect(try await store.agentConfig(doc: app, node: Self.nodeID, agent: old.agentId, snapshot: next.id) == nil)
            #expect(try await store.secrets(app)["rollback-secret"] == nil)
        }
    }

    @Test func publishedGraphPinsOldConfigAndForeignGraphsCannotReadIt() async throws {
        try await withServer { api, store, registry in
            let (token, user, app) = try await Self.seed(api, store)
            let first = try await api.send(.put, Self.path(app), Self.payload().compactJSON(), token: token)
            #expect(first.status == 200, "\(first.text)")
            let frozen = try await registry.sequencer(app).currentSnapshot()
            let old = try #require(try await store.currentAgentConfig(doc: app, node: Self.nodeID))
            let edited = try await api.send(.put, Self.path(app), Self.payload(head: 3).compactJSON(), token: token)
            #expect(edited.status == 200, "\(edited.text)")
            let versionID = UUID().uuidString.lowercased()
            let version = try await store.publishVersion(app, id: versionID, seq: frozen.seq, state: try WireJSON.encodeString(frozen.doc),
                dsl: "{}", hash: "fixture", markedName: "Frozen", markedComment: "", by: user)
            #expect(version != nil)
            #expect(try await store.publishedAgentSnapshot(version: versionID, node: Self.nodeID) == old.id)
            let latest = try await store.currentAgentConfig(doc: app, node: Self.nodeID)
            #expect(latest?.id != old.id)
            let foreign = UUID().uuidString.lowercased()
            _ = try await store.createDocument(id: foreign, initial: frozen.doc)
            let denied = try await api.get(Self.path(foreign), token: token)
            #expect(denied.status == 404)
            let foreignVersionID = UUID().uuidString.lowercased()
            do {
                _ = try await store.publishVersion(foreign, id: foreignVersionID, seq: frozen.seq, state: try WireJSON.encodeString(frozen.doc),
                    dsl: "{}", hash: "fixture", markedName: "Foreign", markedComment: "", by: user)
                Issue.record("A foreign agent binding must not publish")
            } catch { }
            #expect(try await store.version(foreign, id: foreignVersionID) == nil)
        }
    }

    @Test func anAtomicReaderCanReadItsExactPrivateConfigAfterTheDraftNodeWasDeleted() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await Self.seed(api, store)
            let saved = try await api.put(Self.path(app), Self.payload(task: "Frozen task").compactJSON(), token: token)
            #expect(saved.status == 200)
            let pinned = try #require(try await store.currentAgentConfig(doc: app, node: Self.nodeID))
            _ = try await registry.sequencer(app).replace(client: "delete-for-atomic-reader", cseq: 1) { _, _ in
                (.init(ops: [.removeNode(Self.nodeID)], metadata: nil, secrets: [:]), true)
            }
            let current = try await api.get(Self.path(app), token: token)
            #expect(current.status == 404)
            let identity = "?agent_id=\(pinned.agentId)&snapshot_id=\(pinned.id)"
            let historical = try await api.get(Self.path(app) + identity, token: token)
            #expect(historical.status == 200, "\(historical.text)")
            #expect(try JSONValue.parse(historical.text)["node_job"]?["workflow_prompt"] == "Frozen task")
            let foreign = UUID().uuidString.lowercased()
            _ = try await store.createDocument(id: foreign, initial: Document())
            #expect(try await api.get(Self.path(foreign) + identity, token: token).status == 404)
            #expect(try await api.get(Self.path(app) + "?agent_id=" + pinned.agentId, token: token).status == 400)
        }
    }
}

@Suite("Agent composer concurrent revisions", .enabled(if: testDbHost != nil))
struct AgentComposerRaceTests {
    @Test func twoEditorsCannotOverwriteTheSameDocumentHead() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            let (_, editor) = try await api.member("agent-editor@example.com", role: "editor", inviter: token)
            let path = AgentComposerTests.path(app)
            async let first = api.put(path, AgentComposerTests.payload(task: "Editor A").compactJSON(), token: token)
            async let second = api.put(path, AgentComposerTests.payload(task: "Editor B").compactJSON(), token: editor)
            let responses = try await [first, second]
            #expect(responses.map(\.status).sorted() == [200, 409])
            let current = try await registry.sequencer(app).currentSnapshot()
            #expect(current.seq == 3)
            let config = try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID)
            #expect(config?.revision == 1)
        }
    }
    @Test func aSecretReferenceFromAnotherNameCannotBeAdopted() async throws {
        try await withServer { api, store, _ in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            var soul = AgentInlineConfig.empty
            soul["env"] = ["variables": [], "secret_refs": [["name": "A", "value": "fixture-secret"]]]
            let first = try await api.put(AgentComposerTests.path(app), AgentComposerTests.payload(soul: soul).compactJSON(), token: token)
            #expect(first.status == 200)
            let reply = try JSONValue.parse(first.text)
            var copiedSoul = try #require(reply["agent_soul"]?.object)
            let ref = try #require(reply["agent_soul"]?["env"]?["secret_refs"]?.array?.first?["ref"]?.string)
            copiedSoul["env"] = ["variables": [], "secret_refs": [["name": "B", "ref": .string(ref), "value": "********"]]]
            let rejected = try await api.put(AgentComposerTests.path(app), AgentComposerTests.payload(head: 3, soul: copiedSoul).compactJSON(), token: token)
            #expect(rejected.status == 400 && !rejected.text.contains("fixture-secret"))
            let current = try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID)
            #expect(current?.revision == 1)
        }
    }
}

@Suite("Agent composer access and display versions", .enabled(if: testDbHost != nil))
struct AgentComposerAccessTests {
    @Test func readonlyMembersCannotSaveAndDisplayVersionsKeepTheirNotes() async throws {
        try await withServer { api, store, _ in
            let (owner, _, app) = try await AgentComposerTests.seed(api, store)
            let (_, viewer) = try await api.member("agent-viewer@example.com", role: "normal", inviter: owner)
            let path = AgentComposerTests.path(app)
            let denied = try await api.put(path, AgentComposerTests.payload().compactJSON(), token: viewer)
            #expect(denied.status == 403)
            let anonymous = try await api.get(path)
            #expect(anonymous.status == 401)
            var initial = try #require(AgentComposerTests.payload().object)
            initial["version_note"] = "First note"
            let saved = try await api.put(path, JSONValue.object(initial).compactJSON(), token: owner)
            #expect(saved.status == 200)
            let savedJSON = try JSONValue.parse(saved.text)
            let firstSnapshot = try #require(savedJSON["active_config_snapshot"]?["id"]?.string)
            var next = try #require(AgentComposerTests.payload(head: 3).object)
            next["save_strategy"] = "save_as_new_version"; next["version_note"] = "Second note"
            let second = try await api.put(path, JSONValue.object(next).compactJSON(), token: owner)
            let secondJSON = try JSONValue.parse(second.text)
            #expect(second.status == 200 && secondJSON["active_config_snapshot"]?["display_version"] == 2)
            let historical = try await api.get(path + "?snapshot_id=" + firstSnapshot, token: viewer)
            let historicalJSON = try JSONValue.parse(historical.text)
            #expect(historical.status == 200 && historicalJSON["active_config_snapshot"]?["display_version"] == 1)
            #expect(historicalJSON["active_config_snapshot"]?["version_note"] == "First note")
        }
    }
}
