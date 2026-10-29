import Foundation
import CollabRuntime

/// Only stable public state enters workflow records; archive paths and raw errors stay private.
enum AgentRetainedSessionStatus {
    static func normalize(_ value: JSONValue?) throws -> JSONObject {
        guard let saved = value?["saved"]?.bool else {
            throw NodeError("AgentServiceProtocolError", "The agent service did not report retained session state")
        }
        if !saved { return ["saved": false, "error": "session_save_failed"] }
        guard let thread = value?["thread_id"]?.string, thread.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let turns = value?["turns"]?.int, (0...1_000_000).contains(turns) else {
            throw NodeError("AgentServiceProtocolError", "The retained session receipt is invalid")
        }
        return ["saved": true, "thread_id": .string(thread), "turns": .int(turns)]
    }
}
