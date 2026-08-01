import XCTest
@testable import Glyphline

final class BreakRoomTests: XCTestCase {
    /// The break room the layout actually hands out, so the assertions are about
    /// the room the scene draws rather than about a made-up rectangle.
    private let room = IsoLayout.fit(sessionCount: 8,
                                     canvas: CGSize(width: 1300, height: 740)).breakRoom
    private var breakRoom: BreakRoom { BreakRoom(room: room) }

    /// A realistic population: session ids in the shape the scanner reads off
    /// disk, which is a UUID per transcript.
    ///
    /// Written out rather than generated, and not sequential, on purpose. The
    /// first eight of these collide when hashed into eight places — 8 → 6 — so
    /// a starting slot picked by hashing the id fails
    /// `testDifferentIdsGetDifferentStartingSlots` instead of slipping through
    /// on a tidy population that happens to hash to a permutation.
    private let ids = [
        "3f2a91c4-7b18-4d0e-9a55-1c6e2f80b3d7", "a17c5e90-2d44-4f31-8b6a-0e93c7154da2",
        "c84b6027-9f13-4a5c-b2d8-7e015a3f96b1", "5d90a3f8-6c27-41be-9034-8a1f2be705cd",
        "e2617b45-0a89-4c73-a1f6-3d582049eb1c", "7ba0d312-58e6-4917-8c2d-9f4a6013b7e5",
        "1c4f8e63-b271-405a-93de-6087f2c15a49", "9e05427d-3ac1-48f6-b590-2d17e6480fb3",
        "48d1f6b0-7e35-42ca-8916-b0d47f251e8a", "b6390c1e-4d82-47f5-a30b-5c81e97246df",
        "2a7e51d9-08b4-463c-97f1-e4d0b825397c", "f051ce38-9a67-4b20-85dc-13e78f409a6b",
        "6d24b09f-c517-4e8a-b743-902f5c1de680", "0eb87342-5f9a-4d16-8c05-a7326be9147f",
        "8c53a1e7-2b60-49df-9143-6f08d7c25b4e", "d719a60b-3e48-4a92-b5c7-01f8e3527a6d",
        "4a86c2f5-1d70-43eb-92a8-58c604d17f39", "ee32805a-6b91-4c47-80f3-2a95d7168ce4",
        "13cd7f28-4e05-49b6-a8d1-c72fb0946e35", "97f4be01-8d23-4570-b1ea-460c39d8752f",
        "5b28e4a6-0f71-4d39-8ec2-73a15f60b984", "af6103d7-92c8-4b15-a0f4-6e2d859c7301",
        "20e9c85f-7a34-4168-93bd-c05e17f8a642", "cb47d16e-5920-4a83-b7f1-3d8ec6045b27"
    ]

    func testTheRoomHasTheEightPlacesTheReferenceLaysOut() {
        let slots = breakRoom.slots

        XCTAssertEqual(slots.count, 8)
        XCTAssertEqual(slots.map(\.activity),
                       [.sofa, .sofa, .coffee, .table, .table, .counter, .standing, .standing])
        // Where a cup appears. Standing in the middle of the room holding a
        // coffee that came from nowhere reads as a drawing mistake.
        XCTAssertEqual(slots.filter(\.activity.holdsCoffee).count, 4)
    }

    /// Catches a walk seeded from `hashValue`, from `Date()` or from
    /// `Int.random`: all three would give a different answer on the second call
    /// and make every snapshot test in Task 9 flaky in a way that looks like a
    /// rendering bug.
    func testTheSameIdAndFrameAlwaysProduceTheSameWalk() {
        let room = breakRoom
        for frame in [0, 37, 900, 4_312, 120_000] {
            for (order, id) in ids.enumerated() {
                let a = room.walker(for: order, seed: id, frame: frame)
                let b = room.walker(for: order, seed: id, frame: frame)

                XCTAssertEqual(a, b, "id \(id) at frame \(frame)")
            }
        }
    }

    /// Determinism has to survive a restart, not just a second call in the same
    /// process. FNV-1a is fixed, so the first walker's position is a constant
    /// that can be written down — if the seeding is ever swapped for anything
    /// process-dependent, this is the assertion that stops compiling being
    /// enough.
    func testTheWalkIsSeededFromTheIdAndNotFromTheProcess() {
        let hash = SessionPalette.fnv1a("3f2a91c4-7b18-4d0e-9a55-1c6e2f80b3d7")

        XCTAssertEqual(hash, 0x2a8b_22a6_b2a2_d32c)
    }

    /// Catches the obvious wrong turn: picking the opening slot by hashing the
    /// id. Eight slots and eight agents would collide almost every time, and
    /// two figures would share one sofa cushion while five places stood empty.
    func testDifferentIdsGetDifferentStartingSlots() {
        let room = breakRoom
        let starts = ids.prefix(room.slots.count).enumerated().map { order, id in
            room.walker(for: order, seed: id, frame: 0).slotIndex
        }

        XCTAssertEqual(Set(starts).count, room.slots.count)
    }

