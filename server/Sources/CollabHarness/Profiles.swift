import Foundation

/// A named network condition between clients and server. Every round records the profile it ran under.
public struct NetworkProfile: Codable, Sendable {
    /// Toxiproxy toxics for one channel (POST requests or the SSE stream).
    public struct Channel: Codable, Sendable {
        /// One-way latency added to client->server / server->client bytes.
        public var upLatencyMs = 0, upJitterMs = 0, downLatencyMs = 0, downJitterMs = 0
        /// Bandwidth cap in KB/s per direction (0 = unlimited). 32 KB/s = 256 kbit/s.
        public var bandwidthKBps = 0
        /// Fraction (0...1) of new connections whose server->client direction is stalled forever (half-open: the
        /// connection stays up but nothing comes through) - for POST this is "the server committed, the response never arrives".
        public var downStallFraction = 0.0
        public init() {}
    }

    /// Timed behaviour layered on top of the static toxics.
    public enum Dynamics: String, Codable, Sendable {
        case none
        /// Every client's proxies go down for 2-4 s every 8-20 s (clean disconnect: connections are closed).
        case cleanDisconnects
        /// Proxies flip up/down every 0.3-2.5 s.
        case flapping
        /// A quarter of the clients vanish for 20-35 s, then return (long offline).
        case longOffline
        /// The SSE direction server->client silently stops (socket stays open) for windows of 15-30 s, then recovers.
        case halfOpenStream
        /// Every client's event stream is cut every 8 s (random phase per client) while the POST channel is untouched:
        /// a NAT or proxy that caps connection lifetime. (Toxiproxy's `reset_peer` cannot model this: it swallows the
        /// first chunk it sees and resets after the timeout, so no data would ever reach the client.)
        case eventsLifetimeCap
    }

    public var name: String
    public var summary: String
    public var post = Channel()
    public var events = Channel()
    public var netem = NetemSpec()
    public var dynamics = Dynamics.none
    /// Artificial server-side delay before every commit (slow server responses).
    public var serverCommitDelayMs = 0

    public struct NetemSpec: Codable, Sendable {
        public var delayMs = 0, jitterMs = 0
        public var lossPercent = 0.0, reorderPercent = 0.0, duplicatePercent = 0.0
        public init() {}
    }

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }

    public var usesNetem: Bool { netem.delayMs > 0 || netem.lossPercent > 0 || netem.reorderPercent > 0 || netem.duplicatePercent > 0 }

    // MARK: Catalogue

    public static let baseline = NetworkProfile(name: "baseline", summary: "no impairment (through the proxy)")

    private static func latency(_ name: String, rttMs: Int) -> NetworkProfile {
        var p = NetworkProfile(name: name, summary: "fixed latency, RTT +\(rttMs) ms (\(rttMs / 2) ms each way)")
        for kp in [\NetworkProfile.post, \NetworkProfile.events] {
            p[keyPath: kp].upLatencyMs = rttMs / 2
            p[keyPath: kp].downLatencyMs = rttMs / 2
        }
        return p
    }

    public static let catalogue: [NetworkProfile] = {
        var all: [NetworkProfile] = [baseline]
        all += [latency("latency-200ms", rttMs: 200), latency("latency-800ms", rttMs: 800), latency("latency-2s", rttMs: 2000)]
        var jitter = NetworkProfile(name: "jitter", summary: "100 ms each way with +-100 ms jitter")
        for kp in [\NetworkProfile.post, \NetworkProfile.events] {
            jitter[keyPath: kp].upLatencyMs = 100; jitter[keyPath: kp].upJitterMs = 100
            jitter[keyPath: kp].downLatencyMs = 100; jitter[keyPath: kp].downJitterMs = 100
        }
        all.append(jitter)
        var asym = NetworkProfile(name: "asymmetric", summary: "uplink 50 ms, downlink 800 ms (one way)")
        for kp in [\NetworkProfile.post, \NetworkProfile.events] {
            asym[keyPath: kp].upLatencyMs = 50
            asym[keyPath: kp].downLatencyMs = 800
        }
        all.append(asym)
        for loss in [1.0, 5.0, 15.0] {
            var p = NetworkProfile(name: "loss-\(Int(loss))pct", summary: "\(Int(loss))% packet loss (netem) + 40 ms delay")
            p.netem.lossPercent = loss
            p.netem.delayMs = 40
            all.append(p)
        }
        var reorder = NetworkProfile(name: "reorder-duplicate", summary: "25% packet reordering + 5% duplication (netem), 20-60 ms delay")
        reorder.netem.delayMs = 40; reorder.netem.jitterMs = 20; reorder.netem.reorderPercent = 25; reorder.netem.duplicatePercent = 5
        all.append(reorder)
        var bw = NetworkProfile(name: "bandwidth-256kbps", summary: "256 kbit/s per direction (a 500-node snapshot takes many seconds)")
        bw.post.bandwidthKBps = 32; bw.events.bandwidthKBps = 32
        all.append(bw)
        var clean = NetworkProfile(name: "clean-disconnects", summary: "connections closed for 2-4 s every 8-20 s")
        clean.dynamics = .cleanDisconnects
        all.append(clean)
        var half = NetworkProfile(name: "half-open-sse", summary: "SSE direction silently stalls (socket stays open) for 15-30 s windows")
        half.dynamics = .halfOpenStream
        all.append(half)
        var flap = NetworkProfile(name: "flapping", summary: "link up/down every 0.3-2.5 s")
        flap.dynamics = .flapping
        all.append(flap)
        var off = NetworkProfile(name: "long-offline", summary: "25% of clients offline for 20-35 s, then return")
        off.dynamics = .longOffline
        all.append(off)
        var slow = NetworkProfile(name: "slow-server", summary: "every commit takes an extra 800 ms")
        slow.serverCommitDelayMs = 800
        all.append(slow)
        var lostResp = NetworkProfile(name: "post-response-lost", summary: "30% of POST connections swallow the response after the server committed (client times out and resends)")
        lostResp.post.downStallFraction = 0.3
        all.append(lostResp)
        var buf = NetworkProfile(name: "sse-buffered", summary: "a buffering proxy delays the SSE stream by 3-5 s")
        buf.events.downLatencyMs = 3000; buf.events.downJitterMs = 2000
        all.append(buf)
        var cap = NetworkProfile(name: "sse-lifetime-cap", summary: "SSE connections are cut every 8 s (NAT / proxy lifetime cap)")
        cap.dynamics = .eventsLifetimeCap
        all.append(cap)
        return all
    }()

    public static func named(_ n: String) -> NetworkProfile? { catalogue.first { $0.name == n } }
}
