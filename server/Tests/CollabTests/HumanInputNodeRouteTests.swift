import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
import Vapor
import VaporTesting
@testable import CollabServer

/// A human-input node's own form in the console (protocol 1.16, Dify's
/// `/apps/{app}/workflows/draft/human-input/nodes/{node}/form/{preview,run}`): the panel's "run this step" renders the
/// form the node would show, and its answers become the node's draft variables without a run.
@Suite("Human input node form", .enabled(if: testDbHost != nil))
struct HumanInputNodeRouteTests {
    /// start (`q`) → human (`form_content` reads the start value and its own `reply`) → end. The reply's default is the
    /// start value too, so the preview's `resolved_default_values` has something to resolve.
    static func yaml() -> String {
        """
        app:
          mode: workflow
          name: hitl-node
        kind: app
        version: 0.3.1
        workflow:
          conversation_variables: []
          environment_variables: []
          features: {}
          graph:
            edges:
            - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
            - {id: e2, source: human, sourceHandle: approve, target: end, targetHandle: target}
            nodes:
            - id: start
              data:
                title: Start
                type: start
                variables:
                - {variable: q, label: Question, type: text-input, required: true}
            - id: human
              data:
                title: Approve the request
                type: human-input
                form_content: 'Please approve {{#$output.reply#}} (question: {{#start.q#}})'
                inputs:
                - type: paragraph
                  output_variable_name: reply
                  default: {type: variable, selector: [start, q]}
                - type: select
                  output_variable_name: level
                  option_source: {type: constant, value: [low, high]}
                user_actions:
                - {id: approve, title: Approve it, button_style: primary}
                - {id: reject, title: Reject it, button_style: default}
            - id: end
              data:
                title: End
                type: end
                outputs: []
        """
    }

    static func path(_ appId: String, _ tail: String, nodeId: String = "human") -> String {
        "/v1/apps/\(appId)/workflows/draft/human-input/nodes/\(nodeId)/form/\(tail)"
    }

    static func chatPath(_ appId: String, _ tail: String) -> String {
        "/v1/apps/\(appId)/advanced-chat/workflows/draft/human-input/nodes/human/form/\(tail)"
    }

    static func importApp(_ api: API, _ token: String, yaml: String = yaml()) async throws -> String {
        let a = try await api.post("/v1/docs/import", yaml, token: token)
        #expect(a.status == 201, "import: \(a.text)")
        #expect(!a.str("id").isEmpty)
        return a.str("id")
    }

    @Test func systemFeaturesAnnounceTheHumanInputRuntime() async throws {
        // The runtime section exists only with a model runtime configured (as in RuntimeRouteTests).
        try await withFakeDaemon { daemon, _ in
            try await withHumanInputServer(config: runtimeConfig(daemon: daemon)) { api, _, _ in
                let runtime = try JSONValue.parse(try await api.get("/v1/system-features").text)["workflow_runtime"]
                #expect(runtime?["protocol_version"] == "1.21")
                #expect(runtime?["human_input"] == true)
                // Human input runs inside a draft run; its own form endpoints replace a plain single node run.
                #expect(runtime?["draft_run"]?.array?.contains("human-input") == true)
                #expect(runtime?["single_node_run"]?.array?.contains("human-input") == false)
            }
        }
    }

