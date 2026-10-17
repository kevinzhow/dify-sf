import CollabCore

/// Knobs for one simulated run. All randomness derives from the seed passed to `World`.
public struct SimConfig: Sendable {
    public var clientCount = 3
    public var steps = 300
    public var initialNodes = 4
    public var snapshotEvery = 16
    /// Reconnecting clients further behind than this get a snapshot instead of a replay.
    public var maxReplay = 40
    public var pingEvery = 10

    // user behaviour
    public var editRate = 0.35          // chance per step that some user edits
    public var burstRate = 0.10         // chance that an edit is a fast burst of 2-5 edits
    public var reapplyRate = 0.6        // chance a user re-applies an edit that lost a conflict
    public var restoreRate = 0.07       // chance an edit is the undo of a committed delete (protocol 1.6), when one exists
    public var legacyFraction = 0.0     // share of clients older than 1.6 (their streams must never carry restoreNode)
    public var legacySlots: Set<Int> = []  // these clients are older than 1.6 regardless of `legacyFraction` (scenarios)

    // network (per message)
    public var maxDelay = 3
    public var dropRate = 0.0
    public var dupRate = 0.0

    // faults (per step)
    public var disconnectRate = 0.0
    public var longOfflineRate = 0.0    // given a disconnect, chance it is a long "stale tab" absence
    public var clientCrashRate = 0.0
    public var volatileFraction = 0.4   // share of clients that do NOT keep a write-ahead journal
    public var serverCrashRate = 0.0

    // mutation-test knobs (never on in real profiles)
    public var defects: ProtocolDefects = []
    public var lossyDisk = false        // crash drops the last few logged (already acked) entries

    public init() {}
}

public enum Profile: Int, CaseIterable, Sendable {
    case calm, lossy, flaky, crashy, chaos

    public var name: String {
        ["calm", "lossy", "flaky", "crashy", "chaos"][rawValue]
    }

    /// Builds a config for this profile; sizes are randomised from `rng` so runs differ.
    public func config(rng: inout Rng) -> SimConfig {
        var c = SimConfig()
        c.clientCount = rng.int(2...5)
        c.steps = rng.int(150...450)
        c.initialNodes = rng.int(2...6)
        c.snapshotEvery = rng.int(4...40)
        c.maxReplay = rng.int(6...120)
        c.maxDelay = rng.int(1...6)
        c.editRate = Double(rng.int(25...60)) / 100
        c.legacyFraction = Double(rng.int(0...3)) / 10
        switch self {
        case .calm: break
        case .lossy:
            c.dropRate = Double(rng.int(5...30)) / 100
            c.dupRate = Double(rng.int(0...10)) / 100
        case .flaky:
            c.dropRate = Double(rng.int(0...10)) / 100
            c.disconnectRate = Double(rng.int(2...6)) / 100
            c.longOfflineRate = 0.2
        case .crashy:
            c.dropRate = Double(rng.int(0...8)) / 100
            c.clientCrashRate = Double(rng.int(1...3)) / 100
            c.serverCrashRate = Double(rng.int(1...3)) / 100
        case .chaos:
            c.dropRate = Double(rng.int(5...20)) / 100
            c.dupRate = Double(rng.int(0...8)) / 100
            c.disconnectRate = Double(rng.int(2...6)) / 100
            c.longOfflineRate = 0.25
            c.clientCrashRate = Double(rng.int(1...3)) / 100
            c.serverCrashRate = Double(rng.int(1...3)) / 100
        }
        return c
    }
}
