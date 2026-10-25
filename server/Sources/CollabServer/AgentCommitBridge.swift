import CollabRuntime
import Foundation

struct AgentNodeTrace: Sendable {
    var nodeID: String
    var title: String
    var startedAt: Date
    var index: Int
    var scope: NodeScope
}

/// A node waits here before reporting completion to the engine. This prevents downstream side effects from racing an
/// uncommitted Agent result; the existing run persistence code still assigns and stores the ordinary trace fields.
actor AgentCommitBridge {
    typealias Handler = @Sendable (String, AgentNodeTrace, NodeRunResult) async throws -> Void
    private var handler: Handler?
    private var traces: [String: AgentNodeTrace] = [:]

    func clear() { handler = nil; traces.removeAll() }
    func install(_ handler: @escaping Handler) { self.handler = handler }
    func started(_ execution: String, trace: AgentNodeTrace) { traces[execution] = trace }

    func startedData(_ execution: String) async throws -> JSONValue {
        for _ in 0..<500 {
            try Task.checkCancellation()
            if let trace = traces[execution] {
                return RunStreamEncoder.nodeStartedData(execution: execution, node: trace.nodeID, type: "agent", title: trace.title, at: trace.startedAt, scope: trace.scope)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NodeError("AgentPersistenceUnavailable", "The workflow could not capture the agent node start")
    }

    func commit(_ execution: String, result: NodeRunResult) async throws {
        // The started event and this call are delivered on separate tasks. A bounded wait also makes unsupported
        // direct-node execution fail clearly, without leaving a continuation or waiting on a frontend connection.
        for _ in 0..<500 {
            try Task.checkCancellation()
            if let handler, let trace = traces[execution] { try await handler(execution, trace, result); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NodeError("AgentPersistenceUnavailable", "The workflow could not commit the agent node result")
    }
}
