import Foundation

/// A place on the office floor.
///
/// Not a `CGPoint`: `u`/`v` are floor axes, not screen axes, and letting the two
/// be mistaken for each other is how a room ends up drawn ninety degrees out.
struct FloorPoint: Equatable, Sendable {
    var u: Double
    var v: Double
}

/// What an agent is doing while it stands or sits in the break room.
enum BreakActivity: Equatable, Sendable {
    case sofa, coffee, table, counter, standing

    /// Where a figure is drawn holding a cup. Standing in the middle of the
    /// room with a coffee that came from nowhere reads as a drawing mistake.
    var holdsCoffee: Bool {
        switch self {
        case .coffee, .table, .counter: true
        case .sofa, .standing: false
        }
    }
}

/// One place in the break room a waiting agent can occupy.
struct BreakSlot: Equatable, Sendable {
    let u: Double
    let v: Double
    /// Sitting figures are drawn shorter and raised onto the furniture.
    let sitting: Bool
    let activity: BreakActivity

    var point: FloorPoint { FloorPoint(u: u, v: v) }
}

/// One waiting agent's state at one instant: which leg of the wander it is on,
/// and how far along it is.
struct Walker: Equatable, Sendable {
    let from: FloorPoint
    let to: FloorPoint
    let slot: BreakSlot
    let slotIndex: Int
    /// 0 at the moment it leaves `from`, 1 once it has arrived and while it
    /// stays put.
    let progress: Double

    var isMoving: Bool { progress < 1 }

    /// Eased interpolation along the current leg. The easing is the reference's
    /// `ease` — an agent that starts and stops abruptly reads as a sprite being
    /// teleported rather than as a person crossing a room.
    func position(at progress: Double) -> FloorPoint {
        let e = Walker.ease(min(1, max(0, progress)))
        return FloorPoint(u: from.u + (to.u - from.u) * e,
                          v: from.v + (to.v - from.v) * e)
    }

    var position: FloorPoint { position(at: progress) }

    static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

/// The break room: eight places, and the wander between them.
///
/// The wander has to be a pure function of the session id and the frame number,
/// because the scene is. Two consequences follow, and both are deliberate:
///
/// * The generator is seeded with FNV-1a over the id, never `hashValue`, which
///   is seeded per process and would change the whole room on every launch.
/// * The walk is a closed cycle of a fixed number of legs rather than an
///   open-ended random walk. An open walk would have to be simulated from time
///   zero on every frame, and the frame number this scene is given is absolute —
///   billions of frames since the reference date — so that simulation would
///   never finish. The cycle is arranged to end where it began, so wrapping is
///   not visible as a jump.
struct BreakRoom: Equatable, Sendable {
    let slots: [BreakSlot]

    /// How many legs a wander is made of before it repeats. Sixty-four legs at
    /// roughly eleven seconds each is about twelve minutes — far longer than
    /// anyone watches one figure, and cheap enough to rebuild per frame.
    static let legCount = 64

    init(room: RoomRect) {
        let mu = room.midU
        // The reference's eight places, in its order: two on the sofa, one at
        // the coffee machine, two at the table, one at the counter, two just
        // standing about.
        slots = [
            BreakSlot(u: room.u0 + 1.05, v: room.v0 + 1.15, sitting: true, activity: .sofa),
            BreakSlot(u: room.u0 + 1.05, v: room.v0 + 1.95, sitting: true, activity: .sofa),
            BreakSlot(u: room.u1 - 1.15, v: room.v0 + 0.85, sitting: false, activity: .coffee),
            BreakSlot(u: mu + 0.15, v: room.v1 - 1.15, sitting: true, activity: .table),
            BreakSlot(u: mu + 1.15, v: room.v1 - 1.15, sitting: true, activity: .table),
            BreakSlot(u: room.u1 - 1.15, v: room.v0 + 1.95, sitting: false, activity: .counter),
            BreakSlot(u: mu - 0.35, v: room.v0 + 0.55, sitting: false, activity: .standing),
            BreakSlot(u: mu + 0.95, v: room.v0 + 0.45, sitting: false, activity: .standing)
        ]
    }

