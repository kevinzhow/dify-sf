import Testing
@testable import CollabRuntime

@Suite("Agent declared output policy")
struct AgentOutputPolicyTests {
    func field(_ name: String, type: String = "number", required: Bool = true, retries: Int = 0,
               failure: String = "stop", fallback: JSONValue = .null, itemType: String? = nil) throws -> AgentDeclaredOutput {
        var value: JSONObject = ["name": .string(name), "type": .string(type), "required": .bool(required),
            "failure_strategy": ["retry": ["enabled": .bool(retries > 0), "max_retries": .int(retries)],
                                 "on_failure": .string(failure), "default_value": fallback]]
        if let itemType { value["array_item"] = ["type": .string(itemType)] }
        return try AgentDeclaredOutput(value)
    }

    @Test func disabledRetryUsesDefaultWithoutLosingOtherFields() async throws {
        let fields = try [field("score", failure: "default_value", fallback: 0), field("label", type: "string")]
        let outcome = await AgentOutputPolicy.decide(fields: fields, candidate: ["text": "done", "score": "bad", "label": "kept"],
                                                     attempt: 0, fileValid: { _ in false })
        #expect(outcome.action == .succeeded && outcome.nextAttempt == 0)
        #expect(outcome.outputs == ["text": "done", "score": 0, "label": "kept"])
        #expect(outcome.checks.first?.status == .failed)
    }

    @Test func retryBudgetIsMaximumOfFailedFieldsBeforeTerminalStrategyPrecedence() async throws {
        let fields = try [field("a", retries: 1, failure: "stop"), field("b", retries: 2, failure: "fail_branch"),
                          field("c", failure: "default_value", fallback: 8)]
        let candidate: JSONValue = ["a": "wrong", "b": false, "c": []]
        for attempt in [0, 1] {
            let retry = await AgentOutputPolicy.decide(fields: fields, candidate: candidate, attempt: attempt, fileValid: { _ in true })
            #expect(retry.action == .retry && retry.nextAttempt == attempt + 1)
            #expect(retry.feedback.count == 3)
        }
        let exhausted = await AgentOutputPolicy.decide(fields: fields, candidate: candidate, attempt: 2, fileValid: { _ in true })
        #expect(exhausted.action == .failBranch)
    }

    @Test func successfulFieldsDoNotSpendTheirConfiguredRetryBudgets() async throws {
        let fields = try [field("valid", retries: 10), field("bad", failure: "default_value", fallback: 7)]
        let result = await AgentOutputPolicy.decide(fields: fields, candidate: ["valid": 1, "bad": "bad"], attempt: 0, fileValid: { _ in false })
        #expect(result.action == .succeeded && result.outputs["bad"] == 7)
    }

    @Test func optionalMissingIsDistinctFromInvalidNullAndBooleanIsNotNumber() async throws {
        let fields = try [field("optional", type: "string", required: false), field("number", failure: "default_value", fallback: 2)]
        let result = await AgentOutputPolicy.decide(fields: fields, candidate: ["number": true], attempt: 0, fileValid: { _ in false })
        #expect(result.action == .succeeded && result.checks[0].status == .notProduced)
        #expect(result.outputs["optional"] == nil && result.outputs["number"] == 2)
        let null = await AgentOutputPolicy.decide(fields: [fields[0]], candidate: ["optional": .null], attempt: 0, fileValid: { _ in false })
        #expect(null.action == .failNode)
    }

    @Test func fileAndDefaultFileMustPassTheSameOwnershipCheck() async throws {
        let foreign: JSONValue = ["reference": "dify-file-ref:eyJyZWNvcmRfaWQiOiJmb3JlaWduIn0=", "transfer_method": "tool_file"]
        let fields = try [field("file", type: "file", failure: "default_value", fallback: foreign)]
        let rejected = await AgentOutputPolicy.decide(fields: fields, candidate: ["file": foreign], attempt: 0,
                                                      fileValid: { $0["related_id"] == "owned" })
        #expect(rejected.action == .failNode)
        let accepted = await AgentOutputPolicy.decide(fields: fields,
            candidate: ["file": ["related_id": "owned", "transfer_method": "tool_file"]], attempt: 0,
            fileValid: { $0["related_id"] == "owned" })
        #expect(accepted.action == .succeeded)
    }

    @Test func defaultShapesAreValidatedBeforeAnyAgentOrModelRuns() throws {
        for (type, value) in [("number", JSONValue.bool(true)), ("string", JSONValue.int(2)),
                              ("file", ["transfer_method": "tool_file", "upload_file_id": "foreign"]),
                              ("array", JSONValue.string("not an array"))] {
            #expect(throws: NodeDataError.self) { try field("answer", type: type, failure: "default_value", fallback: value) }
        }
        _ = try field("file", type: "file", failure: "default_value", fallback: ["transfer_method": "remote_url", "url": "https://example.test/file.txt"])
    }

    @Test func defaultsAreResolvedOnlyAfterRetryAndMustStillPassFileConstraints() async throws {
        let raw: JSONValue = ["transfer_method": "tool_file", "reference": "dify-file-ref:eyJyZWNvcmRfaWQiOiJvd25lZCJ9"]
        let f = try field("artifact", type: "file", failure: "default_value", fallback: raw)
        let actual: JSONValue = ["related_id": "owned", "transfer_method": "tool_file"]
        let result = await AgentOutputPolicy.decide(fields: [f], candidate: [:], attempt: 0,
            fileValid: { $0["related_id"] == "owned" }, resolveDefault: { _, value in
                #expect(value == raw); return actual
            })
        #expect(result.action == .succeeded && result.outputs["artifact"] == actual)
        let failed = await AgentOutputPolicy.decide(fields: [f], candidate: [:], attempt: 0,
            fileValid: { _ in false }, resolveDefault: { _, _ in actual })
        #expect(failed.action == .failNode)
    }

    @Test func arraysCheckItemTypesAndReservedOrDuplicateNamesAreRefused() async throws {
        let field = try self.field("scores", type: "array", itemType: "number")
        let result = await AgentOutputPolicy.decide(fields: [field], candidate: ["scores": [1, true]], attempt: 0, fileValid: { _ in false })
        #expect(result.action == .failNode && result.checks[0].reason?.contains("items[1]") == true)
        #expect(throws: NodeDataError.self) { try AgentDeclaredOutput.parse([["name": "text", "type": "string"]]) }
        #expect(throws: NodeDataError.self) {
            try AgentDeclaredOutput.parse([["name": "same", "type": "string"], ["name": "same", "type": "number"]])
        }
    }
}
