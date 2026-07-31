import XCTest
@testable import Glyphline

final class CarPositionTests: XCTestCase {
    /// Measured against 309 real sessions: the median holds 2.46 M work tokens
    /// and the largest 413 M, so a smaller lap would print three-digit counts
    /// for the sessions actually on screen.
    func testALapIsAMillionWorkTokens() {
        XCTAssertEqual(CarPosition.tokensPerLap, 1_000_000)
    }

    func testTheLapCountIsWholeLapsOnly() {
        XCTAssertEqual(CarPosition.lapCount(workTokens: 2_600_000, tokensPerLap: 1_000_000), 2)
        XCTAssertEqual(CarPosition.lapCount(workTokens: 540_000, tokensPerLap: 1_000_000), 0)
    }

    /// A car with no complete lap still has a place on the circuit. Position is
    /// the fraction, not the count — a session showing zero laps is early, not
    /// stationary.
    func testPositionIsTheFractionOfALap() {
        XCTAssertEqual(
            CarPosition.lapFraction(workTokens: 2_600_000, tokensPerLap: 1_000_000),
            0.6, accuracy: 0.0001
        )
        XCTAssertEqual(
            CarPosition.lapFraction(workTokens: 540_000, tokensPerLap: 1_000_000),
            0.54, accuracy: 0.0001
        )
    }

    func testASessionWithNoTokensSitsAtTheLine() {
        XCTAssertEqual(CarPosition.lapFraction(workTokens: 0, tokensPerLap: 1_000_000), 0)
        XCTAssertEqual(CarPosition.lapCount(workTokens: 0, tokensPerLap: 1_000_000), 0)
    }

    /// The lap begins at the measured start/finish line, not at whatever point
    /// happens to be stored first: `startIdx` is 118 of 159 on Monaco and 167 of
    /// 171 at Suzuka, so reading `points[0]` puts a zero-lap car most of a lap
    /// from where it says it is.
    func testFractionZeroIsTheStartFinishLine() {
        XCTAssertEqual(CarPosition.pointIndex(fraction: 0, startIdx: 118, count: 159), 118)
        XCTAssertEqual(CarPosition.pointIndex(fraction: 0, startIdx: 0, count: 152), 0)
    }

    /// The end of a lap is the point *before* the line, so the wrap happens at
    /// the line and nowhere else. Catches both a missing modulo and a step
    /// counted one too far.
    func testAFractionJustUnderOneWrapsToThePointBeforeTheLine() {
        XCTAssertEqual(CarPosition.pointIndex(fraction: 0.999, startIdx: 118, count: 159), 117)
        XCTAssertEqual(CarPosition.pointIndex(fraction: 0.999, startIdx: 0, count: 152), 151)
        // Suzuka's line sits four points from the end of the stored geometry, so
        // anything past a quarter of a lap has to come round through zero.
        XCTAssertEqual(CarPosition.pointIndex(fraction: 0.5, startIdx: 167, count: 171), 81)
    }

    /// Whatever the fraction, the index has to address the array it is used to
    /// subscript — a car half a lap on from a late `startIdx` must not run off
    /// the end of `points`.
    func testEveryFractionLandsInsideTheCentreline() {
        for startIdx in [0, 1, 118, 120, 167] {
            for step in 0 ... 100 {
                let index = CarPosition.pointIndex(fraction: Double(step) / 100,
                                                   startIdx: startIdx, count: 171)
                XCTAssertTrue((0 ..< 171).contains(index),
                              "fraction \(Double(step) / 100) from \(startIdx) left the centreline")
            }
        }
    }

    /// A circuit with no geometry is a broken bundle, not a crash: the modulo
    /// would trap on a count of zero.
    func testAnEmptyCentrelineDoesNotTrap() {
        XCTAssertEqual(CarPosition.pointIndex(fraction: 0.4, startIdx: 0, count: 0), 0)
    }

    /// Parked cars are spread evenly along the pit lane rather than stacked at
    /// its mouth, and none of them straddles the entry or the exit. Asserted as
    /// the invariant across several counts: the four literals a single count
    /// produces are also produced by a formula that pins the first and last car
    /// to fixed insets and only spreads the ones between them.
    func testPitSlotsAreEvenlySpacedAndInsetFromBothEnds() {
        for count in [1, 2, 3, 4, 7] {
            let slots = (0 ..< count).map { CarPosition.pitSlot(index: $0, count: count) }

            XCTAssertTrue(slots.allSatisfy { $0 > 0 && $0 < 1 },
                          "\(count): a car sat on the pit entry or the exit")
            XCTAssertEqual(slots, slots.sorted(),
                           "\(count): the slots do not run down the lane in order")
            XCTAssertEqual(Set(slots).count, count, "\(count): two cars share a slot")

            let gaps = zip(slots, slots.dropFirst()).map { $1 - $0 }
            for gap in gaps {
                XCTAssertEqual(gap, gaps[0], accuracy: 0.0001,
                               "\(count): the cars are not evenly spaced")
            }
        }
    }

    func testNoParkedCarsAsksForNoSlotAtAll() {
        XCTAssertEqual(CarPosition.pitSlot(index: 0, count: 0), 0.5, accuracy: 0.0001)
    }

    /// Catches a pit index that no longer starts at the entry — an inset added
    /// here as well as in `pitSlot` would push the first car down the lane twice.
    func testTheStartOfTheLaneIsItsFirstPoint() {
        XCTAssertEqual(CarPosition.pitPointIndex(slot: 0, count: 24), 0)
    }

    /// Catches a dropped clamp: `Int(slot * count)` alone reaches `count` for a
    /// slot at the very end of the lane, one past the last stored point.
    func testASlotAtTheEndOfTheLaneStaysOnTheLastPoint() {
        XCTAssertEqual(CarPosition.pitPointIndex(slot: 0.999, count: 24), 23)
        XCTAssertEqual(CarPosition.pitPointIndex(slot: 1, count: 24), 23)
    }

    /// Catches a dropped emptiness guard: with no pit lane stored the clamp
    /// yields -1, and drawing a car at `pit[-1]` traps.
    func testACircuitWithoutAPitLaneOffersNoPoint() {
        XCTAssertNil(CarPosition.pitPointIndex(slot: 0.5, count: 0))
    }

    func testASinglePitSlotSitsInTheMiddle() {
        XCTAssertEqual(CarPosition.pitSlot(index: 0, count: 1), 0.5, accuracy: 0.0001)
    }
}