    @Test func thePreviewRendersTheNodesFormWithTheValuesItReads() async throws {
        try await withHumanInputServer { api, _, _ in
            let owner = try await api.setupOwner()
            let app = try await Self.importApp(api, owner)
            let preview = try await api.post(Self.path(app, "preview"), ##"{"inputs":{"#start.q#":"why not?"}}"##, token: owner)
            #expect(preview.status == 200, "preview: \(preview.text)")
            #expect(preview.str("node_id") == "human")
            #expect(preview.str("form_id") == "human")
            #expect(preview.str("node_title") == "Approve the request")
            // The runtime reference is rendered, the node's own field stays a placeholder.
            #expect(preview.str("form_content") == "Please approve {{#$output.reply#}} (question: why not?)")
            #expect(preview.list("inputs").count == 2)
            #expect(preview.list("actions").count == 2)
            #expect(preview.obj("resolved_default_values")["reply"] == .string("why not?"))
            #expect(preview.json["display_in_ui"] == .null)
            #expect(preview.json["form_token"] == .null)
        }
    }

    @Test func aValueOutsideASelectsOptionsIsRefusedAndNothingIsSaved() async throws {
        try await withHumanInputServer { api, _, _ in
            let owner = try await api.setupOwner()
            let app = try await Self.importApp(api, owner)
            let bad = try await api.post(Self.path(app, "run"),
                                         ##"{"inputs":{"#start.q#":"why not?"},"form_inputs":{"reply":"ok","level":"sideways"},"action":"approve"}"##,
                                         token: owner)
            #expect(bad.status == 400, "bad select: \(bad.text)")
            #expect(bad.errorCode == "invalid_form_data")
            // An action the node does not offer is refused too.
            let unknownAction = try await api.post(Self.path(app, "run"),
                                                   ##"{"inputs":{"#start.q#":"why not?"},"form_inputs":{"reply":"ok"},"action":"shrug"}"##,
                                                   token: owner)
            #expect(unknownAction.status == 400, "unknown action: \(unknownAction.text)")
            // Nothing was answered, so the node has no draft variables.
            let vars = try await api.get("/v1/apps/\(app)/workflows/draft/nodes/human/variables", token: owner)
            #expect(vars.list("items").isEmpty, "variables: \(vars.text)")
        }
    }

    @Test func theSubmissionReturnsTheAnswersAndSavesThemAsDraftVariables() async throws {
        try await withHumanInputServer { api, _, _ in
            let owner = try await api.setupOwner()
            let app = try await Self.importApp(api, owner)
            let run = try await api.post(Self.path(app, "run"),
                                         ##"{"inputs":{"#start.q#":"why not?"},"form_inputs":{"reply":"yes, go","level":"high"},"action":"approve"}"##,
                                         token: owner)
            #expect(run.status == 200, "run: \(run.text)")
            #expect(run.str("reply") == "yes, go")
            #expect(run.str("__action_id") == "approve")
            #expect(run.str("__action_value") == "Approve it")
            // `render_form_content_with_outputs`: the node's own fields are filled, runtime references stay.
            // The node's own field is filled; the start reference stays a placeholder (`render_form_content_with_outputs`
            // only replaces the node's `$output` fields).
            #expect(run.str("__rendered_content").contains("Please approve yes, go"), "\(run.str("__rendered_content"))")

            // The answers are the node's draft variables: the variable inspect panel shows them.
            let vars = try await api.get("/v1/apps/\(app)/workflows/draft/nodes/human/variables", token: owner)
            #expect(vars.status == 200, "variables: \(vars.text)")
            let byName = Dictionary(uniqueKeysWithValues: vars.list("items").compactMap { item -> (String, Value)? in
                guard let name = string(item.key("name")) else { return nil }
                return (name, item.key("value") ?? .null)
            })
            #expect(byName["reply"] == .string("yes, go"))
            #expect(byName["__action_id"] == .string("approve"))
        }
    }

    @Test func theNodeMustBeAHumanInputNodeAndTheAppTheRoutesMode() async throws {
        try await withHumanInputServer { api, _, _ in
            let owner = try await api.setupOwner()
            let app = try await Self.importApp(api, owner)
            let wrongNode = try await api.post(Self.path(app, "preview", nodeId: "start"), ##"{"inputs":{}}"##, token: owner)
            #expect(wrongNode.status == 400, "wrong node: \(wrongNode.text)")
            #expect(wrongNode.errorCode == "bad_request")
            // A workflow app has no advanced-chat human-input form route.
            // A workflow app has no advanced-chat human-input form route: Dify's `get_app_model(mode=[ADVANCED_CHAT])`
            // raises `AppNotFoundError`, a 404.
            let wrongMode = try await api.post(Self.chatPath(app, "preview"), ##"{"inputs":{}}"##, token: owner)
            #expect(wrongMode.status == 404, "wrong mode: \(wrongMode.text)")
            #expect(wrongMode.errorCode == "app_not_found")
            let missingNode = try await api.post(Self.path(app, "preview", nodeId: "nope"), ##"{"inputs":{}}"##, token: owner)
            #expect(missingNode.status == 404, "missing node: \(missingNode.text)")
        }
    }

    @Test func anEditorRunsItAndAMemberDoesNot() async throws {
        try await withHumanInputServer { api, _, _ in
            let owner = try await api.setupOwner()
            let app = try await Self.importApp(api, owner)
            let editor = try await api.member("ed@example.com", role: "editor", name: "Ed", inviter: owner)
            let viewer = try await api.member("vi@example.com", role: "normal", name: "Vi", inviter: owner)
            let byEditor = try await api.post(Self.path(app, "preview"), ##"{"inputs":{"#start.q#":"hi"}}"##, token: editor.token)
            #expect(byEditor.status == 200, "editor: \(byEditor.text)")
            let byViewer = try await api.post(Self.path(app, "preview"), ##"{"inputs":{"#start.q#":"hi"}}"##, token: viewer.token)
            #expect(byViewer.status == 403, "viewer: \(byViewer.text)")
        }
    }
}

private func string(_ v: Value?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private func strings(_ v: Value?) -> [String] {
    if case .list(let xs)? = v { return xs.compactMap { string($0) } }
    return []
}

private extension Value {
    func key(_ k: String) -> Value? {
        guard case .map(let m) = self else { return nil }
        return m[k]
    }
}
