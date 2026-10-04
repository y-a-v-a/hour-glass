/// A small xorshift64* generator. The simulation draws several random numbers per grain per step,
/// so it needs something much cheaper than the system generator, and seedable for tests.
public struct FastRandom {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    @inline(__always)
    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    /// A uniform value in `0..<1`.
    @inline(__always)
    public mutating func unit() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// A uniform value in `-1..<1`.
    @inline(__always)
    public mutating func signedUnit() -> Float {
        unit() * 2 - 1
    }

    /// A uniform integer in `0..<bound`.
    @inline(__always)
    public mutating func below(_ bound: Int) -> Int {
        Int(truncatingIfNeeded: next() % UInt64(bound))
    }

    @inline(__always)
    public mutating func coinFlip() -> Bool {
        next() & 1 == 0
    }
}
