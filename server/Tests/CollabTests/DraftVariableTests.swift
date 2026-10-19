import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Logging
import Testing
@testable import CollabServer

// Draft variables (protocol 1.14): Dify's DraftVariableSaver rules and the draft variable API.

@Suite("Draft variable rules (Dify's DraftVariableSaver)")
struct DraftVariableRuleTests {
    @Test func nodeOutputsAreSavedExceptExcludedNames() throws {
        let vars = try DraftVariableRules.variables(nodeId: "llm", nodeType: NodeType.llm, executionId: "x1", processData: nil,
                                                    outputs: ["text": "hi", "finish_reason": "stop", "usage": ["total_tokens": 3]])
        #expect(vars.map(\.name) == ["text", "usage"])
        #expect(vars.allSatisfy { $0.visible && $0.editable && $0.nodeExecutionId == "x1" && $0.nodeId == "llm" })
        #expect(vars[0].valueType == .string && vars[1].valueType == .object)
        // If-else outputs go through the plain mapping: visible (only the start mapping hides if-else variables).
        let ifElse = try DraftVariableRules.variables(nodeId: "if", nodeType: NodeType.ifElse, executionId: "x", processData: nil,
                                                      outputs: ["result": true, "selected_case_id": "true"])
        #expect(ifElse.map(\.valueType) == [.boolean, .string] && ifElse.allSatisfy(\.visible))
        // Nothing for nodes inside an iteration or loop (but assigners).
        #expect(try DraftVariableRules.variables(nodeId: "c", nodeType: NodeType.code, executionId: "x", enclosingNodeId: "it", processData: nil,
                                                 outputs: ["a": 1]).isEmpty)
        // Numbers keep integer / float apart; nothing saved for no outputs.
        let code = try DraftVariableRules.variables(nodeId: "c", nodeType: NodeType.code, executionId: "x", processData: nil,
                                                    outputs: ["i": 1, "f": 1.5, "n": .null, "l": [1, 2.5]])
        #expect(code.map(\.valueType) == [.integer, .float, .none, .arrayNumber])
        #expect(try DraftVariableRules.variables(nodeId: "c", nodeType: NodeType.code, executionId: "x", processData: nil, outputs: nil).isEmpty)
    }

    @Test func startNodeMapsPrefixedNames() throws {
        let vars = try DraftVariableRules.variables(
            nodeId: "start", nodeType: NodeType.start, executionId: "x", processData: nil,
            outputs: ["sys.query": "q", "sys.user_id": "u", "sys.files": [], "env.key": "v", "conversation.c": 2, "q": "hello"])
        let byKey = Dictionary(uniqueKeysWithValues: vars.map { ($0.selector.joined(separator: "."), $0) })
        #expect(vars.map { $0.selector.joined(separator: ".") } == ["sys.query", "sys.user_id", "sys.files", "env.key", "conversation.c", "start.q"])
        // sys: query and files editable and visible, the others neither.
        #expect(byKey["sys.query"]!.editable && byKey["sys.query"]!.visible)
        #expect(!byKey["sys.user_id"]!.editable && byKey["sys.user_id"]!.visible)
        #expect(byKey["sys.files"]!.valueType == .arrayFile)
        // env.* is a node variable of node `env` (Dify does the same), not editable.
        #expect(byKey["env.key"]!.variableType == "node" && !byKey["env.key"]!.editable)
        #expect(byKey["conversation.c"]!.nodeExecutionId == nil && byKey["conversation.c"]!.editable)
        #expect(byKey["start.q"]!.editable && byKey["start.q"]!.visible && byKey["start.q"]!.nodeExecutionId == "x")
        // Only system variables: the dummy marks that the node ran.
        let sysOnly = try DraftVariableRules.variables(nodeId: "start", nodeType: NodeType.start, executionId: "x", processData: nil,
                                                       outputs: ["sys.query": "q"])
        #expect(sysOnly.map(\.name) == ["query", DraftVariableRules.dummyName])
        #expect(sysOnly[1].nodeId == "start" && sysOnly[1].valueType == .none && !sysOnly[1].visible && !sysOnly[1].editable)
    }

    @Test func assignerSavesConversationVariablesAndADummy() throws {
        let pd: JSONObject = [DraftVariableRules.updatedVariablesKey: [
            ["name": "count", "selector": ["conversation", "count"], "value_type": "integer", "new_value": 3],
            ["name": "loopvar", "selector": ["loop1", "loopvar"], "value_type": "string", "new_value": "x"],
            ["name": "tags", "selector": ["conversation", "tags"], "value_type": "array[string]", "new_value": []],
        ]]
        let vars = try DraftVariableRules.variables(nodeId: "assign", nodeType: NodeType.variableAssigner, executionId: "x", enclosingNodeId: "loop1",
                                                    processData: pd, outputs: [:])
        #expect(vars.map { $0.selector.joined(separator: ".") } == ["conversation.count", "conversation.tags", "assign.__dummy__"])
        #expect(vars[0].valueType == .integer && vars[0].value == 3 && vars[0].nodeExecutionId == nil)
        #expect(vars[1].valueType == .arrayString)
        #expect(throws: DraftVariableError.self) {
            try DraftVariableRules.variables(nodeId: "a", nodeType: NodeType.variableAssigner, executionId: "x",
                                             processData: [DraftVariableRules.updatedVariablesKey: [["name": "c", "selector": ["conversation"]]]],
                                             outputs: nil)
        }
    }

    @Test func segmentsWithTypeAndTheLoaderSelection() throws {
        #expect(try DraftVariableRules.buildSegment(type: .number, value: 2) == Segment(.integer, 2))
        #expect(try DraftVariableRules.buildSegment(type: .number, value: 2.5) == Segment(.float, 2.5))
        #expect(try DraftVariableRules.buildSegment(type: .arrayObject, value: []) == Segment(.arrayObject, []))
        #expect(try DraftVariableRules.buildSegment(type: .none, value: .null) == .none)
        #expect(throws: DraftVariableError.self) { try DraftVariableRules.buildSegment(type: .integer, value: 2.5) }
        #expect(throws: DraftVariableError.self) { try DraftVariableRules.buildSegment(type: .string, value: .null) }
        #expect(throws: DraftVariableError.self) { try DraftVariableRules.buildSegment(type: .string, value: []) }

        var pool = VariablePool()
        try pool.add(["sys", "query"], "q")
        let mapping: [(key: String, selector: [String])] = [("llm.#start.q#", ["start", "q"]), ("llm.#a.b#", ["a", "b"]),
                                                            ("llm.#sys.query#", ["sys", "query"]), ("llm.#c.d#", ["c", "d"])]
        let toLoad = try DraftVariableRules.selectorsToLoad(mapping: mapping, userInputs: ["#start.q#": "x", "llm.#c.d#": 1], pool: pool)
        #expect(toLoad == [["a", "b"]])
    }
}

