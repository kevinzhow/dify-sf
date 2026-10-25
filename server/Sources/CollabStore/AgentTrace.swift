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

    /// Private replay archive and public log projection share the owner/operation fence. No event is acknowledged first.
    public func appendAgentEvent(session: StoredAgentSession, event: String, record: String, log: String?) async throws {
        try await bounded {
            for try await _ in try await self.client.query("""
                UPDATE agent_node_sessions s SET usage = jsonb_set(
                    jsonb_set(usage, '{agent_events}', coalesce(usage->'agent_events','[]'::jsonb) || \(record)::jsonb),
                    '{agent_log}', coalesce(usage->'agent_log','[]'::jsonb) || coalesce(\(log)::jsonb,'[]'::jsonb)), updated_at = now()
                WHERE execution_id = \(session.executionID) AND generation = \(session.generation)
                  AND owner_id = \(session.ownerID) AND operation_id = \(session.operationID) AND status = 'running' AND lease_until > now()
                  AND NOT coalesce(usage->'agent_events','[]'::jsonb) @> jsonb_build_array(jsonb_build_object('event_key',\(event)::text))
                  AND jsonb_array_length(coalesce(usage->'agent_events','[]'::jsonb)) < 4096
                  AND octet_length(usage::text) + octet_length(\(record)) + coalesce(octet_length(\(log)),0) < 8388608
                RETURNING execution_id
                """, logger: self.logger) { return }
            // Replay after a lost commit response is valid; a changed owner or exhausted archive is not.
            var duplicate = false
            for try await _ in try await self.client.query("""
                SELECT execution_id FROM agent_node_sessions WHERE execution_id = \(session.executionID)
                  AND generation = \(session.generation) AND owner_id = \(session.ownerID) AND operation_id = \(session.operationID)
                  AND status = 'running' AND lease_until > now()
                  AND usage->'agent_events' @> jsonb_build_array(jsonb_build_object('event_key',\(event)::text))
                """, logger: self.logger) { duplicate = true }
            guard duplicate else { throw StoreError.notCommitted("Agent event ownership or archive limit changed") }
        }
    }
}
