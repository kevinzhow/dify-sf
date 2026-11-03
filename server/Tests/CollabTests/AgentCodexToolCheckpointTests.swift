import CollabRuntime
import Foundation
import Testing
@testable import CollabServer

struct AgentCodexToolCheckpointTests {
    static func item(_ id: String?, kind: String = "function_call") -> JSONValue {
        var item: JSONObject = ["type": .string(kind), "arguments": "private command body"]
        if let id { item["call_id"] = .string(id) }
        return .object(item)
    }

    @Test(arguments: ["function_call", "custom_tool_call"])
    func completionBeforeResponseEndStillRequiresTheActualResult(kind: String) {
        var tools = AgentCodexToolCheckpoint()
        _ = tools.observe(Self.item("one", kind: kind), complete: false)
        #expect(tools.pending.isEmpty && tools.announced == ["one"])
        _ = tools.observe(Self.item("one", kind: kind), complete: true)
        #expect(tools.pending == ["one"] && tools.announced.isEmpty)
        #expect(tools.acknowledge("different") == false && tools.pending == ["one"])
        #expect(tools.acknowledge("one") && tools.pending.isEmpty)
    }

    @Test func anUnknownToolProtocolRemainsUnsafeEvenBeforeCompletion() {
        var tools = AgentCodexToolCheckpoint()
        _ = tools.observe(Self.item("unknown", kind: "unrecognized_call"), complete: false)
        #expect(tools.unsafe)
    }

    @Test(arguments: [String?.none, "", String(repeating: "x", count: 257)])
    func invalidIdentityIsOnlyUnsafeWhenTheClientToolCanDispatch(id: String?) {
        var tools = AgentCodexToolCheckpoint()
        _ = tools.observe(Self.item(id), complete: false)
        #expect(!tools.unsafe && tools.pending.isEmpty)
        _ = tools.observe(Self.item(id), complete: true)
        #expect(tools.unsafe)
    }

    @Test func boundedIdentitiesAllowDuplicateCompletionAtCapacity() {
        var tools = AgentCodexToolCheckpoint()
        for i in 0..<256 { _ = tools.observe(Self.item("call-\(i)"), complete: true) }
        #expect(!tools.unsafe && tools.pending.count == 256)
        _ = tools.observe(Self.item("call-0"), complete: true)
        #expect(!tools.unsafe)
        _ = tools.observe(Self.item("overflow"), complete: true)
        #expect(tools.unsafe && tools.pending.count == 256)
    }

    @Test func diagnosticFieldsContainOnlyStagesCountsAndBoundedIdentityHashes() {
        let ids = Set((0..<12).map { "private-call-id-\($0)" })
        let fields = AgentCodexToolCheckpoint.metadata(phase: "recovery_refused", pending: ids, announced: 1, unsafe: false, id: "private-call-id-0")
        let text = String(describing: fields)
        #expect(!text.contains("private-call-id"))
        #expect(text.contains(Tokens.sha256("private-call-id-0")))
        #expect(String(describing: fields["pending_tools"]!) == "12")
        #expect(String(describing: fields["announced_tools"]!) == "1")
        #expect(String(describing: fields["pending_refs_truncated"]!) == "true")
        if case .array(let refs)? = fields["pending_refs"] { #expect(refs.count == 8) }
        else { Issue.record("Expected bounded diagnostic references") }
    }
}
