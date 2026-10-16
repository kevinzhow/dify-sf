/// SplitMix64: tiny, fast, fully deterministic for a given seed on every platform.
public struct Rng: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func int(_ r: ClosedRange<Int>) -> Int {
        r.lowerBound + Int(next() % UInt64(r.upperBound - r.lowerBound + 1))
    }

    public mutating func chance(_ p: Double) -> Bool {
        guard p > 0 else { return false }
        return Double(next() >> 11) / Double(1 << 53) < p
    }

    public mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[int(0...items.count - 1)]
    }
}

extension Rng {
    /// Seed derived from a string (FNV-1a), stable across runs and platforms.
    public init(label: String, salt: UInt64 = 0) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in label.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        self.init(seed: h ^ salt)
    }
}
