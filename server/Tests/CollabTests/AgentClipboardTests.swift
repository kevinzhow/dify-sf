import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent clipboard private resource boundaries", .enabled(if: testDbHost != nil))
struct AgentClipboardTests {
    static func base(_ app: String) -> String { "/v1/apps/\(app)/workflows/draft/agent-clipboard" }

    @Test func portablePasteAndLocalDuplicateOwnDistinctConfigsAndOneIdempotentGraphCommit() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            var soul = AgentInlineConfig.empty
            soul["config_files"] = [["name": "private.txt", "file_kind": "upload_file", "file_id": "source-private-file"]]
            soul["env"] = ["variables": [], "secret_refs": [["name": "TOKEN", "value": "synthetic-private-value"]]]
            let saved = try await api.put(AgentComposerTests.path(app), AgentComposerTests.payload(soul: soul).compactJSON(), token: token)
            #expect(saved.status == 200)
            let source = try #require(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID))
            let exported = try await api.post(Self.base(app) + "/export", JSONValue.object(["expected_seq": 3, "node_ids": [.string(AgentComposerTests.nodeID)]]).compactJSON(), token: token)
            #expect(exported.status == 200, "\(exported.text)")
            #expect(!exported.text.contains("synthetic-private-value") && !exported.text.contains("source-private-file") && !exported.text.contains(source.id))
            let portable = try JSONValue.parse(exported.text)
            var firstNode = try #require(portable["nodes"]?.array?.first?.object)
            firstNode["id"] = "portable-copy"
            var body: JSONObject = ["expected_seq": 3, "idempotency_key": .string(UUID().uuidString.lowercased()), "nodes": [.object(firstNode)],
                "edges": [], "agent_packages": portable["agent_packages"]!, "id_mapping":  .object(JSONObject([(AgentComposerTests.nodeID, "portable-copy")]))]
            let pasted = try await api.post(Self.base(app) + "/paste", JSONValue.object(body).compactJSON(), token: token)
            #expect(pasted.status == 200, "\(pasted.text)")
            let copy = try #require(try await store.currentAgentConfig(doc: app, node: "portable-copy"))
            #expect(copy.agentId != source.agentId && copy.id != source.id)
            let copySoul = try JSONValue.parse(copy.soul)
            #expect(copySoul["config_files"]?.array?.first?["is_missing"] == true)
            #expect(copySoul["env"]?["secret_refs"]?.array?.first?["ref"] == nil)
            let replay = try await api.post(Self.base(app) + "/paste", JSONValue.object(body).compactJSON(), token: token)
            #expect(replay.status == 200 && replay.json == pasted.json)
            let head = try #require(try JSONValue.parse(pasted.text)["document_seq"]?.int)
            #expect(try await registry.sequencer(app).currentSnapshot().seq == head)
            firstNode["id"] = "local-copy"
            body["expected_seq"] = .int(head); body["idempotency_key"] = .string(UUID().uuidString.lowercased()); body["nodes"] = [.object(firstNode)]
            body["id_mapping"] = .object(JSONObject([(AgentComposerTests.nodeID, "local-copy")]))
            body["local_sources"] = ["local-copy": ["node_id": .string(AgentComposerTests.nodeID), "agent_id": .string(source.agentId), "current_snapshot_id": .string(source.id)]]
            let duplicated = try await api.post(Self.base(app) + "/paste", JSONValue.object(body).compactJSON(), token: token)
            #expect(duplicated.status == 200, "\(duplicated.text)")
            let clone = try #require(try await store.currentAgentConfig(doc: app, node: "local-copy"))
            #expect(clone.agentId != source.agentId && clone.id != source.id)
            #expect(clone.soul == source.soul)
            #expect(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID)?.revision == 1)
        }
    }

    @Test func eventArchiveDeduplicatesTransportReplayAndFencesAFormerOwner() async throws {
        try await withServer { api, store, _ in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            try await store.startAgentOperation(session: session, operation: session.executionID + ":0:0", digest: "fixture", tokenHash: "fixture")
            session = try #require(try await store.agentSession(execution: session.executionID))
            let record = #"[{"event_key":"remote:1","event":"thought","data":{"text":"retained"}}]"#
            let log = #"[{"message_id":"remote:1","node_id":"inline-agent","label":"thought","status":"success","data":{"text":"retained"}}]"#
            try await store.appendAgentEvent(session: session, event: "remote:1", record: record, log: log)
            try await store.appendAgentEvent(session: session, event: "remote:1", record: record, log: log)
            let saved = try #require(try await store.agentSession(execution: session.executionID))
            #expect(try JSONValue.parse(saved.usage)["agent_log"]?.array?.count == 1)
            var stale = session; stale.generation += 1
            do { try await store.appendAgentEvent(session: stale, event: "remote:2", record: record, log: log); Issue.record("A stale Agent owner appended an event") } catch { }
            #expect(try await store.pendingAgentJobs().isEmpty)
        }
    }
}
