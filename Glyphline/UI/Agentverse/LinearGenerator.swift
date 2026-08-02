/// The reference's generator: a linear congruential sequence, seeded from the
/// session id rather than from the clock or from `hashValue`.
///
/// In a file of its own, and not private, because more than one scene needs the
/// same sequence — the break room's wander and the datastream's lanes both draw
/// from it, and a second copy would be a second thing to keep in step.
struct LinearGenerator {
    private var state: UInt32

    init(seed: String) {
        state = UInt32(truncatingIfNeeded: SessionPalette.fnv1a(seed))
    }

    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / 4_294_967_296
    }
}