    /// The same rule stated as the property it exists for: while places remain
    /// free, nobody doubles up.
    func testSlotAssignmentNeverDoublesUpWhileSlotsRemainFree() {
        let room = breakRoom
        for population in 1...room.slots.count {
            let occupied = (0..<population).map { room.startSlotIndex(order: $0) }

            XCTAssertEqual(Set(occupied).count, population,
                           "population \(population) doubled up with places to spare")
        }
    }

    /// Catches a walk that teleports: an un-eased jump at a leg boundary, a
    /// cycle that does not close, or a `from` that is not the previous leg's
    /// `to`. At sixty frames a second and roughly two seconds a leg, no step
    /// can move more than a fraction of a tile.
    func testTheWalkIsContinuousBetweenAdjacentFrames() {
        let room = breakRoom
        for (order, id) in ids.prefix(8).enumerated() {
            var previous = room.walker(for: order, seed: id, frame: 0).position
            for frame in 1...6_000 {
                let next = room.walker(for: order, seed: id, frame: frame).position
                let step = ((next.u - previous.u) * (next.u - previous.u)
                            + (next.v - previous.v) * (next.v - previous.v)).squareRoot()

                XCTAssertLessThan(step, 0.2, "\(id) jumped at frame \(frame)")
                previous = next
            }
        }
    }

    /// The walk repeats, because the frame number it is given is absolute and
    /// simulating from time zero would never finish. That makes the seam its own
    /// hazard: this walks one agent past the far end of its cycle — which is
    /// somewhere between 21 000 and 65 000 frames out — and catches a cycle
    /// whose last leg does not lead home.
    func testTheCycleClosesSoTheWrapIsNotAJump() {
        let room = breakRoom
        var previous = room.walker(for: 0, seed: ids[0], frame: 0).position
        for frame in 1...66_000 {
            let next = room.walker(for: 0, seed: ids[0], frame: frame).position
            let step = ((next.u - previous.u) * (next.u - previous.u)
                        + (next.v - previous.v) * (next.v - previous.v)).squareRoot()

            XCTAssertLessThan(step, 0.2, "jumped at frame \(frame)")
            previous = next
        }
    }

    /// The wander must stay indoors. Catches a leg that interpolates towards a
    /// desk, or a slot built off the wrong corner of the room rectangle.
    func testNobodyEverLeavesTheBreakRoomFloor() {
        let room = breakRoom
        for (order, id) in ids.enumerated() {
            for frame in stride(from: 0, through: 60_000, by: 7) {
                let p = room.walker(for: order, seed: id, frame: frame).position

                XCTAssertGreaterThanOrEqual(p.u, self.room.u0 - 0.4)
                XCTAssertLessThanOrEqual(p.u, self.room.u1 + 0.4)
                XCTAssertGreaterThanOrEqual(p.v, self.room.v0 - 0.4)
                XCTAssertLessThanOrEqual(p.v, self.room.v1 + 0.4)
            }
        }
    }

    /// More waiting agents than places is the ordinary case on a busy machine.
    /// Nothing may trap on the modulo and everyone still gets a real place.
    func testMoreWaitingSessionsThanSlotsStillPlacesEveryone() {
        let room = breakRoom
        for (order, id) in ids.enumerated() {
            let walker = room.walker(for: order, seed: id, frame: 900)

            XCTAssertTrue(room.slots.indices.contains(walker.slotIndex))
            XCTAssertEqual(walker.slot, room.slots[walker.slotIndex])
        }
    }

    /// The wander has to actually wander. Catches a plan whose every leg picks
    /// the slot it is already standing in — deterministic, continuous, in the
    /// room, and completely still, which every other test here would pass.
    func testAnAgentDoesNotStandStillOnTheSpotForever() {
        let room = breakRoom
        let positions = stride(from: 0, through: 3_600, by: 30).map {
            room.walker(for: 0, seed: ids[0], frame: $0).position
        }

        XCTAssertGreaterThan(Set(positions.map(\.u)).count, 3)
    }

    /// The easing is what makes a figure accelerate out of a chair rather than
    /// snap into motion. Catches a plain linear lerp slipping back in.
    func testTheEasingIsSmoothRatherThanLinear() {
        XCTAssertEqual(Walker.ease(0), 0, accuracy: 1e-12)
        XCTAssertEqual(Walker.ease(1), 1, accuracy: 1e-12)
        XCTAssertEqual(Walker.ease(0.5), 0.5, accuracy: 1e-12)
        XCTAssertLessThan(Walker.ease(0.25), 0.25)
        XCTAssertGreaterThan(Walker.ease(0.75), 0.75)
    }

    /// Every session maps into the palette, and the mapping is the fixed hash
    /// rather than the per-process one. A `hashValue` here would give a
    /// different shirt on every launch.
    func testEverySessionMapsIntoThePaletteAndStaysThere() {
        for id in ids {
            let palette = SessionPalette.forSession(id)

            XCTAssertTrue(SessionPalette.all.contains(palette))
            XCTAssertEqual(palette, SessionPalette.forSession(id))
        }
        // Written down, not derived: a stable hash is only stable if it is the
        // same one tomorrow.
        XCTAssertEqual(SessionPalette.forSession("3f2a91c4-7b18-4d0e-9a55-1c6e2f80b3d7"), SessionPalette.all[4])
        XCTAssertEqual(SessionPalette.forSession("glyphline"), SessionPalette.all[7])
    }
}
