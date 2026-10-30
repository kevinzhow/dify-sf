import Testing
@testable import CollabRuntime

@Suite("Workflow Agent model inputs")
struct AgentModelInputsTests {
    struct UnusedRuntime: AgentRuntime {
        func prepare(nodeID: String, data: AgentNodeData) async throws {}
        func run(nodeID: String, data: AgentNodeData, context: NodeRunContext) async throws -> AgentNodeDecision { .pause(formID: "unused") }
    }

    @Test func singleNodeRunsRequestModelVariablesAndDeduplicatePromptReferences() throws {
        let data = try AgentNodeData(["type": "agent", "version": "2", "agent_node_kind": "dify_agent",
            "agent_binding": ["binding_type": "inline_agent", "agent_id": "agent", "current_snapshot_id": "snapshot"],
            "agent_task": "Use {{#start.model#}}", "agent_model": ["model": "{{#start.model#}}", "reasoning_effort": "{{#start.effort#}}"]])
        let node = AgentV2Node(id: "agent", data: data, runtime: UnusedRuntime())
        let mapping = node.variableMapping(graph: try GraphConfig(json: ["nodes": [], "edges": []]))
        #expect(mapping.count == 2)
        #expect(Set(mapping.map(\.selector)) == Set([["start", "model"], ["start", "effort"]]))
    }

    static func config() throws -> AgentInlineConfig {
        try AgentInlineConfig(["harness_style": "codex", "model": ["plugin_id": "vendor/plugin", "model_provider": "provider",
            "model": "model-a", "credential_ref": ["type": "model", "id": "model-a-credential"],
            "model_settings": ["reasoning_effort": "max", "max_tokens": 4096]]], requireModel: true)
    }

    @Test func resolvesBothInputsWithoutChangingProviderOrOtherParameters() throws {
        var pool = VariablePool()
        try pool.add(["start-node", "model"], "model-b")
        try pool.add(["start-node", "effort"], "high")
        let bindings = try AgentModelInputs(["model": "{{#start-node.model#}}", "reasoning_effort": "{{#start-node.effort#}}"])
        let resolved = try bindings.resolve(Self.config(), pool: pool)
        #expect(resolved.model == "model-b")
        #expect(resolved.provider == "vendor/plugin/provider")
        #expect(resolved.modelParameters == ["reasoning_effort": "high", "max_tokens": 4096])
        #expect(resolved.json["model"]?["credential_ref"] == nil)
        #expect(Set(bindings.selectors) == Set([["start-node", "model"], ["start-node", "effort"]]))
        #expect(try Self.config().model == "model-a")
    }

    @Test func fixedSelectionAndModelCredentialStayCompatible() throws {
        let original = try Self.config()
        #expect(try AgentModelInputs(nil).resolve(original, pool: VariablePool()).json == original.json)
        var pool = VariablePool(); try pool.add(["start", "effort"], "xhigh")
        let resolved = try AgentModelInputs(["reasoning_effort": "{{#start.effort#}}"])
            .resolve(original, pool: pool)
        #expect(resolved.model == "model-a")
        #expect(resolved.json["model"]?["credential_ref"] == original.json["model"]?["credential_ref"])
    }

    @Test func missingWrongTypeEmptyAndSecretValuesFailBeforeModelInvocation() throws {
        let input = try AgentModelInputs(["reasoning_effort": "{{#start.effort#}}"])
        #expect(throws: NodeError.self) { try input.resolve(Self.config(), pool: VariablePool()) }
        for segment in [Segment(.integer, 3), Segment(.string, ""), Segment(.string, "   "), Segment(.secret, "high")] {
            var pool = VariablePool(); try pool.add(["start", "effort"], segment)
            #expect(throws: NodeError.self) { try input.resolve(Self.config(), pool: pool) }
        }
        var pool = VariablePool(); try pool.add(["start", "effort"], "unsupported")
        #expect(throws: NodeDataError.self) { try input.resolve(Self.config(), pool: pool) }
    }