private func chatflowYAML() -> String {
    """
    app:
      mode: advanced-chat
      name: draft-vars
    kind: app
    version: 0.3.1
    workflow:
      conversation_variables:
      - id: 11111111-1111-1111-1111-111111111111
        name: count
        value_type: number
        value: 1
        description: a counter
        selector: [conversation, count]
      environment_variables:
      - id: 22222222-2222-2222-2222-222222222222
        name: plain
        value_type: string
        value: hello
        description: ''
        selector: [env, plain]
      - id: 33333333-3333-3333-3333-333333333333
        name: token
        value_type: secret
        value: sk-very-secret-value
        description: ''
        selector: [env, token]
      features: {}
      graph:
        edges:
        - id: start-answer
          source: start
          sourceHandle: source
          target: answer
          targetHandle: target
        nodes:
        - id: start
          data:
            title: Start
            type: start
            variables: []
        - id: answer
          data:
            title: Answer
            type: answer
            answer: '{{#sys.query#}}'
    """
}

private func json(_ v: JSONValue) -> String { v.compactJSON() }

@Suite("Draft variable routes (protocol 1.14)", .enabled(if: testDbHost != nil))
struct DraftVariableRouteTests {
    @Test func savedValuesAreServedEditedResetAndDeletedLikeDify() async throws {
        try await withServer { api, store, registry in
            var logger = Logger(label: "test")
            logger.logLevel = .error
            let routes = try Routes(registry: registry, store: store, config: .defaults, logger: logger)
            let owner = try await api.setupOwner()
            let ownerId = try await api.get("/v1/account", token: owner).str("id")
            let imported = try await api.post("/v1/apps/imports", json(["mode": "yaml-content", "yaml_content": .string(chatflowYAML())]), token: owner)
            let app = imported.str("app_id")
            #expect(!app.isEmpty, "\(imported.text)")
            let base = "/v1/apps/\(app)/workflows/draft"
            let head = try await store.documentHead(app)

            // Nothing yet.
            let empty = try JSONValue.parse(try await api.get("\(base)/variables", token: owner).text)
            #expect(empty == ["items": [], "total": 0])

            // A start node's single run (whole outputs) and an LLM node's run.
            let startExec = "aaaaaaaa-0000-0000-0000-000000000001", llmExec = "aaaaaaaa-0000-0000-0000-000000000002"
            let llmOutputs: JSONObject = ["text": "answer one", "finish_reason": "stop"]
            try await store.insertNodeExecution(StoredNodeExecution(
                id: llmExec, docId: app, workflowRunId: nil, triggeredFrom: "single-step", docSeq: 1, index: 1, predecessorNodeId: nil,
                nodeId: "llm", nodeType: "llm", title: "LLM", inputs: nil, processData: nil, outputs: JSONValue.object(llmOutputs).compactJSON(),
                status: "succeeded", error: nil, elapsedTime: 0.1, executionMetadata: nil, createdBy: ownerId, createdAt: Date(), finishedAt: Date()))
            try await store.insertNodeExecution(StoredNodeExecution(
                id: startExec, docId: app, workflowRunId: nil, triggeredFrom: "single-step", docSeq: 1, index: 1, predecessorNodeId: nil,
                nodeId: "start", nodeType: "start", title: "Start", inputs: nil, processData: nil,
                outputs: JSONValue.object(["sys.query": "first", "sys.user_id": .string(ownerId)]).compactJSON(),
                status: "succeeded", error: nil, elapsedTime: 0.1, executionMetadata: nil, createdBy: ownerId, createdAt: Date(), finishedAt: Date()))
            try await routes.saveDraftVariables(appId: app, userId: ownerId, docSeq: 1, nodeId: "start", nodeType: "start", executionId: startExec,
                                                processData: nil, outputs: ["sys.query": "first", "sys.user_id": .string(ownerId)])
            try await routes.saveDraftVariables(appId: app, userId: ownerId, docSeq: 1, nodeId: "llm", nodeType: "llm", executionId: llmExec,
                                                processData: nil, outputs: llmOutputs)

            // The list: no values, newest first, total on page 1 only.
            let list = try JSONValue.parse(try await api.get("\(base)/variables?page=1&limit=2", token: owner).text)
            #expect(list["total"] == 4, "\(list)")
            let items = list["items"]?.array ?? []
            #expect(items.count == 2 && items[0]["name"] == "text" && items[0]["value"] == nil)
            #expect(items[0].object?.keys == ["id", "type", "name", "description", "selector", "value_type", "edited", "visible", "is_truncated"])
            #expect(try JSONValue.parse(try await api.get("\(base)/variables?page=2&limit=2", token: owner).text)["total"] == .null)
            #expect(try await api.get("\(base)/variables?limit=101", token: owner).status == 400)

            // One node's variables, full shape.
            let node = try JSONValue.parse(try await api.get("\(base)/nodes/llm/variables", token: owner).text)
            let text = node["items"]?.array?.first ?? .null
            #expect(node["items"]?.array?.count == 1 && text["value"] == "answer one" && text["type"] == "node" && text["selector"] == ["llm", "text"])
            #expect(text["value_type"] == "string" && text["edited"] == false && text["full_content"] == .null && text["is_truncated"] == false)
            #expect(try await api.get("\(base)/nodes/sys/variables", token: owner).errorCode == "invalid_param")
            let start = try JSONValue.parse(try await api.get("\(base)/nodes/start/variables", token: owner).text)
            #expect(start["items"]?.array?.map { $0["name"] } == ["__dummy__"])

            // System variables.
            let sys = try JSONValue.parse(try await api.get("\(base)/system-variables", token: owner).text)
            let sysByName = Dictionary(uniqueKeysWithValues: (sys["items"]?.array ?? []).map { ($0["name"]?.string ?? "", $0) })
            #expect(sysByName["query"]?["type"] == "sys" && sysByName["query"]?["visible"] == true)
            #expect(sysByName["user_id"]?["visible"] == true)  // Dify's new_sys_variable: always visible, not editable

            // Conversation variables: the draft's defaults, filled in once.
            let conv = try JSONValue.parse(try await api.get("\(base)/conversation-variables", token: owner).text)
            let count = conv["items"]?.array?.first ?? .null
            #expect(conv["items"]?.array?.count == 1 && count["name"] == "count" && count["value"] == 1 && count["value_type"] == "number")
            #expect(count["description"] == "a counter" && count["type"] == "conversation")
            let countId = count["id"]?.string ?? ""

            // Environment variables: from the document, secrets masked.
            let env = try JSONValue.parse(try await api.get("\(base)/environment-variables", token: owner).text)
            let envItems = env["items"]?.array ?? []
            #expect(envItems.count == 2 && envItems.allSatisfy { $0["type"] == "env" && $0["editable"] == true && $0["edited"] == false })
            let token = envItems.first { $0["name"] == "token" }
            #expect(token?["value"]?.string?.contains("very-secret") == false && token?["value_type"] == "secret")
            #expect(token?["selector"] == ["env", "token"])

            // Edit a node variable: value then name; edited.
            let textId = text["id"]?.string ?? ""
            let patched = try await api.patch("\(base)/variables/\(textId)", #"{"value":"edited"}"#, token: owner)
            let p = try JSONValue.parse(patched.text)
            #expect(patched.status == 200 && p["value"] == "edited" && p["edited"] == true, "\(patched.text)")
            #expect(try await api.patch("\(base)/variables/\(textId)", #"{"value":3}"#, token: owner).errorCode == "invalid_param")
            #expect(try await api.patch("\(base)/variables/\(textId)", #"{}"#, token: owner).status == 200)
            // A variable that cannot be edited.
            let userIdVar = sysByName["user_id"]?["id"]?.string ?? ""
            #expect(try await api.patch("\(base)/variables/\(userIdVar)", #"{"value":"x"}"#, token: owner).errorCode == "invalid_param")
            #expect(try await api.put("\(base)/variables/\(userIdVar)/reset", token: owner).errorCode == "invalid_param")

            // Reset: the node execution's output again; a conversation variable its default.
            let reset = try JSONValue.parse(try await api.put("\(base)/variables/\(textId)/reset", token: owner).text)
            #expect(reset["value"] == "answer one" && reset["edited"] == false, "\(reset)")
            #expect(try JSONValue.parse(try await api.patch("\(base)/variables/\(countId)", #"{"value":5}"#, token: owner).text)["value"] == 5)
            let countReset = try JSONValue.parse(try await api.put("\(base)/variables/\(countId)/reset", token: owner).text)
            #expect(countReset["value"] == 1 && countReset["edited"] == false)
            // The system query resets from the start execution's `sys.query`.
            let queryId = sysByName["query"]?["id"]?.string ?? ""
            _ = try await api.patch("\(base)/variables/\(queryId)", #"{"value":"changed"}"#, token: owner)
            #expect(try JSONValue.parse(try await api.put("\(base)/variables/\(queryId)/reset", token: owner).text)["value"] == "first")

            // The loader gives typed segments.
            let loaded = try await routes.loadDraftVariables(appId: app, userId: ownerId, selectors: [["llm", "text"], ["conversation", "count"],
                                                                                                       ["nope", "x"]])
            #expect(Set(loaded.map { $0.selector }) == [["llm", "text"], ["conversation", "count"]])
            #expect(loaded.first { $0.selector == ["conversation", "count"] }?.segment == Segment(.integer, 1))

            // Another account sees none of them; the ids are not theirs.
            let editor = try await api.member("e@example.com", role: "editor", inviter: owner)
            #expect(try await api.get("\(base)/variables/\(textId)", token: editor.token).status == 404)
            #expect(try JSONValue.parse(try await api.get("\(base)/variables", token: editor.token).text)["total"] == 0)
            let normal = try await api.member("n@example.com", role: "normal", inviter: owner)
            #expect(try await api.get("\(base)/variables", token: normal.token).status == 403)
            #expect(try await api.get("\(base)/variables").status == 401)
            #expect(try await api.get("\(base)/variables/not-a-uuid", token: owner).status == 404)

            // Deletes: one, one node's, all.
            #expect(try await api.delete("\(base)/variables/\(textId)", token: owner).status == 204)
            #expect(try await api.get("\(base)/variables/\(textId)", token: owner).status == 404)
            #expect(try await api.delete("\(base)/nodes/start/variables", token: owner).status == 204)
            #expect(try JSONValue.parse(try await api.get("\(base)/nodes/start/variables", token: owner).text)["items"] == [])
            #expect(try await api.delete("\(base)/variables", token: owner).status == 204)
            #expect(try JSONValue.parse(try await api.get("\(base)/variables", token: owner).text)["total"] == 0)

            // Draft variables are never ops.
            #expect(try await store.documentHead(app) == head)
        }
    }
}
