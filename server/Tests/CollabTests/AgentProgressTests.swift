import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent progress projection") struct AgentProgressTests {
    @Test func startedAndProgressEventsReachLogsWithStableIDsAndSecretRedaction() {
        let samples: [(Int, String, JSONObject)] = [(1, "run_started", ["max_turns": 200]),
            (2, "progress", ["caption": "fixture-secret preview", "call_index": 12])]
        for (event, name, data) in samples {
            let projected = AgentTrace.project(run: "run", node: "agent", event: event, name: name, data: data, secrets: ["fixture-secret"])
            #expect(projected.log?["message_id"] == .string("run:\(event)"))
            #expect(projected.log?["metadata"]?["event"] == .string(name))
            #expect(!projected.record.compactJSON().contains("fixture-secret"))
        }
    }
}

@Suite("Agent progress file ownership", .enabled(if: testDbHost != nil)) struct AgentProgressFileTests {
    @Test func onlyCompletedReceiptsForThisExecutionCanPublishAnImage() async throws {
        try await withServerAndRoutes { api, store, routes in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            #expect(try await store.pinAgentReportProgress(session: session, enabled: true))
            #expect(try await store.pinAgentReportProgress(session: session, enabled: false))
            var foreignOwner = session; foreignOwner.ownerID = "other-owner"
            await #expect(throws: StoreError.self) { try await store.pinAgentReportProgress(session: foreignOwner, enabled: false) }
            let operation = session.executionID + ":0:0"
            try await store.startAgentOperation(session: session, operation: operation, digest: "fixture-digest", tokenHash: "fixture-only")
            session = try #require(try await store.agentSession(execution: session.executionID))
            let files = TestRuntimeFiles()
            let id = files.file.recordId
            let account = try #require(try await store.workflowRun(id: session.workflowRunID)?.createdBy)
            try await store.insertUploadFile(.init(id: id, workspaceId: uploadWorkspaceId, key: uploadWorkspaceId + "/" + id,
                name: files.file.filename, size: Int64(files.file.size), extensionName: "png", mimeType: files.file.mimeType,
                createdBy: account, sha256: "fixture-only"))
            _ = try await store.client.query("""
                INSERT INTO agent_file_uploads (id, execution_id, operation_id, generation, token_hash,
                    filename, mime_type, size, state, file_id, expires_at)
                VALUES (\(id), \(session.executionID), \(operation), \(session.generation), 'fixture-only',
                    \(files.file.filename), \(files.file.mimeType), \(files.file.size), 'ready', \(id), now() + interval '10 minutes')
                """, logger: store.logger)
            let receipt: JSONObject = ["upload_id": .string(id), "filename": .string(files.file.filename),
                "mime_type": .string(files.file.mimeType), "size": .int(files.file.size), "url": "https://untrusted.invalid/do-not-use"]
            let normalized = try await routes.normalizeAgentProgress(["file": .object(receipt), "caption": "Fixture progress", "call_index": 12,
                "path": "/host/private", "unexpected": "must-not-publish"], session: session, files: files)
            #expect(normalized["file"] == files.file.json)
            #expect(normalized["caption"] == "Fixture progress" && normalized["call_index"] == 12)
            #expect(normalized["path"] == nil && normalized["unexpected"] == nil)
            #expect(!JSONValue.object(normalized).compactJSON().contains("untrusted.invalid"))
            var wrongExecution = session; wrongExecution.executionID = UUID().uuidString.lowercased()
            #expect(try await routes.normalizeAgentProgress(["file": .object(receipt)], session: wrongExecution, files: files)["file_unavailable"] == true)
            for field in ["filename", "mime_type", "size"] {
                var mismatched = receipt
                mismatched[field] = field == "size" ? 999 : "wrong"
                let result = try await routes.normalizeAgentProgress(["file": .object(mismatched)], session: session, files: files)
                #expect(result["file"] == nil && result["file_unavailable"] == true)
            }
            _ = try await store.client.query("UPDATE agent_file_uploads SET state = 'writing' WHERE id = \(id)", logger: store.logger)
            #expect(try await routes.normalizeAgentProgress(["file": .object(receipt)], session: session, files: files)["file_unavailable"] == true)
        }
    }
}
