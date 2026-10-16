import AsyncHTTPClient
import CollabClientKit
import CollabCore
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// Environment of the harness (set by bench/run.sh).
public struct HarnessEnv: Sendable {
    public var dbHost = env("HARNESS_DB_HOST", "127.0.0.1")
    public var dbPort = Int(env("HARNESS_DB_PORT", "5432")) ?? 5432
    public var dbUser = env("HARNESS_DB_USER", "collab")
    public var dbPassword = env("HARNESS_DB_PASSWORD", "collab")
    public var dbName = env("HARNESS_DB_NAME", "collab")
    /// Toxiproxy admin API, e.g. http://toxiproxy:8474 (empty = run without a fault proxy).
    public var toxiproxyAPI = env("HARNESS_TOXIPROXY_API", "")
    /// Host name under which clients reach toxiproxy's listeners.
    public var toxiproxyHost = env("HARNESS_TOXIPROXY_HOST", "127.0.0.1")
    /// Host name under which toxiproxy reaches the server processes (this machine/container).
    public var selfHost = env("HARNESS_SELF_HOST", "127.0.0.1")
    public var binDir = env("HARNESS_BIN_DIR", ".build/release")
    public var netemDevice = env("HARNESS_NETEM_DEV", "eth0")
    public init() {}

    public var serverBinary: String { "\(binDir)/collab-server" }
    public var benchBinary: String { "\(binDir)/collab-bench" }
}

private func env(_ k: String, _ d: String) -> String { ProcessInfo.processInfo.environment[k] ?? d }

// MARK: - Child processes

/// A child process we can kill -9, pause and resume.
public final class ManagedProcess: @unchecked Sendable {
    public let process = Process()
    public let name: String
    private let stdoutPipe: Pipe?
    private let stdinPipe: Pipe?
    public private(set) var stdoutLines: AsyncStream<String>?

    public init(name: String, executable: String, arguments: [String], environment: [String: String] = [:],
                logPath: String, pipes: Bool = false) throws {
        self.name = name
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var e = ProcessInfo.processInfo.environment
        for (k, v) in environment { e[k] = v }
        process.environment = e
        if pipes {
            let out = Pipe(), inp = Pipe()
            stdoutPipe = out
            stdinPipe = inp
            process.standardOutput = out
            process.standardInput = inp
            FileManager.default.createFile(atPath: logPath, contents: nil)
            process.standardError = FileHandle(forWritingAtPath: logPath)
        } else {
            stdoutPipe = nil
            stdinPipe = nil
            FileManager.default.createFile(atPath: logPath, contents: nil)
            let fh = FileHandle(forWritingAtPath: logPath)
            process.standardOutput = fh
            process.standardError = fh
        }
        try process.run()
        if let out = stdoutPipe {
            stdoutLines = LineStream.make(fd: out.fileHandleForReading.fileDescriptor)
        }
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func send(_ line: String) {
        try? stdinPipe?.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func kill9() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    public func terminate() {
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
    }

    public func pause() { if process.isRunning { kill(process.processIdentifier, SIGSTOP) } }
    public func resume() { if process.isRunning { kill(process.processIdentifier, SIGCONT) } }

    public func waitExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return !process.isRunning
    }
}

/// The server under test as a real OS process.
public final class ServerProcess: @unchecked Sendable {
    public let port: Int
    private let env: HarnessEnv
    private let dir: String
    private let extraEnv: [String: String]
    private var proc: ManagedProcess?
    private var generation = 0
    /// Database host as seen by the server (may point at a fault proxy).
    private let dbHost: String
    private let dbPort: Int

    public init(port: Int, dir: String, env: HarnessEnv, dbHost: String? = nil, dbPort: Int? = nil, extraEnv: [String: String] = [:]) {
        self.port = port
        self.dir = dir
        self.env = env
        self.dbHost = dbHost ?? env.dbHost
        self.dbPort = dbPort ?? env.dbPort
        self.extraEnv = extraEnv
    }

