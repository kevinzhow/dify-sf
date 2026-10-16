import CollabCore
import Foundation

/// Applies a `NetworkProfile` to the per-client proxies and runs its timed behaviour.
public final class NetworkControl: @unchecked Sendable {
    public struct ProxyPair: Sendable {
        public var post: String
        public var events: String
    }

    private let toxi: Toxiproxy
    private let profile: NetworkProfile
    private let pairs: [ProxyPair]
    private var tasks: [Task<Void, Never>] = []
    private let lock = NSLock()
    public private(set) var injected: [String: Int] = [:]

    public init(toxi: Toxiproxy, profile: NetworkProfile, pairs: [ProxyPair]) {
        self.toxi = toxi
        self.profile = profile
        self.pairs = pairs
    }

    private func bump(_ k: String) { lock.lock(); injected[k, default: 0] += 1; lock.unlock() }

    /// Installs the static toxics (latency, bandwidth, stalls, resets).
    public func applyStatic() async {
        for pair in pairs {
            await install(profile.post, on: pair.post)
            await install(profile.events, on: pair.events)
        }
    }

    private func install(_ c: NetworkProfile.Channel, on proxy: String) async {
        if c.upLatencyMs > 0 || c.upJitterMs > 0 {
            await toxi.setToxic(proxy: proxy, name: "lat-up", type: "latency", stream: "upstream",
                                attributes: ["latency": c.upLatencyMs, "jitter": c.upJitterMs])
        }
        if c.downLatencyMs > 0 || c.downJitterMs > 0 {
            await toxi.setToxic(proxy: proxy, name: "lat-down", type: "latency", stream: "downstream",
                                attributes: ["latency": c.downLatencyMs, "jitter": c.downJitterMs])
        }
        if c.bandwidthKBps > 0 {
            await toxi.setToxic(proxy: proxy, name: "bw-up", type: "bandwidth", stream: "upstream", attributes: ["rate": c.bandwidthKBps])
            await toxi.setToxic(proxy: proxy, name: "bw-down", type: "bandwidth", stream: "downstream", attributes: ["rate": c.bandwidthKBps])
        }
        if c.downStallFraction > 0 {
            // timeout = 0: the connection stays open, data is held back (never delivered while the toxic is in place).
            await toxi.setToxic(proxy: proxy, name: "stall-down", type: "timeout", stream: "downstream",
                                attributes: ["timeout": 0], toxicity: c.downStallFraction)
        }
        if c.resetAfterMs > 0 {
            await toxi.setToxic(proxy: proxy, name: "reset", type: "reset_peer", stream: "downstream", attributes: ["timeout": c.resetAfterMs])
        }
    }

    /// Starts the timed behaviour of the profile.
    public func startDynamics() {
        switch profile.dynamics {
        case .none: break
        case .cleanDisconnects:
            for (i, p) in pairs.enumerated() {
                spawn(seed: i) { [self] rng in
                    try? await Task.sleep(for: .milliseconds(rng.int(1000...12000)))
                    while !Task.isCancelled {
                        await setUp(p, false); bump("disconnect")
                        try? await Task.sleep(for: .milliseconds(rng.int(2000...4000)))
                        await setUp(p, true)
                        try? await Task.sleep(for: .milliseconds(rng.int(8000...20000)))
                    }
                }
            }
        case .flapping:
            for (i, p) in pairs.enumerated() {
                spawn(seed: 100 + i) { [self] rng in
                    var up = true
                    while !Task.isCancelled {
                        up.toggle()
                        await setUp(p, up)
                        if !up { bump("flap") }
                        try? await Task.sleep(for: .milliseconds(rng.int(300...2500)))
                    }
                }
            }
        case .longOffline:
            for (i, p) in pairs.enumerated() where i % 4 == 0 {
                spawn(seed: 200 + i) { [self] rng in
                    try? await Task.sleep(for: .milliseconds(rng.int(3000...15000)))
                    await setUp(p, false); bump("longOffline")
                    try? await Task.sleep(for: .milliseconds(rng.int(20000...35000)))
                    await setUp(p, true)
                }
            }
        case .halfOpenStream:
            for (i, p) in pairs.enumerated() {
                spawn(seed: 300 + i) { [self] rng in
                    try? await Task.sleep(for: .milliseconds(rng.int(1000...15000)))
                    while !Task.isCancelled {
                        await toxi.setToxic(proxy: p.events, name: "half-open", type: "timeout", stream: "downstream", attributes: ["timeout": 0])
                        bump("halfOpen")
                        try? await Task.sleep(for: .milliseconds(rng.int(15000...30000)))
                        await toxi.removeToxic(proxy: p.events, name: "half-open")
                        try? await Task.sleep(for: .milliseconds(rng.int(10000...25000)))
                    }
                }
            }
        }
    }

    private func spawn(seed: Int, _ body: @escaping @Sendable (inout Rng) async -> Void) {
        let t = Task { var rng = Rng(seed: UInt64(seed) &* 7919 &+ 13); await body(&rng) }
        lock.lock(); tasks.append(t); lock.unlock()
    }

    private func setUp(_ p: ProxyPair, _ up: Bool) async {
        await toxi.setEnabled(p.post, up)
        await toxi.setEnabled(p.events, up)
    }

    /// Ad-hoc fault for the chaos runs: take one client's proxies down for `ms`.
    public func cut(_ index: Int, forMs ms: Int) async {
        guard pairs.indices.contains(index) else { return }
        bump("cut")
        await setUp(pairs[index], false)
        try? await Task.sleep(for: .milliseconds(ms))
        let p = pairs[index]
        await Task { await self.setUp(p, true) }.value  // heal even if the fault window just ended
    }

    /// Ad-hoc fault: stall the server->client direction of both channels for `ms` (connection stays open).
    public func stall(_ index: Int, forMs ms: Int) async {
        guard pairs.indices.contains(index) else { return }
        bump("stall")
        let p = pairs[index]
        for proxy in [p.post, p.events] {
            await toxi.setToxic(proxy: proxy, name: "adhoc-stall", type: "timeout", stream: "downstream", attributes: ["timeout": 0])
        }
        try? await Task.sleep(for: .milliseconds(ms))
        await Task { for proxy in [p.post, p.events] { await self.toxi.removeToxic(proxy: proxy, name: "adhoc-stall") } }.value
    }

    /// Stops all timed behaviour and puts every proxy back to a clean, enabled state.
    public func restore() async {
        let t: [Task<Void, Never>] = lock.withLock { let t = tasks; tasks = []; return t }
        for x in t { x.cancel() }
        for x in t { await x.value }
        for p in pairs {
            await toxi.ensureClean(proxy: p.post)
            await toxi.ensureClean(proxy: p.events)
        }
    }
}