    @Test func resumedExecutionUsesPinnedValuesEvenWhenVariablesAreMissingOrChanged() throws {
        var pool = VariablePool(); try pool.add(["start", "model"], "model-b"); try pool.add(["start", "effort"], "high")
        let input = try AgentModelInputs(["model": "{{#start.model#}}", "reasoning_effort": "{{#start.effort#}}"])
        let first = try input.resolve(Self.config(), pool: pool)
        let pinned = first.json["model"]!.object!
        #expect(try input.resolve(Self.config(), pool: VariablePool(), pinned: pinned).json == first.json)
        try pool.add(["start", "model"], "model-c"); try pool.add(["start", "effort"], "max")
        #expect(try input.resolve(Self.config(), pool: pool, pinned: pinned).json == first.json)
    }

    @Test func rejectsPartialReferencesAndUnknownOverrideFields() {
        for value in [1, ["provider": "{{#start.provider#}}"], ["model": ""], ["model": "prefix {{#start.model#}}"],
                      ["reasoning_effort": "{{#start.#}}"], ["reasoning_effort": "{{#start.effort#}}suffix"],
                      ["reasoning_effort": ["start", "effort"]],
                      ["selection": "{{#start.choice#}}", "model": "{{#start.model#}}"]] as [JSONValue] {
            #expect(throws: NodeDataError.self) { try AgentModelInputs(value) }
        }
    }

    @Test(arguments: ["provider", "provider_credential", "model", "model_credential"])
    func oneSelectionSwitchesProviderAndClearsForeignCredentialsAndSettings(credentialType: String) throws {
        var original = try Self.config().json
        var selection = original["model"]!.object!
        selection["credential_ref"] = ["type": .string(credentialType), "id": "old-secret", "provider": "vendor/plugin/provider"]
        original["model"] = .object(selection)
        var pool = VariablePool()
        try pool.add(["start", "choice"], "langgenius/deepseek/deepseek::deepseek-flash")
        try pool.add(["start", "effort"], "high")
        let input = try AgentModelInputs(["selection": "{{#start.choice#}}", "reasoning_effort": "{{#start.effort#}}"])
        let selected = try input.resolve(AgentInlineConfig(original), pool: pool)
        #expect(selected.provider == "langgenius/deepseek/deepseek" && selected.model == "deepseek-flash")
        #expect(selected.modelParameters == ["reasoning_effort": "high"])
        #expect(selected.json["model"]?["credential_ref"] == nil)
        #expect(input.selectsProvider && input.selectors.count == 2)
        // Resume/retry must not resolve a changed or missing input into a different provider.
        let pinned = selected.json["model"]!.object!
        try pool.add(["start", "choice"], "langgenius/openai/openai::other")
        #expect(try input.resolve(Self.config(), pool: pool, pinned: pinned).json == selected.json)
        #expect(try input.resolve(Self.config(), pool: VariablePool(), pinned: pinned).json == selected.json)
    }

    @Test func fullSelectionKeepsUnchangedDefaultsAndAllowsSlashesInsideTheModelName() throws {
        let original = try Self.config()
        let input = try AgentModelInputs(["selection": "{{#start.choice#}}"])
        var pool = VariablePool(); try pool.add(["start", "choice"], "vendor/plugin/provider::model-a")
        #expect(try input.resolve(original, pool: pool).json == original.json)
        try pool.add(["start", "choice"], "vendor/plugin/provider::org/model::revision")
        let selected = try input.resolve(original, pool: pool)
        #expect(selected.model == "org/model::revision" && selected.modelParameters.isEmpty)
        #expect(selected.json["model"]?["credential_ref"] == nil)
    }

    @Test func invalidFullSelectionsAndSecretVariablesNeverBecomeConnections() throws {
        let input = try AgentModelInputs(["selection": "{{#start.choice#}}"])
        for text in ["model-only", "::model", "vendor/plugin/provider::", "vendor/plugin::model", "vendor/plugin/provider/extra::model",
                     "https://example.com::model", "vendor/plugin/provider::   "] {
            var pool = VariablePool(); try pool.add(["start", "choice"], text)
            #expect(throws: NodeError.self) { try input.resolve(Self.config(), pool: pool) }
        }
        var pool = VariablePool(); try pool.add(["start", "choice"], Segment(.secret, "vendor/plugin/provider::model"))
        #expect(throws: NodeError.self) { try input.resolve(Self.config(), pool: pool) }
    }
}
