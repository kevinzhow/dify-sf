import CollabCore
import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent long records", .enabled(if: testDbHost != nil))
struct AgentLongRecordsTests {
    @Test func longReasoningArchivesRowsWithoutFailingAndTheBoundedPreviewReferencesTheFullRedactedFile() async throws {
        try await withServer { api, store, registry in
            var session = try await AgentExecutionStoreTests.seed(api, store)
            try await store.startAgentOperation(session: session, operation: session.executionID + ":0:0", digest: "fixture", tokenHash: "fixture")
            session = try #require(try await store.agentSession(execution: session.executionID))
            let routes = try Routes(registry: registry, store: store, config: ServerConfig.defaults, logger: store.logger)
            let secret = "synthetic-event-secret"
            for index in 1...4105 {
                if index % 200 == 0 { #expect(try await store.renewAgentSession(execution: session.executionID, owner: session.ownerID, generation: session.generation)) }
                let projected = AgentTrace.project(run: "remote", node: session.nodeID, event: index, name: index == 4105 ? "model_call" : "thought",
                    data: ["text": .string(String(repeating: "想🙂", count: 320) + secret), "usage": ["total_tokens": 3]], secrets: [secret])
                try await store.appendAgentEvent(session: session, event: "remote:\(index)", record: JSONValue.array([projected.record]).compactJSON(),
                    log: projected.log.map { JSONValue.array([$0]).compactJSON() })
            }
            let preview = try await routes.agentLogPreview(session)
            #expect(preview.compactJSON().utf8.count <= Routes.agentLogPreviewBytes)
            #expect(preview.array?.last?["data"]?["truncated"] == true)
            let path = try #require(preview.array?.last?["data"]?["full_record_url"]?.string)
            #expect(!preview.compactJSON().contains(secret))
            #expect(try await store.agentSession(execution: session.executionID)?.usage.utf8.count ?? 0 < 1024)
            var after = 0, count = 0, size = 0, last: JSONValue = [:]
            while true {
                let rows = try await store.agentEventRecords(execution: session.executionID, after: after)
                if rows.isEmpty { break }
                for row in rows { after = row.ordinal; count += 1; size += row.record.utf8.count; last = try JSONValue.parse(row.record); #expect(!row.record.contains(secret)) }
            }
            #expect(count == 4105 && size > 8 << 20)
            #expect(last.array?.first?["event"] == "model_call")
            // The full file uses ordinary member authorization; it is never a public signed capability.
            #expect(try await api.get(path).status == 401)
            let login = try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#)
            #expect(login.status == 200, "\(login.text)")
            let token = login.str("access_token"); #expect(!token.isEmpty)
            let download = try await api.get(path, token: token)
            #expect(download.status == 200)
            #expect(download.text.split(separator: "\n").count == 4105)
            #expect(!download.text.contains(secret))
            let other = path.replacingOccurrences(of: session.workflowRunID, with: UUID().uuidString.lowercased())
            #expect(try await api.get(other, token: token).status == 404)
            // Replaying a committed cursor does not add an event row or broadcast it twice.
            let duplicate = try await store.appendAgentEvent(session: session, event: "remote:4105", record: "[]", log: nil)
            #expect(!duplicate)
            try await store.recordAgentResult(session: session, run: "remote", event: 4105, result: #"{"status":"succeeded"}"#)
            #expect(try await store.agentSession(execution: session.executionID)?.status == "result_ready")
        }
    }
}
