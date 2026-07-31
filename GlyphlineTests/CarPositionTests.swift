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

    /// Parked cars are spread along the pit lane rather than stacked at its
    /// mouth, and none of them straddles the entry or the exit.
    func testPitSlotsAreEvenlySpacedAndInsetFromBothEnds() {
        let slots = (0 ..< 4).map { CarPosition.pitSlot(index: $0, count: 4) }

        XCTAssertEqual(slots, [0.125, 0.375, 0.625, 0.875])
        XCTAssertTrue(slots.allSatisfy { $0 > 0 && $0 < 1 })
    }

    func testASinglePitSlotSitsInTheMiddle() {
        XCTAssertEqual(CarPosition.pitSlot(index: 0, count: 1), 0.5, accuracy: 0.0001)
    }
}
