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

    func testASessionWithNoTokensHasNoCompletedLap() {
        XCTAssertEqual(CarPosition.lapCount(workTokens: 0, tokensPerLap: 1_000_000), 0)
    }

    /// The place on the circuit is the clock, not the odometer. A car that has
    /// been driving for a whole lap time is back where it started.
    func testAWorkingCarCoversALapInTheLapTime() {
        let start = CarPosition.lapFraction(frame: 0, startOffset: 0,
                                            framesPerSecond: 60, secondsPerLap: 45)
        let quarter = CarPosition.lapFraction(frame: 675, startOffset: 0,
                                              framesPerSecond: 60, secondsPerLap: 45)
        let full = CarPosition.lapFraction(frame: 2700, startOffset: 0,
                                           framesPerSecond: 60, secondsPerLap: 45)

        XCTAssertEqual(start, 0, accuracy: 0.0001)
        XCTAssertEqual(quarter, 0.25, accuracy: 0.0001)
        XCTAssertEqual(full, 0, accuracy: 0.0001)
    }

    /// A lap in the region of half a minute: fast enough that a glance catches
    /// movement, slow enough that the field stays readable.
    func testALapTakesFortyFiveSeconds() {
        XCTAssertEqual(CarPosition.secondsPerLap, 45)
        XCTAssertEqual(CarPosition.framesPerSecond, 60)
    }

    /// The offset moves the car round the lap without changing its speed.
    func testTheStartOffsetShiftsTheCarRoundTheLap() {
        XCTAssertEqual(CarPosition.lapFraction(frame: 0, startOffset: 0.3),
                       0.3, accuracy: 0.0001)
        XCTAssertEqual(CarPosition.lapFraction(frame: 675, startOffset: 0.9,
                                               framesPerSecond: 60, secondsPerLap: 45),
                       0.15, accuracy: 0.0001,
                       "past the line the lap wraps rather than running past 1")
    }

    /// Whatever the frame, the fraction has to be one `pointIndex` can use.
    func testEveryFrameYieldsAFractionInsideTheLap() {
        for frame in stride(from: 0, to: 20_000, by: 137) {
            let fraction = CarPosition.lapFraction(frame: frame, startOffset: 0.77)
            XCTAssertTrue((0 ..< 1).contains(fraction), "frame \(frame) left the lap")
        }
    }

    /// A zero lap time is a broken constant, not a division by zero.
    func testAZeroLapTimeLeavesTheCarAtItsOffset() {
        XCTAssertEqual(CarPosition.lapFraction(frame: 900, startOffset: 0.4,
                                               framesPerSecond: 60, secondsPerLap: 0),
                       0.4, accuracy: 0.0001)
    }

    /// The same session keeps its place in the field across launches, which
    /// `hashValue` — seeded per process — could not promise.
    func testTheStartOffsetIsStableForASession() {
        XCTAssertEqual(CarPosition.startOffset(sessionID: "019fa0ad-422e-79e0-b0d5-c4605371f1d2"),
                       CarPosition.startOffset(sessionID: "019fa0ad-422e-79e0-b0d5-c4605371f1d2"))
    }

    /// The whole point of the offset: cars must not be stacked on one another.
    func testTheStartOffsetSpreadsTheField() {
        let offsets = (0 ..< 200).map { CarPosition.startOffset(sessionID: "session-\($0)") }

        XCTAssertTrue(offsets.allSatisfy { $0 >= 0 && $0 < 1 })
        XCTAssertGreaterThan(Set(offsets).count, 150,
                             "the hash is collapsing distinct sessions onto one place")
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

    /// A circuit with known geometry, so a heading can be asserted rather than
    /// eyeballed. `spanX`/`spanY` are what `CircuitFit` scales against.
    private func testCircuit(points: [[Double]]) -> Circuit {
        Circuit(name: "Test", location: nil, tz: "UTC", lengthKm: 1,
                lat: 0, lon: 0, rot: 0,
                minX: 0, minY: 0, spanX: 100, spanY: 100,
                startIdx: 0, points: points, pit: [])
    }

    private func testFit(_ circuit: Circuit) -> CircuitFit {
        CircuitFit(circuit: circuit, in: CGSize(width: 200, height: 200))
    }

    func testAHeadingRunsAlongTheDirectionOfTravel() {
        let circuit = testCircuit(points: [[0, 0], [10, 0], [20, 0]])
        let heading = CarPosition.heading(points: circuit.points, index: 1,
                                          closed: false, fit: testFit(circuit))

        XCTAssertEqual(try XCTUnwrap(heading), 0, accuracy: 0.0001)
    }

    /// The heading agrees with where `CircuitFit` actually puts the points.
    ///
    /// It does not, today, tell screen space from metre space: `CircuitFit` is a
    /// uniform positive similarity transform — one `min()` scale for both axes,
    /// plus a translation — and `atan2` is invariant under that, so a metre-space
    /// implementation returns the identical angle and passes this. The axes
    /// cannot be forced apart either; keeping the aspect ratio is the whole point
    /// of that `min()`. This test becomes load-bearing the day the fit gains a
    /// flip or a per-axis scale, which is exactly when the guarantee starts to
    /// matter.
    func testAHeadingAgreesWithTheFittedPoints() throws {
        let circuit = testCircuit(points: [[0, 0], [0, 10], [0, 20]])
        let heading = try XCTUnwrap(
            CarPosition.heading(points: circuit.points, index: 1,
                                closed: false, fit: testFit(circuit))
        )
        let a = testFit(circuit).point([0, 0])
        let b = testFit(circuit).point([0, 20])

        XCTAssertEqual(heading, atan2(b.y - a.y, b.x - a.x), accuracy: 0.0001)
    }

    /// The centreline is a closed loop; the first point's predecessor is the
    /// last. Without the wrap a car at the start/finish line — which is where
    /// every car with no completed lap stands — would have no heading at all.
    func testAClosedLineWrapsAtBothEnds() throws {
        let circuit = testCircuit(points: [[0, 0], [10, 0], [10, 10], [0, 10]])
        let fit = testFit(circuit)

        let first = try XCTUnwrap(CarPosition.heading(points: circuit.points, index: 0,
                                                      closed: true, fit: fit))
        let last = try XCTUnwrap(CarPosition.heading(points: circuit.points, index: 3,
                                                     closed: true, fit: fit))

        // Index 0's neighbours are 3 and 1; index 3's are 2 and 0.
        XCTAssertEqual(first, atan2(fit.point([10, 0]).y - fit.point([0, 10]).y,
                                    fit.point([10, 0]).x - fit.point([0, 10]).x),
                       accuracy: 0.0001)
        XCTAssertEqual(last, atan2(fit.point([0, 0]).y - fit.point([10, 10]).y,
                                   fit.point([0, 0]).x - fit.point([10, 10]).x),
                       accuracy: 0.0001)
    }

    /// The pit lane has an entry and an exit, so its ends clamp rather than wrap.
    ///
    /// Its two ends fail differently, so they are pinned separately. Without the
    /// clamp the entry reads `points[-1]` — a trap on the way in.
    func testAnOpenLineClampsAtItsEntry() throws {
        let circuit = testCircuit(points: [[0, 0], [10, 0], [20, 0]])
        let fit = testFit(circuit)

        let first = try XCTUnwrap(CarPosition.heading(points: circuit.points, index: 0,
                                                      closed: false, fit: fit))

        XCTAssertEqual(first, 0, accuracy: 0.0001)
    }

    /// The other end, and the one that matters most: without the clamp the exit
    /// subscripts one past the last point and traps — verified by deleting the
    /// clamp, which turns this into `Fatal error: Index out of range`. A parked
    /// car stands at the exit, so this is a live path rather than a corner case.
    func testAnOpenLineClampsAtItsExit() throws {
        let circuit = testCircuit(points: [[0, 0], [10, 0], [20, 0]])
        let fit = testFit(circuit)

        let last = try XCTUnwrap(CarPosition.heading(points: circuit.points, index: 2,
                                                     closed: false, fit: fit))

        XCTAssertEqual(last, 0, accuracy: 0.0001)
    }

    func testTwoCoincidentNeighboursLeaveNoHeading() {
        let circuit = testCircuit(points: [[5, 5], [0, 0], [5, 5]])

        XCTAssertNil(CarPosition.heading(points: circuit.points, index: 1,
                                         closed: false, fit: testFit(circuit)))
    }

    func testAShortOrEmptyLineHasNoHeading() {
        let empty = testCircuit(points: [])
        let single = testCircuit(points: [[0, 0]])

        XCTAssertNil(CarPosition.heading(points: empty.points, index: 0,
                                         closed: true, fit: testFit(empty)))
        XCTAssertNil(CarPosition.heading(points: single.points, index: 0,
                                         closed: true, fit: testFit(single)))
        XCTAssertNil(CarPosition.heading(points: single.points, index: 7,
                                         closed: true, fit: testFit(single)))
    }
}
