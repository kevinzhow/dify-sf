import CollabCore
import CollabInvariants
import Foundation
import Glibc

/// One line of a client's ground-truth ledger (JSON lines, appended with a single write per line so a
/// kill -9 can lose at most the line being written).
public struct LedgerLine: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case issued, committed, rejected, lost, early }
    public var k: Kind
    public var c: ClientID
    public var cseq: Int?
    public var t: Int64                // wall-clock millis
    public var base: Int?
    public var op: Op?
    public var seq: Int?
    public var reason: RejectReason?
}

public final class LedgerWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    public init(path: String) {
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    deinit { if fd >= 0 { _ = Glibc.close(fd) } }

    public func append(_ line: LedgerLine) {
        guard fd >= 0, var data = try? WireJSON.encode(line) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

}

/// Everything the harness knows about what its clients did, merged across processes and incarnations.
public struct LedgerSummary: Sendable {
    public var issued: [OpKey: Issued] = [:]
    public var issuedAt: [OpKey: Int64] = [:]
    public var terminals: [OpKey: [Terminal]] = [:]
    public var terminalAt: [OpKey: Int64] = [:]
    public var earlyWarnings = 0
    public var malformedLines = 0
}

public enum LedgerReader {
    public static func read(files: [String]) -> LedgerSummary {
        var s = LedgerSummary()
        for path in files {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let line = try? WireJSON.decode(LedgerLine.self, from: String(raw)) else {
                    s.malformedLines += 1  // a torn last line after kill -9: ignored
                    continue
                }
                let key = line.cseq.map { OpKey(client: line.c, cseq: $0) }
                switch line.k {
                case .issued:
                    guard let key, let op = line.op, let base = line.base else { continue }
                    if s.issued[key] == nil { s.issued[key] = Issued(op: op, base: base); s.issuedAt[key] = line.t }
                case .committed:
                    guard let key, let seq = line.seq else { continue }
                    s.terminals[key, default: []].append(.committed(seq: seq))
                    s.terminalAt[key] = min(s.terminalAt[key] ?? line.t, line.t)
                case .rejected:
                    guard let key, let r = line.reason else { continue }
                    s.terminals[key, default: []].append(.rejected(r))
                    s.terminalAt[key] = min(s.terminalAt[key] ?? line.t, line.t)
                case .lost:
                    guard let key else { continue }
                    s.terminals[key, default: []].append(.lost)
                case .early: s.earlyWarnings += 1
                }
            }
        }
        return s
    }
}

/// Final per-client dump written by a worker once it has converged.
public struct ClientFinal: Codable, Sendable {
    public var id: ClientID
    public var lastSeq: Int
    public var unresolved: Int
    public var confirmed: Document
    public var view: Document
    public var violations: [String]
    public var stats: DriverStatsDump
}

public struct DriverStatsDump: Codable, Sendable {
    public var posts = 0, postFailures = 0, streamsOpened = 0, streamsLost = 0, snapshots = 0, commits = 0
    public var postMillis: [Int] = []
}

/// Per-client "when did I apply seq N" (wall millis), flushed periodically so a kill -9 loses little.
public struct AppliedTimes: Codable, Sendable {
    public var client: ClientID
    public var at: [Int64]  // index = seq
}

public final class AppliedRecorder: @unchecked Sendable {
    private var at: [Int64] = [0]
    private let lock = NSLock()
    let client: ClientID
    let path: String

    public init(client: ClientID, path: String) {
        self.client = client
        self.path = path
    }

    public func record(first: Int, last: Int, wall: Int64) {
        guard last >= first, first >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if at.count <= last { at.append(contentsOf: [Int64](repeating: 0, count: last + 1 - at.count)) }
        for s in first...last where at[s] == 0 { at[s] = wall }
    }

    public func flush() {
        lock.lock()
        let snapshot = at
        lock.unlock()
        guard let data = try? JSONEncoder().encode(AppliedTimes(client: client, at: snapshot)) else { return }
        let tmp = path + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: data)
        rename(tmp, path)
    }
}
