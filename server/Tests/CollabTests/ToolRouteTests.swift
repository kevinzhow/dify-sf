import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import PostgresNIO
import Testing
@testable import CollabServer

@Suite("Tool authorization and workflow tools", .enabled(if: testDbHost != nil))
struct ToolRouteTests {
    @Test func encryptedCredentialsRespectPrivateAndSharedVisibility() async throws {
        try await withServerAndRoutes { api, store, routes in
            let owner = try await api.setupOwner()
            let ownerId = try await api.get("/v1/account", token: owner).str("id")
            let member = try await api.member("tools@example.com", role: "editor", inviter: owner)
            let privateID = try await store.saveToolCredential(provider: "fixture/tools/echo", name: "Private", config: #"{"api_key":"fixture-sensitive"}"#, userId: ownerId, shared: false)
            let sharedID = try await store.saveToolCredential(provider: "fixture/tools/echo", name: "Shared", config: #"{"api_key":"fixture-shared"}"#, userId: ownerId, shared: true)
            let path = "/v1/workspaces/current/tool-provider/builtin/fixture/tools/echo/credentials"
            let own = try await api.get(path, token: owner)
            #expect(own.status == 200 && own.j.array?.count == 2)
            #expect(!own.text.contains("fixture-sensitive") && !own.text.contains("fixture-shared"))
            let theirs = try await api.get(path, token: member.token)
            #expect(theirs.status == 200 && theirs.j.array?.count == 1)
            #expect(theirs.j.array?.first?["id"]?.string == sharedID)
            #expect(try await api.get(path).status == 401)
            #expect(try await api.post("/v1/workspaces/current/tool-provider/builtin/fixture/tools/echo/delete", #"{"credential_id":"\#(privateID)"}"#, token: member.token).status == 404)
            do {
                _ = try await routes.toolCredentials(ToolReference(providerID: "fixture/tools/echo", providerType: "builtin", name: "echo", credentialID: privateID), userId: member.id)
                Issue.record("another member's private credential was accepted")
            } catch let error as NodeError { #expect(error.errorTypeName == "ToolProviderCredentialError") }
            let values = try await routes.toolCredentials(ToolReference(providerID: "fixture/tools/echo", providerType: "builtin", name: "echo", credentialID: sharedID), userId: member.id)
            #expect(values["api_key"] == "fixture-shared")
            for try await sealed in try await store.client.query("SELECT encrypted_config FROM tool_provider_credentials").decode(String.self) {
                #expect(!sealed.contains("fixture-sensitive") && !sealed.contains("fixture-shared"))
            }
        }
    }

    static let childYAML = """
    app: {mode: workflow, name: Echo child}
    kind: app
    version: 0.7.0
    workflow:
      environment_variables: []
      conversation_variables: []
      features: {}
      graph:
        nodes:
        - id: start
          data: {type: start, title: Start, variables: [{variable: q, label: Q, type: text-input, required: true}]}
        - id: end
          data: {type: end, title: End, outputs: [{variable: q, value_selector: [start, q]}]}
        edges: [{id: se, source: start, target: end, sourceHandle: source, targetHandle: target}]
    """

    @Test func workflowToolUsesItsPublishedVersionAndPersistsTheNestedTrace() async throws {
        try await withServerAndRoutes { api, store, routes in
            let owner = try await api.setupOwner()
            let ownerId = try await api.get("/v1/account", token: owner).str("id")
            let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(Self.childYAML)]).compactJSON(), token: owner)
            let app = try #require(imported.j["app_id"]?.string)
            #expect(try await api.post("/v1/apps/\(app)/workflows/publish", "{}", token: owner).status == 200)
            let preview = try await api.get("/v1/workspaces/current/tool-provider/workflow/preview?workflow_app_id=\(app)", token: owner)
            #expect(preview.status == 200 && preview.j["parameters"]?.array?.first?["name"] == "q")
            #expect(preview.j["outputs"]?.array?.first?["name"] == "q")
            let saved = try await api.post("/v1/workspaces/current/tool-provider/workflow/create",
                JSONValue.object(["workflow_app_id": .string(app), "name": "echo_child", "label": "Echo child", "description": "Fixture", "parameters": [["name": "q", "description": "Prompt for the child", "form": "form"]]]).compactJSON(), token: owner)
            #expect(saved.status == 200, "\(saved.text)")
            let id = try #require(saved.j["id"]?.string)
            let definition = try #require(try await store.workflowTools().first)
            #expect(try JSONValue.parse(Array(definition.definition.utf8))["parameters"]?.array?.first?["form"] == "form")
            let pinned = definition.versionId
            // Edit and republish the draft. The registered tool must still use the earlier snapshot.
            let client = try await api.post("/v1/docs/\(app)/clients", token: owner).str("client")
            let op: JSONValue = ["client": .string(client), "ops": [["cseq": 1, "base": 0, "op": ["t": "setField", "node": "end", "field": ["k": "config", "path": ["outputs"]],
                "value": [["variable": "changed", "value_selector": ["start", "q"]]]]]]]
            let edit = try await api.post("/v1/docs/\(app)/ops", op.compactJSON(), token: owner)
            #expect(edit.status == 200, "\(edit.text)")
            #expect(try await api.post("/v1/apps/\(app)/workflows/publish", "{}", token: owner).status == 200)
            #expect(try await store.latestVersion(app)?.id != pinned)
            let runtime = ServerToolRuntime(routes: routes, userId: ownerId, plugin: nil, callStack: ["parent"])
            let tool = try ToolNode(id: "tool", data: ["title": "Child", "type": "tool", "provider_type": "workflow", "provider_id": .string(id), "tool_name": "echo_child",
                "tool_configurations": ["q": ["type": "constant", "value": "hello"]]], runtime: runtime)
            let (result, _) = await runNode(tool)
            #expect(result.status == .succeeded, "\(result.error)")
            #expect(result.outputs["q"] == "hello" && result.outputs["changed"] == nil)
            let nested = try #require(result.metadata["workflow_run_id"]?.string)
            let run = try #require(try await store.workflowRun(id: nested))
            #expect(run.status == "succeeded" && run.workflowId == pinned && run.triggeredFrom == "workflow-tool")
            #expect(try await store.nodeExecutions(doc: app, run: nested).count == 2)
            let recursive = ServerToolRuntime(routes: routes, userId: ownerId, plugin: nil, callStack: [app])
            do {
                _ = try await recursive.parameters(ToolReference(providerID: id, providerType: "workflow", name: "echo_child"), context: NodeRunContext(pool: VariablePool()))
                Issue.record("recursive workflow was accepted")
            } catch let error as NodeError { #expect(error.description.contains("recursion")) }
        }
    }
}
