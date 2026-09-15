public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

public struct PropertyFailure: Equatable, Sendable {
    public let seed: UInt64
    public let iteration: Int
    public let value: UInt64
}

public enum DeterministicProperty {
    public static func check(
        seed: UInt64,
        iterations: Int,
        predicate: (UInt64) -> Bool
    ) -> PropertyFailure? {
        var generator = SplitMix64(seed: seed)
        for iteration in 0..<iterations {
            let value = generator.next()
            if !predicate(value) {
                return PropertyFailure(seed: seed, iteration: iteration, value: value)
            }
        }
        return nil
    }

    public static func reproduce(_ failure: PropertyFailure) -> UInt64 {
        var generator = SplitMix64(seed: failure.seed)
        var value: UInt64 = 0
        for _ in 0...failure.iteration {
            value = generator.next()
        }
        return value
    }
}
