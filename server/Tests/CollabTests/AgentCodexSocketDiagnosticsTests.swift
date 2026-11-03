import Foundation
import Logging
import NIOCore
import Synchronization
import Testing
@testable import CollabServer

final class CodexSocketLog: Sendable {
    struct Entry: Sendable {
        let message: String
        let fields: [String: String]
    }
    private let entries = Mutex<[Entry]>([])
    var snapshot: [Entry] { entries.withLock { $0 } }
    var logger: Logger { Logger(label: "codex-socket-test") { _ in Handler(log: self) } }
    private struct Handler: LogHandler {
        let log: CodexSocketLog
        var metadata: Logger.Metadata = [:]
        var logLevel = Logger.Level.info
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String,
                 file: String, function: String, line: UInt) {
            let fields = self.metadata.merging(metadata ?? [:]) { _, new in new }.mapValues { String(describing: $0) }
            log.entries.withLock { $0.append(.init(message: String(describing: message), fields: fields)) }
        }
    }
}

struct AgentCodexSocketDiagnosticsTests {
    @Test func errorCodesAndCleanupAreRecordedWithoutErrorDescriptions() {
        let log = CodexSocketLog()
        let requestID = "0123456789abcdef0123456789abcdef"
        let trace = AgentCodexSocketDiagnostics(logger: log.logger, socketID: "synthetic-socket", requestID: requestID)
        trace.ended(.upstreamRead, .error, error: IOError(errnoCode: 104,
            reason: "Bearer fixture-private-token at https://private.invalid/?key=fixture-secret"))
        trace.ended(.lifecycle, .cancelled)
        trace.ended(.upstreamChannel, .channelClosed)
        let entries = log.snapshot
        #expect(entries.count == 3)
        #expect(entries[0].fields["stage"] == "upstream_read")
        #expect(entries[0].fields["system_errno"] == "104")
        #expect(entries[0].fields["request_id"] == requestID)
        #expect(entries.map { $0.fields["terminal_sequence"] } == ["1", "2", "3"])
        #expect(entries.map { $0.fields["first_observed"] } == ["true", "false", "false"])
        let rendered = String(describing: entries)
        for forbidden in ["fixture-private-token", "private.invalid", "fixture-secret", "Bearer"] {
            #expect(!rendered.contains(forbidden))
        }
    }

    @Test(arguments: ["Bearer fixture-secret", "0123456789abcdef0123456789abcde\n", String(repeating: "a", count: 1024)])
    func untrustedRequestIDsAreNotLogged(value: String) {
        let log = CodexSocketLog()
        let trace = AgentCodexSocketDiagnostics(logger: log.logger, socketID: "synthetic-socket", requestID: value)
        trace.ended(.downstreamRead, .closeFrame, closeCode: 1000)
        #expect(log.snapshot.count == 1)
        #expect(log.snapshot[0].fields["request_id"] == nil)
        #expect(log.snapshot[0].fields["close_code"] == "1000")
        #expect(!String(describing: log.snapshot).contains(value))
    }

    @Test func concurrentCleanupHasOnlyOneFirstObservation() async {
        let log = CodexSocketLog()
        let trace = AgentCodexSocketDiagnostics(logger: log.logger, socketID: "synthetic-socket", requestID: nil)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { trace.ended(.lifecycle, .cancelled) } }
        }
        let entries = log.snapshot
        #expect(entries.count == 32)
        #expect(entries.filter { $0.fields["first_observed"] == "true" }.count == 1)
        #expect(Set(entries.compactMap { $0.fields["terminal_sequence"] }).count == 32)
    }
}
