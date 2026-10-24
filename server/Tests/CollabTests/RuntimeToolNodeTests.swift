import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

struct FixtureTools: ToolRuntime {
    var declarations: [JSONValue]
    var messages: [JSONValue]
    var check: @Sendable (JSONObject) throws -> Void = { _ in }
    func parameters(_ tool: ToolReference, context: NodeRunContext) async throws -> [JSONValue] { declarations }
    func invoke(_ tool: ToolReference, parameters: JSONObject, context: NodeRunContext) -> AsyncThrowingStream<ToolRuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
            do { try check(parameters); for message in messages { continuation.yield(.message(message)) }; continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Runtime tool nodes")
struct RuntimeToolNodeTests {
    func node(_ runtime: FixtureTools, bindings: JSONObject = [:]) throws -> ToolNode {
        try ToolNode(id: "tool", data: ["title": "Tool", "type": "tool", "provider_id": "fixture/tools/echo", "provider_type": "builtin", "tool_name": "echo", "tool_parameters": .object(bindings)], runtime: runtime)
    }
    @Test func bindingsAndStreamsFollowTheGraphonContract() async throws {
        let runtime = FixtureTools(declarations: [["name": "text", "required": true], ["name": "n"], ["name": "secret"], ["name": "absent"]],
            messages: [["type": "text", "message": ["text": "hello"]], ["type": "json", "message": ["json_object": ["ok": true]]],
                       ["type": "variable", "message": ["variable_name": "extra", "variable_value": "a", "stream": true]],
                       ["type": "variable", "message": ["variable_name": "extra", "variable_value": "b", "stream": true]]], check: { values in
                #expect(values == ["text": "hello", "n": "3", "secret": "sensitive", "unknown": .null])
            })
        let bindings: JSONObject = ["text": ["type": "mixed", "value": "{{#start.text#}}"], "n": ["type": "constant", "value": 3],
                                   "secret": ["type": "variable", "value": ["env", "key"]], "absent": ["type": "variable", "value": ["start", "missing"]],
                                   "unknown": ["type": "constant", "value": "ignored"]]
        let (result, events) = await runNode(try node(runtime, bindings: bindings), pool: try pool([(["start", "text"], "hello")], secrets: [(["env", "key"], "sensitive")]))
        #expect(result.status == .succeeded)
        #expect(result.outputs == ["text": "hello", "json": [["ok": true]], "files": [], "extra": "ab"])
        #expect(result.inputs["secret"] == "[hidden]")
        #expect(result.outputTypes["files"] == .arrayFile)
        #expect(events.count > 4)
    }
    @Test func missingRequiredVariableFailsBeforeInvocation() async throws {
        let runtime = FixtureTools(declarations: [["name": "text", "required": true]], messages: [], check: { _ in Issue.record("must not invoke") })
        let (result, _) = await runNode(try node(runtime, bindings: ["text": ["type": "variable", "value": ["start", "missing"]]]))
        #expect(result.status == .failed && result.errorType == "ToolParameterError")
    }
    @Test func emptyJSONAndReservedVariables() async throws {
        let (empty, _) = await runNode(try node(FixtureTools(declarations: [], messages: [])))
        #expect(empty.outputs["json"] == [["data": []]])
        let runtime = FixtureTools(declarations: [], messages: [["type": "variable", "message": ["variable_name": "text", "variable_value": "bad"]]])
        let (failed, _) = await runNode(try node(runtime))
        #expect(failed.status == .failed)
    }
    @Test func incompleteAndUnboundedBlobChunksAreRejected() async throws {
        for total in [3, 200 * 1024 * 1024] {
            let runtime = FixtureTools(declarations: [], messages: [["type": "blob_chunk", "message": ["id": "a", "sequence": 0, "total_length": .int(total), "blob": "YQ==", "end": false]]])
            let (result, _) = await runNode(try node(runtime))
            #expect(result.status == .failed && result.errorType == "ToolFileError")
        }
    }
}
