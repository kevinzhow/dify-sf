import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Portable inline Agent packages", .enabled(if: testDbHost != nil))
struct AgentPackageTests {
    @Test func exportsAndAppCopiesMaterializePrivateBindingsWithoutSecretsOrFileLocators() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            var soul = AgentInlineConfig.empty
            soul["executor_profile"] = "imported-unknown-environment"
            soul["model"] = ["plugin_id": "fixture/plugin", "model_provider": "provider", "model": "fixture-model", "credential_ref": ["type": "model", "id": "private-credential"]]
            soul["env"] = ["variables": [["name": "PLAIN", "value": "portable"]], "secret_refs": [["name": "TOKEN", "value": "must-not-export-private-secret"]]]
            soul["config_files"] = [["name": "notes.txt", "file_kind": "upload_file", "file_id": "private-file-locator"]]
            soul["human"] = ["contacts": [["id": "source-contact", "name": "Operator", "method": "web_app"]], "tools": []]
            var body = try #require(AgentComposerTests.payload(soul: soul).object)
            body["node_job"] = ["workflow_prompt": "Portable task", "declared_outputs": [["name": "artifact", "type": "file",
                "failure_strategy": ["on_failure": "default_value", "default_value": ["transfer_method": "tool_file", "reference": "dify-file-ref:eyJyZWNvcmRfaWQiOiJzb3VyY2UtZmlsZSJ9"]]]],
                "metadata": ["file_refs": [["file_id": "source-task-file"]]]]
            let saved = try await api.put(AgentComposerTests.path(app), JSONValue.object(body).compactJSON(), token: token)
            #expect(saved.status == 200, "\(saved.text)")
            let original = try #require(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID))
            let response = try await api.get("/v1/docs/\(app)/export?format=json&include_secret=true", token: token)
            #expect(response.status == 200, "\(response.text)")
            for privateValue in ["private-credential", "must-not-export-private-secret", "private-file-locator", "source-contact", "source-task-file", "dify-file-ref:eyJyZWNvcmRfaWQiOiJzb3VyY2UtZmlsZSJ9", original.agentId, original.id] {
                #expect(!response.text.contains(privateValue), "Portable Agent export must omit workspace/private locators")
            }
            let projected = try JSONValue.parse(response.text)
            #expect(projected["agent_packages"]?["agent_1"]?["schema_version"] == 1)
            let packageSoul = projected["agent_packages"]?["agent_1"]?["soul"]
            #expect(packageSoul?["executor_profile"] == "imported-unknown-environment")
            #expect(packageSoul?["config_files"]?.array?.first?["is_missing"] == true)
            #expect(packageSoul?["env"]?["secret_refs"]?.array?.first?["name"] == "TOKEN")
            #expect(packageSoul?["env"]?["variables"]?.array?.first?["value"] == "portable")
            let imported = try await api.post("/v1/docs/import", response.text, token: token)
            #expect(imported.status == 201, "\(imported.text)")
            let copied = imported.str("id")
            let config = try #require(try await store.currentAgentConfig(doc: copied, node: AgentComposerTests.nodeID))
            #expect(try JSONValue.parse(config.soul)["executor_profile"] == "imported-unknown-environment")
            #expect(config.agentId != original.agentId && config.id != original.id && config.docId == copied)
            let doc = try await registry.sequencer(copied).currentSnapshot().doc
            let graphBinding = try JSONValue.parse(try WireJSON.encode(doc.nodes[AgentComposerTests.nodeID]?.config["agent_binding"]))
            #expect(graphBinding["agent_id"] == .string(config.agentId))
            let metadata = try await store.documentMetadata(copied)
            let publicMetadata = try JSONValue.parse(try WireJSON.encode(metadata))
            #expect(publicMetadata["agent_packages"] == nil, "Private Soul must not be copied into shared metadata")
            #expect(try await store.secrets(copied).isEmpty)
            let console = try await api.get(AgentComposerTests.path(copied), token: token)
            #expect(console.status == 200 && console.text.contains("notes.txt"))
            #expect(!console.text.contains("must-not-export-private-secret"))
            let loaded = try JSONValue.parse(console.text)
            #expect(loaded["node_job"]?["metadata"]?["file_refs"]?.array?.first?["is_missing"] == true)
            #expect(loaded["node_job"]?["declared_outputs"]?.array?.first?["failure_strategy"]?["default_value"] == Routes.omittedAgentFile)
            let editPayload = AgentComposerTests.payload(head: 0, soul: loaded["agent_soul"]?.object)
            var edit = try #require(editPayload.object)
            edit["node_job"] = loaded["node_job"]
            let editedCopy = try await api.put(AgentComposerTests.path(copied), JSONValue.object(edit).compactJSON(), token: token)
            #expect(editedCopy.status == 200, "Unconfigured imported secrets remain editable without borrowing a source reference: \(editedCopy.text)")
            #expect(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID)?.revision == 1)
            #expect(try await store.currentAgentConfig(doc: copied, node: AgentComposerTests.nodeID)?.revision == 2)
        }
    }

    @Test func invalidPackageImportRollsBackTheWholeGraphAndDoesNotBorrowOtherNodesPrivateIds() async throws {
        try await withServer { api, store, registry in
            let (token, _, app) = try await AgentComposerTests.seed(api, store)
            let saved = try await api.put(AgentComposerTests.path(app), AgentComposerTests.payload().compactJSON(), token: token)
            #expect(saved.status == 200)
            let old = try await registry.sequencer(app).currentSnapshot()
            let exported = try await api.get("/v1/docs/\(app)/export?format=json", token: token)
            var raw = try #require(try JSONValue.parse(exported.text).object)
            raw["agent_packages"] = nil
            let rawImport = try await api.post("/v1/docs/import", JSONValue.object(raw).compactJSON(), token: token)
            #expect(rawImport.status == 400)
            var malformed = try #require(try JSONValue.parse(exported.text).object)
            var packages = try #require(malformed["agent_packages"]?.object)
            var package = try #require(packages["agent_1"]?.object)
            var soul = try #require(package["soul"]?.object)
            soul["config_files"] = "wrong type"
            package["soul"] = .object(soul); packages["agent_1"] = .object(package); malformed["agent_packages"] = .object(packages)
            let rejected = try await api.post("/v1/docs/\(app)/replace?client=agent-package-test&cseq=1&confirm=true", JSONValue.object(malformed).compactJSON(), token: token)
            #expect(rejected.status == 400, "\(rejected.text)")
            let after = try await registry.sequencer(app).currentSnapshot()
            #expect(after.seq == old.seq && after.doc == old.doc)
            #expect(try await store.currentAgentConfig(doc: app, node: AgentComposerTests.nodeID)?.revision == 1)
        }
    }
    @Test func aFailedPrivateResourceWriteRollsBackANewDocumentToo() async throws {
        try await withServer { api, store, registry in
            let (token, user, source) = try await AgentComposerTests.seed(api, store)
            _ = try await api.put(AgentComposerTests.path(source), AgentComposerTests.payload().compactJSON(), token: token)
            let doc = try await registry.sequencer(source).currentSnapshot().doc
            var config = try #require(try await store.currentAgentConfig(doc: source, node: AgentComposerTests.nodeID))
            let target = UUID().uuidString.lowercased()
            config.docId = target; config.id = UUID().uuidString.lowercased(); config.agentId = UUID().uuidString.lowercased(); config.bindingId = UUID().uuidString.lowercased()
            let receipt = AgentComposerReceipt(requestID: UUID().uuidString.lowercased(), userID: user + "-wrong", nodeID: AgentComposerTests.nodeID, digest: "invalid", response: "{}")
            do {
                _ = try await store.createDocument(id: target, initial: doc, metadata: .map([:]), secrets: ["fixture-secret": "must roll back"],
                    agentConfigs: [.init(snapshot: config, expectedSnapshotId: nil, receipt: receipt)])
                Issue.record("Document and private Agent resources must roll back together")
            } catch { }
            #expect(try await store.load(target) == nil)
            #expect(try await store.currentAgentConfig(doc: target, node: AgentComposerTests.nodeID) == nil)
            #expect(try await store.secrets(target).isEmpty)
        }
    }

}
