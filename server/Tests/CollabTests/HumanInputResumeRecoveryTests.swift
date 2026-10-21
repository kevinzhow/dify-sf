import CollabCore
import Foundation
import Logging
import Testing
@testable import CollabStore
@testable import CollabServer

@Suite("Human input durable resume and stale scans")
struct HumanInputResumeRecoveryTests {
    @Test(.enabled(if: testDbHost != nil))
    func aTemporaryClaimFailureRemainsEligibleForPeriodicRecovery() async throws {
        var config = humanInputTestConfig()
        config.testDefect = "slowClaim"
        try await withHumanInputServerAndRoutes(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.appYAML(), token: owner).str("id")
            let response = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let required = try #require(HumanInputRunTests.frames(response.text).first { $0["event"]?.string == "human_input_required" })
            let token = try #require(required["data"]?["form_token"]?.string)
            let runId = try #require(required["workflow_run_id"]?.string)
            // A transaction error before the claim commits, on this test's isolated schema only.
            try await store.executeForTest("""
                CREATE FUNCTION review_block_claim() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF OLD.status = 'paused' AND NEW.status = 'running' THEN RAISE EXCEPTION 'temporary claim failure'; END IF;
                    RETURN NEW;
                END $$
                """)
            try await store.executeForTest("CREATE TRIGGER review_claim BEFORE UPDATE ON workflow_runs FOR EACH ROW EXECUTE FUNCTION review_block_claim()")
            let answered = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"yes"},"action":"approve"}"#, token: owner)
            #expect(answered.status == 200)
            try await Task.sleep(for: .milliseconds(1700)) // the request's slowClaim attempt fails
            let logger = Logger(label: "third-review")
            let ready = humanInputTestConfig()
            let second = try CollabServer.Routes(registry: DocumentRegistry(store: store, config: ready, logger: logger),
                                                store: store, config: ready, logger: logger)
            await StartupRecovery(routes: second, logger: logger).run()
            try await store.executeForTest("DROP TRIGGER review_claim ON workflow_runs")
            // What the production periodic worker actually does after the database comes back.
            for _ in 0..<3 {
                await HumanInputTimeouts(routes: second, intervalSeconds: 1, logger: logger).runOnce(now: Date())
                try await Task.sleep(for: .milliseconds(200))
            }
            let status = try await store.workflowRun(id: runId)?.status
            #expect(status == "succeeded", "accepted answer was stranded after a transient claim failure: \(status ?? "nil")")
        }
    }

    @Test(.enabled(if: testDbHost != nil))
    func aStaleGlobalSweepDoesNotExpireFormsAfterResumeWon() async throws {
        var config = humanInputTestConfig()
        config.testDefect = "slowClaim"
        try await withHumanInputServerAndRoutes(config: config) { api, store, _ in
            let owner = try await api.setupOwner()
            let app = try await api.post("/v1/docs/import", HumanInputRunTests.twoFormsYAML(), token: owner).str("id")
            let response = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: owner)
            let required = HumanInputRunTests.frames(response.text).filter { $0["event"]?.string == "human_input_required" }
            #expect(required.count == 2)
            let token = try #require(required.first?["data"]?["form_token"]?.string)
            let other = try #require(required.last?["data"]?["form_token"]?.string)
            let runId = try #require(required.first?["workflow_run_id"]?.string)
            let answered = try await api.post("/v1/form/human_input/\(token)", #"{"inputs":{"reply":"yes"},"action":"approve"}"#, token: owner)
            #expect(answered.status == 200)
            // A still-fresh run must also reject a premature global scan.
            #expect(try await !store.expireRunForGlobalTimeout(workflowRunId: runId, error: "premature scan", at: Date(), timeoutSeconds: 86400))
            let claim = try await store.claimResume(workflowRunId: runId, at: Date())
            #expect(claim != nil)
            #expect(try await !store.endHumanInputForm(token: other, status: .timedOut, at: Date()))
            let changed = try await store.expireRunForGlobalTimeout(workflowRunId: runId, error: "stale scan", at: Date())
            #expect(!changed, "resume already won the run's state transition")
            let remaining = try await store.humanInputForm(token: other)?.status
            #expect(remaining == .waiting, "a refused stale timeout still mutated the running phase's remaining form: \(String(describing: remaining))")
            try await Task.sleep(for: .milliseconds(1700))
        }
    }
}
