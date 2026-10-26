import CollabRuntime
import Foundation
import PostgresNIO
import Testing
@testable import CollabStore
@testable import CollabServer

@Suite("Agent event persistence retry", .enabled(if: testDbHost != nil), .serialized)
struct AgentPersistenceRetryTests {
    @Test func classificationExcludesDiskFullPermissionsAndOwnershipFailures() {
        for code in ["08006", "40001", "40P01", "53300", "57P01"] { #expect(AgentEventWriteRetry.transientSQLState(code)) }
        for code in ["53100", "42501", "23505", "22000", "57014", ""] { #expect(!AgentEventWriteRetry.transientSQLState(code)) }
        #expect(!AgentEventWriteRetry.transient(StoreError.notCommitted("ownership changed")))
        #expect(!AgentEventWriteRetry.transient(CancellationError()))
    }

    private func injected(_ state: String, failures: Int, expected: Int, succeeds: Bool) async throws {
        try await withServer { api, store, _ in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            try await store.startAgentOperation(session: session, operation: session.executionID + ":0:0", digest: "fixture", tokenHash: "fixture")
            session = try #require(try await store.agentSession(execution: session.executionID))
            // PostgreSQL sequences survive transaction rollback: count real
            // database attempts, including failures before any event is stored.
            _ = try await store.client.query("CREATE SEQUENCE agent_retry_counter", logger: store.logger)
            let function = """
                CREATE FUNCTION agent_retry_inject() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.execution_id = TG_ARGV[0] AND nextval('agent_retry_counter') <= TG_ARGV[1]::integer THEN
                        RAISE EXCEPTION 'synthetic persistence failure' USING ERRCODE = TG_ARGV[2];
                    END IF;
                    RETURN NEW;
                END $$
                """
            _ = try await store.client.query(PostgresQuery(unsafeSQL: function), logger: store.logger)
            let trigger = "CREATE TRIGGER agent_retry_trigger BEFORE INSERT ON agent_event_records FOR EACH ROW EXECUTE FUNCTION agent_retry_inject('\(session.executionID)', '\(failures)', '\(state)')"
            _ = try await store.client.query(PostgresQuery(unsafeSQL: trigger), logger: store.logger)
            do {
                let inserted = try await store.appendAgentEvent(session: session, event: "remote:1", record: "[]", log: nil)
                #expect(succeeds && inserted)
            } catch { #expect(!succeeds) }
            for try await attempts in try await store.client.query("SELECT last_value FROM agent_retry_counter", logger: store.logger).decode(Int.self) {
                #expect(attempts == expected)
            }
            #expect(try await store.agentEventRecords(execution: session.executionID).count == (succeeds ? 1 : 0))
            _ = try await store.client.query("DROP TRIGGER agent_retry_trigger ON agent_event_records", logger: store.logger)
            _ = try await store.client.query("DROP FUNCTION agent_retry_inject()", logger: store.logger)
            _ = try await store.client.query("DROP SEQUENCE agent_retry_counter", logger: store.logger)
            // The same operation/session is still running; no tool/model replay
            // or abandon was used to survive a transient event write failure.
            #expect(try await store.agentSession(execution: session.executionID)?.status == "running")
        }
    }
    @Test func realSerializationErrorsRetryTheSameEventAndCommitOnce() async throws {
        try await injected("40001", failures: 2, expected: 3, succeeds: true)
    }
    @Test func retriesAreFiniteAndDiskErrorsAreNotTreatedAsTransportLoss() async throws {
        try await injected("40001", failures: 10, expected: 4, succeeds: false)
        try await injected("53100", failures: 10, expected: 1, succeeds: false)
    }
}