    public var pid: Int32? { proc?.isRunning == true ? proc?.pid : nil }
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    public func start() throws {
        generation += 1
        var e = extraEnv
        e["COLLAB_HTTP_HOST"] = "0.0.0.0"
        e["COLLAB_HTTP_PORT"] = "\(port)"
        e["COLLAB_DB_HOST"] = dbHost
        e["COLLAB_DB_PORT"] = "\(dbPort)"
        e["COLLAB_DB_USER"] = env.dbUser
        e["COLLAB_DB_PASSWORD"] = env.dbPassword
        e["COLLAB_DB_NAME"] = env.dbName
        e["COLLAB_LOG_LEVEL"] = e["COLLAB_LOG_LEVEL"] ?? ProcessInfo.processInfo.environment["HARNESS_SERVER_LOG_LEVEL"] ?? "notice"
        if let d = ProcessInfo.processInfo.environment["HARNESS_SERVER_DEFECT"], !d.isEmpty { e["COLLAB_TEST_DEFECT"] = d }
        proc = try ManagedProcess(name: "server", executable: env.serverBinary, arguments: [], environment: e,
                                  logPath: "\(dir)/server.\(generation).log")
    }

    public func kill9() { proc?.kill9() }
    public func stop() async {
        proc?.terminate()
        if await proc?.waitExit(timeout: .seconds(5)) == false { proc?.kill9() }
    }

    /// Polls /healthz until the server answers (or throws after `timeout`).
    public func waitHealthy(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if proc?.isRunning != true { throw HarnessError("server process exited during startup (see \(dir)/server.\(generation).log)") }
            if let (status, _) = try? await HarnessHTTP.get("\(baseURL)/healthz", timeout: .seconds(2)), status == 200 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError("server did not become healthy in time")
    }

    /// CPU seconds (user+system) and resident set size in bytes of the server process.
    public func resourceUsage() -> (cpuSeconds: Double, rssBytes: Int)? {
        guard let pid else { return nil }
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 13, let ut = Double(fields[11]), let st = Double(fields[12]) else { return nil }
        let rss = (try? String(contentsOfFile: "/proc/\(pid)/statm", encoding: .utf8))
            .flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
        return ((ut + st) / 100.0, rss * 4096)
    }
}

/// Plain GET helper that always drains the body (an unconsumed body wedges AsyncHTTPClient's connection).
public enum HarnessHTTP {
    public static func get(_ url: String, timeout: Duration) async throws -> (Int, Data) {
        try await withTimeout(timeout) {
            var r = HTTPClientRequest(url: url)
            r.method = .GET
            let resp = try await HTTPClient.shared.execute(r, deadline: .now() + .seconds(Int64(timeout.components.seconds) + 1))
            let data = Data(buffer: try await resp.body.collect(upTo: 256 << 20))
            return (Int(resp.status.code), data)
        }
    }
}

public struct HarnessError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

// MARK: - Toxiproxy

/// Minimal client for the Toxiproxy admin API.
public final class Toxiproxy: @unchecked Sendable {
    private let api: String
    private let http: HTTPClient

    public init(api: String) {
        self.api = api
        http = HTTPClient(eventLoopGroupProvider: .singleton)
    }

    public func shutdown() async { try? await http.shutdown() }

