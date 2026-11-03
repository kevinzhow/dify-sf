import CollabRuntime
import Logging

/// The pinned native Codex dispatches tools on output_item.done, not added or
/// arguments.done. Keep only bounded identities, never arguments or history.
struct AgentCodexToolCheckpoint: Sendable {
    enum Phase: String { case announced, dispatchable, acknowledged, unsafe }
    struct Observation {
        var phase: Phase
        var id: String?
    }
    private(set) var pending: Set<String> = []
    private(set) var announced: Set<String> = []
    private(set) var unsafe = false
    static let limit = 256

    mutating func observe(_ item: JSONValue, complete: Bool) -> Observation? {
        guard let type = item["type"]?.string, type.hasSuffix("_call") else { return nil }
        let clientTool = type == "function_call" || type == "custom_tool_call"
        let rawID = item["call_id"]?.string
        let id = rawID.flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? $0 : nil }
        // Unknown tool protocols may execute remotely before item completion.
        guard clientTool else { unsafe = true; return .init(phase: .unsafe, id: id) }
        if !complete {
            guard let id else { return .init(phase: .announced, id: nil) }
            guard announced.contains(id) || announced.count < Self.limit else {
                unsafe = true; return .init(phase: .unsafe, id: id)
            }
            return announced.insert(id).inserted ? .init(phase: .announced, id: id) : nil
        }
        guard let id, pending.contains(id) || pending.count < Self.limit else {
            unsafe = true; return .init(phase: .unsafe, id: id)
        }
        announced.remove(id)
        return pending.insert(id).inserted ? .init(phase: .dispatchable, id: id) : nil
    }

    mutating func acknowledge(_ id: String) -> Bool {
        announced.remove(id)
        return pending.remove(id) != nil
    }

    static func metadata(phase: String, pending: Set<String>, announced: Int, unsafe: Bool, id: String? = nil) -> Logger.Metadata {
        // Hash only validated, bounded IDs. No tool names, arguments, outputs,
        // capabilities, raw identities or partial model text reach the log.
        var fields: Logger.Metadata = ["tool_phase": .string(phase), "pending_tools": "\(pending.count)",
            "announced_tools": "\(announced)", "unsafe_tools": "\(unsafe)"]
        if let id { fields["tool_ref"] = .string(Tokens.sha256(id)) }
        fields["pending_refs"] = .array(pending.sorted().prefix(8).map { .string(Tokens.sha256($0)) })
        fields["pending_refs_truncated"] = "\(pending.count > 8)"
        return fields
    }
}
