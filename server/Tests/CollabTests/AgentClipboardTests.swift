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
            #expect(try await store.agentEventRecords(execution: session.executionID).count == 1)
            var stale = session; stale.generation += 1
            do { try await store.appendAgentEvent(session: stale, event: "remote:2", record: record, log: log); Issue.record("A stale Agent owner appended an event") } catch { }
            #expect(try await store.pendingAgentJobs().isEmpty)
        }
    }
    @Test func shellCapabilityIsPinnedAndLegacyEventsMigrateWithoutChangingOtherExecutionUsage() async throws {
        try await withServer { api, store, _ in
            let s = try await AgentExecutionStoreTests.seed(api, store)
            #expect(try await store.pinAgentShell(session: s, enabled: false) == false)
            #expect(try await store.pinAgentShell(session: s, enabled: true) == false)
            let legacy = #"{"shell_enabled":false,"total_tokens":9,"agent_events":[{"event_key":"legacy:1","event":"thought","data":{"text":"preserved"}}],"agent_log":[{"message_id":"legacy:1","data":{"text":"preserved"}}]}"#
            _ = try await store.client.query("UPDATE agent_node_sessions SET usage = \(legacy)::jsonb WHERE execution_id = \(s.executionID)", logger: store.logger)
            try await store.migrate()
            try await store.migrate()
            let rows = try await store.agentEventRecords(execution: s.executionID)
            #expect(rows.count == 1 && rows[0].log?.contains("preserved") == true)
            let usage = try JSONValue.parse(try #require(try await store.agentSession(execution: s.executionID)).usage)
            #expect(usage["shell_enabled"] == false && usage["total_tokens"] == 9)
            #expect(usage["agent_events"] == nil && usage["agent_log"] == nil)
        }
    }

    @Test func copyingDuringCollaborationChecksOnlyTheSelectedNodesAndSupportsUnconfiguredPlaceholders() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            _ = try await api.put(AgentComposerTests.path(app), AgentComposerTests.payload().compactJSON(), token: token)
            let sequencer = await registry.sequencer(app)
            _ = try await sequencer.replace(client: "clipboard-placeholders", cseq: 1) { _, _ in
                (.init(ops: [.addNode(Node(id: "empty", type: "agent", config: ["version": .string("2"), "agent_node_kind": .string("dify_agent")])),
                    .addNode(Node(id: "roster", type: "agent", config: ["version": .string("2"), "agent_node_kind": .string("dify_agent"),
                        "agent_binding": .map(["binding_type": .string("roster_agent"), "agent_id": .string("private-roster"), "current_snapshot_id": .string("private-roster-snapshot")])]))], metadata: nil, secrets: [:]), true)
            }
            let before = try await sequencer.currentSnapshot()
            let selected = [AgentComposerTests.nodeID, "empty", "roster"]
            let baseline = try JSONObject(selected.map { ($0, try JSONValue.parse(try WireJSON.encode(before.doc.nodes[$0]!))) })
            _ = try await sequencer.replace(client: "unrelated-collaborator", cseq: 1) { _, _ in
                (.init(ops: [.addNode(Node(id: "unrelated", type: "start"))], metadata: nil, secrets: [:]), true)
            }
            let request: JSONObject = ["expected_seq": .int(before.seq), "node_ids": .array(selected.map(JSONValue.string)), "expected_nodes": .object(baseline)]
            let exported = try await api.post(Self.base(app) + "/export", JSONValue.object(request).compactJSON(), token: token)
            #expect(exported.status == 200, "\(exported.text)")
            #expect(!exported.text.contains("private-roster"))
            let portable = try JSONValue.parse(exported.text)
            let mapping = Dictionary(uniqueKeysWithValues: selected.map { ($0, "copy-" + $0) })
            let nodes = (portable["nodes"]?.array ?? []).map { value -> JSONValue in
                var node = value.object!; node["id"] = .string(mapping[node["id"]!.string!]!); return .object(node)
            }
            let head = try await sequencer.currentSnapshot().seq
            let pasted = try await api.post(Self.base(app) + "/paste", JSONValue.object(["expected_seq": .int(head),
                "idempotency_key": .string(UUID().uuidString.lowercased()), "nodes": .array(nodes), "edges": [],
                "agent_packages": portable["agent_packages"]!, "id_mapping": .object(JSONObject(mapping.map { ($0.key, .string($0.value)) }))]).compactJSON(), token: token)
            #expect(pasted.status == 200, "\(pasted.text)")
            #expect(try await store.currentAgentConfig(doc: app, node: "copy-" + AgentComposerTests.nodeID) != nil)
            #expect(try await store.currentAgentConfig(doc: app, node: "copy-empty") == nil)
            _ = try await sequencer.replace(client: "selected-collaborator", cseq: 1) { _, _ in
                (.init(ops: [.setField(AgentComposerTests.nodeID, .config(["agent_task"]), .string("changed"))], metadata: nil, secrets: [:]), true)
            }
            #expect(try await api.post(Self.base(app) + "/export", JSONValue.object(request).compactJSON(), token: token).status == 409)
        }
    }

}