    @discardableResult
    private func call(_ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, allow: Set<Int> = [200, 201, 204]) async throws -> Data {
        var r = HTTPClientRequest(url: "\(api)\(path)")
        r.method = method
        r.headers.add(name: "Connection", value: "close")  // no keep-alive: Toxiproxy's idle-connection handling races with reuse
        if let body {
            r.headers.add(name: "Content-Type", value: "application/json")
            r.body = .bytes(try JSONSerialization.data(withJSONObject: body))
        }
        // Toxiproxy closes idle keep-alive connections; a request that races with such a close is simply repeated.
        var lastError: Error = HarnessError("toxiproxy unreachable")
        for _ in 0..<4 {
            do {
                let resp = try await http.execute(r, timeout: .seconds(10))
                let data = Data(buffer: try await resp.body.collect(upTo: 1 << 20))
                guard allow.contains(Int(resp.status.code)) else {
                    throw HarnessError("toxiproxy \(method) \(path) -> \(resp.status.code): \(String(decoding: data, as: UTF8.self))")
                }
                return data
            } catch let e as HarnessError { throw e } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError
    }

    public func createProxy(name: String, listenPort: Int, upstream: String) async throws {
        try? await call(.DELETE, "/proxies/\(name)", allow: [204, 404])
        try await call(.POST, "/proxies", ["name": name, "listen": "0.0.0.0:\(listenPort)", "upstream": upstream, "enabled": true])
    }

    public func deleteProxy(_ name: String) async { _ = try? await call(.DELETE, "/proxies/\(name)", allow: [204, 404]) }

    /// Number of admin-API calls that failed even after retries (reported by the rounds).
    public private(set) var failedCalls = 0
    private let counterLock = NSLock()
    private func failed() { counterLock.lock(); failedCalls += 1; counterLock.unlock() }

    @discardableResult
    public func setEnabled(_ name: String, _ enabled: Bool) async -> Bool {
        do { _ = try await call(.POST, "/proxies/\(name)", ["enabled": enabled]); return true } catch { failed(); return false }
    }

    /// Adds (or replaces) a toxic. `type`: latency, bandwidth, timeout, slow_close, reset_peer, limit_data, slicer.
    public func setToxic(proxy: String, name: String, type: String, stream: String, attributes: [String: Any], toxicity: Double = 1.0) async {
        _ = try? await call(.DELETE, "/proxies/\(proxy)/toxics/\(name)", allow: [204, 404])
        _ = try? await call(.POST, "/proxies/\(proxy)/toxics",
                            ["name": name, "type": type, "stream": stream, "toxicity": toxicity, "attributes": attributes])
    }

    public func removeToxic(proxy: String, name: String) async {
        do { _ = try await call(.DELETE, "/proxies/\(proxy)/toxics/\(name)", allow: [204, 404]) } catch { failed() }
    }

    /// Removes every toxic and re-enables the proxy, retrying until the admin API confirms a clean state.
    public func ensureClean(proxy: String) async {
        for _ in 0..<40 {
            if let data = try? await call(.GET, "/proxies/\(proxy)/toxics"),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for t in arr { if let n = t["name"] as? String { await removeToxic(proxy: proxy, name: n) } }
                if arr.isEmpty, await setEnabled(proxy, true) { return }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        failed()
    }
}

// MARK: - netem

/// Real packet loss/reordering/duplication on the egress of this machine towards the fault proxy, via `tc netem`.
public struct Netem: Sendable {
    public var delayMs = 0
    public var jitterMs = 0
    public var lossPercent = 0.0
    public var reorderPercent = 0.0
    public var duplicatePercent = 0.0

    public init(delayMs: Int = 0, jitterMs: Int = 0, lossPercent: Double = 0, reorderPercent: Double = 0, duplicatePercent: Double = 0) {
        self.delayMs = delayMs
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.reorderPercent = reorderPercent
        self.duplicatePercent = duplicatePercent
    }

    public var isIdentity: Bool { delayMs == 0 && jitterMs == 0 && lossPercent == 0 && reorderPercent == 0 && duplicatePercent == 0 }

    var options: [String] {
        var o: [String] = []
        if delayMs > 0 || reorderPercent > 0 {
            // reordering needs a delay so that packets can overtake each other
            o += ["delay", "\(max(delayMs, reorderPercent > 0 ? 20 : 0))ms"]
            if jitterMs > 0 { o.append("\(jitterMs)ms") }
        }
        if lossPercent > 0 { o += ["loss", "\(lossPercent)%"] }
        if duplicatePercent > 0 { o += ["duplicate", "\(duplicatePercent)%"] }
        if reorderPercent > 0 { o += ["reorder", "\(100 - reorderPercent)%", "50%"] }
        return o
    }

    /// Whether the netem setup can be used here (root + tc present).
    public static var available: Bool { geteuid() == 0 && FileManager.default.fileExists(atPath: "/usr/sbin/tc") }

    private static func tc(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/tc")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    public static func clear(device: String) { tc(["qdisc", "del", "dev", device, "root"]) }

    /// Shapes only traffic whose destination is `toIP` (the fault proxy); everything else is untouched.
    public static func apply(_ n: Netem, device: String, toIP: String) {
        clear(device: device)
        guard !n.isIdentity else { return }
        tc(["qdisc", "add", "dev", device, "root", "handle", "1:", "prio"])
        tc(["qdisc", "add", "dev", device, "parent", "1:3", "handle", "30:", "netem"] + n.options)
        tc(["filter", "add", "dev", device, "protocol", "ip", "parent", "1:0", "prio", "1", "u32", "match", "ip", "dst", "\(toIP)/32", "flowid", "1:3"])
    }

    public static func resolve(host: String) -> String? {
        var hints = addrinfo(), res: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addr = r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