    /// The place an agent starts at. Taken from its position in the waiting
    /// list, not from its id: hashing the id into a slot would collide, and two
    /// figures sharing one chair while five chairs stand empty is the failure
    /// this avoids.
    func startSlotIndex(order: Int) -> Int {
        guard !slots.isEmpty else { return 0 }
        return ((order % slots.count) + slots.count) % slots.count
    }

    /// Where this agent is, and what it is doing, at this frame.
    ///
    /// `order` is its place in the waiting list and decides where it starts;
    /// `seed` is its session id and decides everything after that.
    func walker(for order: Int, seed: String, frame: Int) -> Walker {
        let plan = plan(order: order, seed: seed)
        guard !plan.legs.isEmpty, plan.total > 0 else {
            let index = startSlotIndex(order: order)
            let slot = slots.isEmpty
                ? BreakSlot(u: 0, v: 0, sitting: false, activity: .standing)
                : slots[index]
            return Walker(from: slot.point, to: slot.point, slot: slot,
                          slotIndex: index, progress: 1)
        }

        // The cycle closes, so the modulo is not a seam.
        var t = Double(frame) / 60
        t = t.truncatingRemainder(dividingBy: plan.total)
        if t < 0 { t += plan.total }

        var elapsed = 0.0
        for leg in plan.legs {
            // Each leg is a stay followed by a stroll, in that order, so at
            // frame zero everyone is sitting in the place they were assigned
            // rather than already halfway out of it.
            if t < elapsed + leg.hold {
                return Walker(from: leg.from.point, to: leg.from.point, slot: leg.from,
                              slotIndex: leg.fromIndex, progress: 1)
            }
            elapsed += leg.hold
            if t < elapsed + leg.duration {
                return Walker(from: leg.from.point, to: leg.to.point, slot: leg.to,
                              slotIndex: leg.toIndex,
                              progress: (t - elapsed) / leg.duration)
            }
            elapsed += leg.duration
        }
        // Only reachable through floating-point slack at the very end of the
        // cycle, where the walk has just arrived back where it began.
        let last = plan.legs[plan.legs.count - 1]
        return Walker(from: last.to.point, to: last.to.point, slot: last.to,
                      slotIndex: last.toIndex, progress: 1)
    }

    // MARK: - The plan

    /// One stay in a place, and the stroll out of it that follows.
    private struct Leg {
        let from: BreakSlot
        let fromIndex: Int
        let to: BreakSlot
        let toIndex: Int
        /// How long the agent stays put before setting off. The brief's four to
        /// thirteen seconds.
        let hold: Double
        /// How long the stroll takes.
        let duration: Double
    }

    private struct Plan {
        let legs: [Leg]
        let total: Double
    }

    private func plan(order: Int, seed: String) -> Plan {
        guard !slots.isEmpty else { return Plan(legs: [], total: 0) }
        var rng = LinearGenerator(seed: seed)
        let first = startSlotIndex(order: order)

        var legs: [Leg] = []
        var currentIndex = first
        for k in 0..<Self.legCount {
            // The last leg is forced home, so the end of the cycle is the start
            // of the next one and the wrap cannot be seen.
            let nextIndex = k == Self.legCount - 1
                ? first
                : Int(rng.next() * Double(slots.count)) % slots.count
            // The reference's numbers: the agent stays put for 4–13 s, then
            // takes 1.6–3.8 s to stroll to the next place.
            let hold = 4 + rng.next() * 9
            let duration = 1.6 + rng.next() * 2.2
            legs.append(Leg(from: slots[currentIndex], fromIndex: currentIndex,
                            to: slots[nextIndex], toIndex: nextIndex,
                            hold: hold, duration: duration))
            currentIndex = nextIndex
        }
        return Plan(legs: legs, total: legs.reduce(0) { $0 + $1.hold + $1.duration })
    }
}

/// The reference's generator: a linear congruential sequence, seeded from the
/// session id rather than from the clock or from `hashValue`.
private struct LinearGenerator {
    private var state: UInt32

    init(seed: String) {
        state = UInt32(truncatingIfNeeded: SessionPalette.fnv1a(seed))
    }

    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / 4_294_967_296
    }
}
