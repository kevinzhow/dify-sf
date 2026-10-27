import Testing
@testable import CollabRuntime

@Suite("Agent inline Soul config")
struct AgentInlineConfigTests {
    static var model: JSONValue {
        ["plugin_id": "langgenius/openai_api_compatible", "model_provider": "openai_api_compatible", "model": "fixture",
         "model_settings": ["temperature": 0.2]]
    }
    @Test func executorProfileIsOnlyANameAndUnknownNamesRemainPortable() throws {
        #expect(try AgentInlineConfig([:]).executorProfile == "default")
        #expect(try AgentInlineConfig(["executor_profile": ""]).executorProfile == "default")
        for name in ["default", "remote-environment", String(repeating: "a", count: 64)] {
            let value: JSONObject = ["executor_profile": .string(name)]
            #expect(try AgentInlineConfig(value).executorProfile == name)
            #expect(try AgentInlineConfig(value).json["executor_profile"] == .string(name))
        }
        for invalid in [.null, 1, true, "UPPER", "bad/name", "bad_name", "bad\n", " space", .string(String(repeating: "a", count: 65))] as [JSONValue] {
            #expect(throws: NodeDataError.self) { try AgentInlineConfig(["executor_profile": invalid]) }
        }
        #expect(throws: NodeDataError.self) { try AgentInlineConfig(["executor_profile": ["image": "arbitrary"]]) }
    }
    @Test func productConfigShapeAndExactModelProviderArePreserved() throws {
        var soul = AgentInlineConfig.empty
        soul["model"] = Self.model
        soul["prompt"] = ["system_prompt": "Use the specification"]
        soul["config_files"] = [["name": "spec.txt", "file_kind": "upload_file", "file_id": "F"]]
        soul["human"] = ["contacts": [["channel": "web_app", "id": "reviewer"]], "tools": []]
        let config = try AgentInlineConfig(soul, requireModel: true)
        #expect(config.provider == "langgenius/openai_api_compatible/openai_api_compatible")
        #expect(config.askHuman && config.files.count == 1)
        #expect(config.json["model"] == Self.model)
        #expect(config.systemPrompt == "Use the specification")
        soul["human"] = ["contacts": [], "tools": []]
        #expect(try AgentInlineConfig(soul).askHuman == false)
    }
    @Test func unsupportedOrMalformedActiveConfigDoesNotSilentlyDisappear() {
        let bad: [JSONObject] = [
            ["unknown": true], ["tools": ["unhandled": true]], ["app_features": ["speech": ["enabled": true]]], ["tools": "shell"], ["tools": ["cli_tools": [["name": "curl"]]]],
            ["knowledge": ["sets": "invalid"]], ["config_skills": ["skill"]],
            ["memory": ["artifacts": [["id": "old"]]]], ["human": ["tools": [["name": "other"]]]],
            ["prompt": ["system_prompt": 3]], ["model": ["model_settings": []]],
        ]
        for json in bad { #expect(throws: NodeDataError.self) { try AgentInlineConfig(json) } }
        #expect(throws: NodeDataError.self) { try AgentInlineConfig(AgentInlineConfig.empty, requireModel: true) }
    }
    @Test func filesCannotEscapeWorkspaceOrHideMissingReferences() {
        for name in ["../escape", "/etc/passwd", "a/b", "a\\b", ".", "..", "bad\nname"] {
            #expect(throws: NodeDataError.self) {
                try AgentInlineConfig(["config_files": [["name": .string(name), "file_kind": "upload_file", "file_id": "F"]]])
            }
        }
        var soul = AgentInlineConfig.empty
        soul["model"] = Self.model
        soul["config_files"] = [["name": "valid", "file_kind": "tool_file", "is_missing": true]]
        #expect(throws: NodeDataError.self) { try AgentInlineConfig(soul, requireModel: true) }
    }
    @Test func sandboxControlEnvironmentAndDuplicateNamesAreRejected() {
        for name in ["HOME", "path", "TMPDIR", "shellctl_token", "HTTPS_PROXY", "no_proxy", "not-a-name"] {
            #expect(throws: NodeDataError.self) {
                try AgentInlineConfig(["env": ["variables": [["name": .string(name), "value": "unsafe"]]]])
            }
        }
        #expect(throws: NodeDataError.self) {
            try AgentInlineConfig(["env": ["variables": [["name": "TOKEN", "value": "plain"]],
                                           "secret_refs": [["name": "TOKEN", "ref": "sealed"]]]])
        }
    }
    @Test func originalCompatibilityUsesEnglishLabelAndDoesNotInventACapabilityGuarantee() {
        #expect(!AgentModelCompatibility.isCompatible(label: "gpt-4.1"))
        #expect(!AgentModelCompatibility.isCompatible(label: "claude-3-7-sonnet"))
        #expect(AgentModelCompatibility.isCompatible(label: "kimi-k3"))
        #expect(AgentModelCompatibility.isCompatible(label: "A workspace-specific model label"))
    }
}
