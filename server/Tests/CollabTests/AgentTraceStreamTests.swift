import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Agent streaming secret redaction")
struct AgentTraceStreamTests {
    @Test func everySplitIncludingOneScalarEventsAndOverlappingSecretsIsMasked() {
        for secret in ["synthetic-token-123", "秘🙂密钥", "abababa"] {
            let scalars = Array(secret.unicodeScalars)
            for split in 1..<scalars.count {
                var redactor = AgentReasoningRedactor(secrets: [secret])
                let first = redactor.redact("before " + String(String.UnicodeScalarView(scalars[..<split])))
                let second = redactor.redact(String(String.UnicodeScalarView(scalars[split...])) + " after.")
                #expect(first == "before [redacted]")
                #expect(second == "[redacted] after.")
            }
            var redactor = AgentReasoningRedactor(secrets: [secret])
            for scalar in scalars { #expect(redactor.redact(String(scalar)) == "[redacted]") }
        }
        var overlap = AgentReasoningRedactor(secrets: ["aba", "bab"])
        #expect(overlap.redact("a") == "[redacted]")
        #expect(overlap.redact("ba") == "[redacted]")
        #expect(overlap.redact("b") == "[redacted]")
    }

    @Test func falsePrefixesFailClosedWithoutDroppingUnrelatedTextOrRetainingRawChunks() {
        var redactor = AgentReasoningRedactor(secrets: ["secret-value"])
        #expect(redactor.redact("normal text") == "normal text")
        #expect(redactor.redact("the sec") == "the [redacted]")
        #expect(redactor.redact("tion is visible") == "tion is visible")
        #expect(redactor.redact("secret-value twice secret-value!") == "[redacted] twice [redacted]!")
        var empty = AgentReasoningRedactor(secrets: [""])
        #expect(empty.redact("unchanged🙂") == "unchanged🙂")
    }

    @Test func longOverlappingPrefixesRemainBoundedAndDoNotExposeTheLaterCompletion() {
        let prefix = String(repeating: "a", count: 1024)
        var redactor = AgentReasoningRedactor(secrets: [prefix + "b"])
        let first = redactor.redact(String(repeating: "a", count: 200_000))
        #expect(first == String(repeating: "a", count: 200_000 - 1024) + "[redacted]")
        #expect(redactor.redact("b done.") == "[redacted] done.")
    }

    @Test func compactionLifecycleIsVisibleInTraceLogsAndKeepsEventIdentity() throws {
        for phase: JSONValue in ["started", "finished"] {
            let projected = AgentTrace.project(run: "remote", node: "node", event: 17,
                name: "compaction", data: ["phase": phase, "call_index": 3], secrets: [])
            let log = try #require(projected.log)
            #expect(log["label"] == "compaction" && log["metadata"]?["event"] == "compaction")
            #expect(log["message_id"] == "remote:17" && projected.record["event_key"] == "remote:17")
            #expect(log["status"] == (phase == "started" ? "start" : "success"))
        }
    }

    @Test func toolLabelsAreRedactedAsWellAsNestedArgumentsAndObjectKeys() {
        let result = AgentTrace.project(run: "remote", node: "node", event: 1, name: "tool_call",
            data: ["name": "contains-secret", "arguments": ["contains-secret": "contains-secret"]], secrets: ["secret"])
        #expect(!result.record.compactJSON().contains("secret"))
        #expect(!result.log!.compactJSON().contains("secret"))
    }
}
