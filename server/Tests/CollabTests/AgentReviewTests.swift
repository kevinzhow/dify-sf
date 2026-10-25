import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent review boundaries")
struct AgentReviewTests {
    @Test func unconfiguredShellIsOffAndSecretValuesAreNotGuessableFromTheAuditDigest() async {
        let config = ServerConfig.defaults.agentService
        #expect(!config.shellEnabled)
        #expect(await AgentServiceClient(config: config).shellAvailable() == false)
        let a: JSONObject = ["operation_id": "same", "env": ["TOKEN": "guessable-a"]]
        let b: JSONObject = ["operation_id": "same", "env": ["TOKEN": "guessable-b"]]
        #expect(ServerAgentRuntime.operationDigest(a) == ServerAgentRuntime.operationDigest(b))
    }
    @Test func parserAndLogProjectionKeepIdentityAndRedactSecretsWithoutRetainingTerminalSnapshots() throws {
        let frame = "id: 3\nevent: tool_call\ndata: {\"name\":\"shell\",\"phase\":\"finished\",\"output\":\"secret-value\"}"
        let parsed = try AgentServiceClient.parseEvent(frame)
        let event = try #require(parsed)
        let projection = AgentTrace.project(run: "run", node: "node", event: event.id, name: event.name, data: event.data, secrets: ["secret-value"])
        #expect(projection.log?["message_id"] == "run:3")
        #expect(!projection.record.compactJSON().contains("secret-value"))
        #expect(try AgentServiceClient.parseEvent(": keep-alive") == nil)
        let terminal = AgentTrace.project(run: "run", node: "node", event: 4, name: "succeeded", data: ["snapshot": ["messages": ["private prompt"]], "status": "succeeded"], secrets: [])
        #expect(terminal.record["data"]?["snapshot"] == nil)
    }
    @Test func nullableFileMetadataStillProducesAnUploadMarker() throws {
        let data = try AgentNodeData(["type": "agent", "version": "2", "title": "Agent", "agent_node_kind": "dify_agent", "agent_binding": ["binding_type": "inline_agent", "agent_id": "agent", "current_snapshot_id": "snap"],
            "agent_declared_outputs": [["name": "artifact", "type": "file", "file": .null]]])
        #expect(data.outputSchema?["properties"]?["artifact"]?["x-dify-sf-file"]?.object != nil)
    }
}

@Suite("Agent review transactions", .enabled(if: testDbHost != nil))
struct AgentReviewStoreTests {
    @Test func invalidFileReceiptsUseFieldPoliciesAndOrdinaryObjectsAreUntouched() async throws {
        try await withServerAndRoutes { api, store, routes in
            let session = try await AgentExecutionStoreTests.seed(api, store)
            for action in ["fail_branch", "default_value", "stop"] {
                var field: JSONObject = ["name": "bundle", "type": "object", "children": [["name": "file", "type": "file"]],
                    "failure_strategy": ["on_failure": .string(action), "default_value": ["file": ["transfer_method": "remote_url", "url": "https://fixture.invalid/a.txt"]]]]
                if action == "default_value" { field["failure_strategy"] = ["on_failure": "default_value", "default_value": ["file": ["approved_fixture_file": true]]] }
                let fields = try AgentDeclaredOutput.parse([.object(field)])
                let candidate: JSONValue = ["bundle": ["file": ["upload_id": "missing", "filename": "a.txt", "mime_type": "text/plain", "size": 1]]]
                let normalized = try await routes.normalizeAgentCandidate(candidate, session: session, files: nil, declarations: fields)
                let result = await AgentOutputPolicy.decide(fields: fields, candidate: normalized, attempt: 0, fileValid: { $0["approved_fixture_file"] == true })
                #expect(result.action == (action == "fail_branch" ? .failBranch : action == "stop" ? .failNode : .succeeded))
            }
            let fields = try AgentDeclaredOutput.parse([["name": "details", "type": "object"]])
            let candidate: JSONValue = ["details": ["upload_id": "an ordinary business property"]]
            let normalized = try await routes.normalizeAgentCandidate(candidate, session: session, files: nil, declarations: fields)
            #expect(normalized == candidate)
            let retry = try AgentDeclaredOutput.parse([["name": "artifact", "type": "file", "failure_strategy": ["retry": ["enabled": true, "max_retries": 1], "on_failure": "stop"]]])
            let bad = try await routes.normalizeAgentCandidate(["artifact": ["upload_id": "missing"]], session: session, files: nil, declarations: retry)
            #expect(await AgentOutputPolicy.decide(fields: retry, candidate: bad, attempt: 0, fileValid: { _ in false }).action == .retry)
        }
    }
    @Test func unrelatedGraphEditsDoNotConflictButTheSameAgentNodeDoes() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            var body = try #require(AgentComposerTests.payload().object)
            body["expected_node"] = ["agent_binding": .null, "agent_task": "Original task", "agent_declared_outputs": []]
            _ = try await registry.sequencer(app).replace(client: "other-graph-edit", cseq: 1) { _, _ in
                (.init(ops: [.addNode(Node(id: "other", type: "start", title: "Other"))], metadata: nil, secrets: [:]), true)
            }
            let saved = try await api.put(AgentComposerTests.path(app), JSONValue.object(body).compactJSON(), token: token)
            #expect(saved.status == 200, "\(saved.text)")
            body["idempotency_key"] = .string(UUID().uuidString.lowercased())
            let stale = try await api.put(AgentComposerTests.path(app), JSONValue.object(body).compactJSON(), token: token)
            #expect(stale.status == 409)
            #expect(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID)?.revision == 1)
        }
    }
}
