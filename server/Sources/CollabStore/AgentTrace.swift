import Foundation
import PostgresNIO

extension PostgresStore {
    /// Recover the accepted-run identity only for the exact expired operation. This never adopts/replays active work.
    public func reconcileExpiredAgentRun(execution: String, operation: String, generation: Int, run: String) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE agent_node_sessions SET agent_run_id = \(run), updated_at = now()
                WHERE execution_id = \(execution) AND operation_id = \(operation) AND generation = \(generation)
                  AND agent_run_id IS NULL AND status = 'running' AND lease_until <= now()
                """, logger: self.logger)
        }
    }

    public func agentTraceSessions(run: String) async throws -> [StoredAgentSession] {
        try await bounded {
            var result: [StoredAgentSession] = []
            for try await json in try await self.client.query("SELECT row_to_json(s)::text FROM agent_node_sessions s WHERE workflow_run_id = \(run) ORDER BY created_at, execution_id", logger: self.logger).decode(String.self) {
                result.append(try StoredAgentSession(json: json))
            }
            return result
        }
    }


    /// One immutable row per event. Hold a shared ownership lock until insertion commits so a concurrent
    /// outcome/owner change cannot acknowledge a result before this event is durable. Duplicate delivery is harmless.
    @discardableResult
    public func appendAgentEvent(session: StoredAgentSession, event: String, record: String, log: String?) async throws -> Bool {
        try await bounded {
            try await AgentEventWriteRetry.run {
                try await self.client.withTransaction(logger: self.logger) { tx in
                    var owned = false
                    for try await _ in try await tx.query("""
                        SELECT execution_id FROM agent_node_sessions WHERE execution_id = \(session.executionID)
                          AND generation = \(session.generation) AND owner_id = \(session.ownerID) AND operation_id = \(session.operationID)
                          AND status = 'running' AND lease_until > now() FOR SHARE
                        """, logger: self.logger) { owned = true }
                    guard owned else { throw StoreError.notCommitted("Agent event ownership changed") }
                    for try await _ in try await tx.query("""
                        INSERT INTO agent_event_records(execution_id, operation_id, event_key, record, log)
                        VALUES (\(session.executionID), \(session.operationID), \(event), \(record), \(log))
                        ON CONFLICT(execution_id, event_key) DO NOTHING RETURNING ordinal
                        """, logger: self.logger) { return true }
                    return false
                }
            }
        }
    }


    /// The sandbox capability belongs to an execution, not to each answer/resume or transient health probe.
    public func pinAgentShell(session: StoredAgentSession, enabled: Bool) async throws -> Bool {
        try await bounded {
            for try await value in try await self.client.query("""
                UPDATE agent_node_sessions SET usage = jsonb_set(usage, '{shell_enabled}',
                    coalesce(usage->'shell_enabled', to_jsonb(\(enabled)::boolean)))
                WHERE execution_id = \(session.executionID) AND generation = \(session.generation)
                  AND owner_id = \(session.ownerID) AND lease_until > now()
                  AND status IN ('prepared', 'paused', 'retry') RETURNING (usage->>'shell_enabled')::boolean
                """, logger: self.logger).decode(Bool.self) { return value }
            throw StoreError.notCommitted("Agent capability ownership changed")
        }
    }

    /// Keyset paging keeps the download and preview bounded even for arbitrarily long reasoning histories.
    public func agentEventRecords(execution: String, after: Int = 0, limit: Int = 128) async throws -> [StoredAgentEvent] {
        try await bounded {
            var rows: [StoredAgentEvent] = []
            for try await (ordinal, record, log) in try await self.client.query("""
                SELECT ordinal, record, log FROM agent_event_records WHERE execution_id = \(execution) AND ordinal > \(after)
                ORDER BY ordinal LIMIT \(max(1, min(limit, 256)))
                """, logger: self.logger).decode((Int, String, String?).self) {
                rows.append(.init(ordinal: ordinal, record: record, log: log))
            }
            return rows
        }
    }
    /// Reverse keyset paging for the end of long previews. No OFFSET or whole-archive allocation.
    public func agentEventRecordsBefore(execution: String, before: Int, limit: Int = 128) async throws -> [StoredAgentEvent] {
        try await bounded {
            var rows: [StoredAgentEvent] = []
            for try await (ordinal, record, log) in try await self.client.query("""
                SELECT ordinal, record, log FROM agent_event_records WHERE execution_id = \(execution) AND ordinal < \(before)
                ORDER BY ordinal DESC LIMIT \(max(1, min(limit, 256)))
                """, logger: self.logger).decode((Int, String, String?).self) {
                rows.append(.init(ordinal: ordinal, record: record, log: log))
            }
            return rows
        }
    }

}

public struct StoredAgentEvent: Sendable {
    public let ordinal: Int
    public let record: String
    public let log: String?
}

/// Retry only the immutable, uniquely keyed event insertion, never an agent
/// operation/model/tool. An uncertain COMMIT is safe to repeat because of its
/// (execution_id, event_key) unique key and the ownership check in the same tx.
enum AgentEventWriteRetry {
    static func transientSQLState(_ state: String) -> Bool {
        state.hasPrefix("08") || ["40001", "40P01", "53300", "57P01", "57P02", "57P03"].contains(state)
    }
    static func transient(_ error: any Error) -> Bool {
        if error is CancellationError || error is StoreError { return false }
        if let tx = error as? PostgresTransactionError {
            let causes = [tx.beginError, tx.closureError, tx.commitError, tx.rollbackError].compactMap { $0 }
            return !causes.isEmpty && causes.allSatisfy { transient($0) }
        }
        guard let error = error as? PSQLError else { return false }
        if [.connectionError, .serverClosedConnection, .uncleanShutdown].contains(error.code) { return true }
        return error.code == .server && transientSQLState(error.serverInfo?[.sqlState] ?? "")
    }
    static func run<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do { return try await work() }
            catch {
                guard attempt < 3, transient(error) else { throw error }
                try await Task.sleep(for: .milliseconds(100 * (1 << attempt)))
            }
        }
        preconditionFailure("retry loop must return or throw")
    }
}
