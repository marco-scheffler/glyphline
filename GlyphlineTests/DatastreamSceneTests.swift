import XCTest
@testable import Glyphline

/// The datastream, asserted where it can be asserted: the lane geometry and the
/// motion, both of which are pure functions of a session id and a frame number.
///
/// Every test here names the production change it would catch, and each of those
/// changes was injected and confirmed to turn the test red before it was left in.
/// The drawing itself is not asserted here — Task 9's rendered bytes cover that —
/// but everything the drawing reads from is.
final class DatastreamSceneTests: XCTestCase {
    private static let canvas = CGSize(width: 1300, height: 640)

    private func lane(_ id: String,
                      state: DatastreamState = .working,
                      subagents: Int = 12,
                      tokens: Int64 = 20_000_000) -> DatastreamLane {
        DatastreamLane(id: id, name: "project", repository: "project", state: state,
                       subagentCount: subagents, workTokens: tokens)
    }

    private func stream(_ lane: DatastreamLane,
                        index: Int = 0,
                        laneCount: Int = 7) -> DatastreamStream {
        DatastreamStream(lane: lane,
                         index: index,
                         layout: DatastreamLayout(canvas: Self.canvas, laneCount: laneCount))
    }

    // MARK: - Lane geometry

    /// Would catch: a gutter between lanes, a lane width that leaves the last
    /// lane short of the right edge, or an off-by-one in the divisor. Injecting
    /// `laneWidth = canvas.width / Double(laneCount + 1)` fails the tiling at
    /// every one of the seventeen counts.
    func testLanesTileTheCanvasWithoutGapOrOverlap() {
        for count in 4...20 {
            let layout = DatastreamLayout(canvas: Self.canvas, laneCount: count)
            XCTAssertEqual(layout.laneX(0), 0, accuracy: 1e-9,
                           "lane 0 must start at the left edge, \(count) sessions")
            for index in 0..<count {
                XCTAssertEqual(layout.laneX(index) + layout.laneWidth,
                               layout.laneX(index + 1),
                               accuracy: 1e-9,
                               "lane \(index) must end exactly where \(index + 1) starts, \(count) sessions")
            }
            XCTAssertEqual(layout.laneX(count - 1) + layout.laneWidth,
                           Self.canvas.width,
                           accuracy: 1e-9,
                           "the last lane must reach the right edge, \(count) sessions")
        }
    }

    /// Would catch: a lane's columns escaping their own lane. Injecting the
    /// reference's `laneW - 20` spread without the `+ 10` inset puts the last
    /// column of every lane on its neighbour's boundary.
    func testColumnsStayInsideTheirOwnLane() {
        let layout = DatastreamLayout(canvas: Self.canvas, laneCount: 9)
        for index in 0..<9 {
            let stream = DatastreamStream(lane: lane("session-\(index)"),
                                          index: index,
                                          layout: layout)
            for column in stream.columns(at: 4_800_000_000) {
                XCTAssertGreaterThan(column.x, layout.laneX(index))
                XCTAssertLessThan(column.x, layout.laneX(index + 1))
            }
        }
    }

    // MARK: - Header titles cut to a width, not to a character count

    /// A stand-in for the header's text metrics, monotone in the prefix length
    /// exactly as the real one is. The rule under test is the fitting, not the
    /// font — 11 pt monospaced runs about 6.6 pt per character.
    private func measure(_ text: String) -> Double { Double(text.count) * 6.6 }

    private func renderer(_ layout: DatastreamLayout) -> DatastreamRenderer {
        DatastreamRenderer(layout: layout, frame: 0, hovered: nil)
    }

    private static let panes = [CGSize(width: 1300, height: 640),
                                CGSize(width: 900, height: 560),
                                CGSize(width: 640, height: 480),
                                CGSize(width: 420, height: 320)]

    /// The whole point of the fix, and the property a character count cannot
    /// hold: a lane is the pane divided by the session count, so the same 22
    /// characters that fit at 1300 by 4 overflow at 420 by 20.
    ///
    /// Would catch: the old `SessionLabel.laneLimit` coming back. Injecting
    /// `String(title.prefix(21)) + "…"` in place of the fitter fails at every
    /// pane from nine lanes up.
    func testNoLaneHeaderIsWiderThanItsLane() {
        let title = "Issue 558 auf Umstellung des Agentverse in die zweite Ansicht"
        for pane in Self.panes {
            for count in 4...20 {
                let layout = DatastreamLayout(canvas: pane, laneCount: count)
                XCTAssertLessThanOrEqual(layout.laneTextWidth, layout.laneWidth,
                                         "pane \(pane) count \(count)")
                let fitted = renderer(layout).fittedName(title, measure: measure)
                XCTAssertLessThanOrEqual(
                    measure(fitted), layout.laneTextWidth,
                    "pane \(pane) count \(count): \"\(fitted)\" measures "
                        + "\(measure(fitted)) in a \(layout.laneTextWidth) lane")
            }
        }
    }

    /// Would catch: a fitter that returns the text unchanged, or one that drops
    /// the ellipsis so a cut title reads as the whole one.
    func testATitleLongerThanTheLaneIsCutAndSaysSo() {
        let title = "PR 3 fortsetzen: Datastream-Spuren beschriften und messen"
        let layout = DatastreamLayout(canvas: Self.canvas, laneCount: 9)
        let fitted = renderer(layout).fittedName(title, measure: measure)

        XCTAssertTrue(fitted.hasSuffix("…"), fitted)
        XCTAssertTrue(title.hasPrefix(String(fitted.dropLast())), fitted)
        XCTAssertLessThanOrEqual(measure(fitted), layout.laneTextWidth)
        // And it uses the lane it has: one character more would not fit.
        XCTAssertGreaterThan(measure(fitted + "x"), layout.laneTextWidth, fitted)
    }

    /// A rule that truncates everything is as wrong as one that truncates
    /// nothing. Would catch: cutting unconditionally instead of measuring first.
    func testAShortTitleIsLeftAlone() {
        let layout = DatastreamLayout(canvas: Self.canvas, laneCount: 4)
        for title in ["glyphline", "Issue 558", "a"] {
            XCTAssertEqual(renderer(layout).fittedName(title, measure: measure), title)
        }
    }

    // MARK: - Header captions cut the same way

    /// The caption is drawn at 9.5 pt where the name is drawn at 11 pt, so it
    /// gets its own metric — a stand-in for the smaller font, monotone in the
    /// prefix length as the real one is.
    private func captionMeasure(_ text: String) -> Double { Double(text.count) * 5.7 }

    /// The caption sits in the same lane as the name and so is bound by the same
    /// width. It was left out when the name was moved onto the fitter.
    ///
    /// Would catch: the caption going back to being drawn unfitted. With
    /// `lane.caption` passed straight through, the branch-and-model line
    /// overflows its lane from nine lanes up at every pane below.
    func testNoLaneCaptionIsWiderThanItsLane() {
        let caption = "feature/agentverse-datastream-lane-labels  claude-opus-4-6"
        for pane in Self.panes {
            for count in 4...20 {
                let layout = DatastreamLayout(canvas: pane, laneCount: count)
                let fitted = renderer(layout).fittedCaption(caption, measure: captionMeasure)
                XCTAssertLessThanOrEqual(
                    captionMeasure(fitted), layout.laneTextWidth,
                    "pane \(pane) count \(count): \"\(fitted)\" measures "
                        + "\(captionMeasure(fitted)) in a \(layout.laneTextWidth) lane")
            }
        }
    }

    /// Would catch: a caption fitter that returns the text unchanged, or one
    /// that drops the ellipsis so a cut caption reads as the whole one.
    func testACaptionLongerThanTheLaneIsCutAndSaysSo() {
        let caption = "feature/datastream-caption-fitting  claude-sonnet-5"
        let layout = DatastreamLayout(canvas: Self.canvas, laneCount: 9)
        let fitted = renderer(layout).fittedCaption(caption, measure: captionMeasure)

        XCTAssertTrue(fitted.hasSuffix("…"), fitted)
        XCTAssertTrue(caption.hasPrefix(String(fitted.dropLast())), fitted)
        XCTAssertLessThanOrEqual(captionMeasure(fitted), layout.laneTextWidth)
        XCTAssertGreaterThan(captionMeasure(fitted + "x"), layout.laneTextWidth, fitted)
    }

    /// A rule that truncates everything is as wrong as one that truncates
    /// nothing. Would catch: cutting unconditionally instead of measuring first.
    func testAShortCaptionIsLeftAlone() {
        let layout = DatastreamLayout(canvas: Self.canvas, laneCount: 4)
        for caption in ["main", "main  opus", "—"] {
            XCTAssertEqual(renderer(layout).fittedCaption(caption, measure: captionMeasure),
                           caption)
        }
    }

    // Not asserted: that the caption is measured with the caption's *font*
    // rather than the name's. The font is chosen where the string is drawn, in
    // `GraphicsContext`, and the measurement is a closure the caller supplies —
    // so any test hands in its own metrics and would only be checking its own
    // stub. The name's fit has had the same gap since it was extracted.

    // MARK: - Determinism

    /// Would catch: a lane seeded from anything other than its session id, and
    /// a lane that is not a pure function of the frame. Injecting
    /// `LinearGenerator(seed: "constant")` makes every lane fall identically and
    /// fails the second half; injecting an accumulating `y` fails the first,
    /// because the second call carries on where the first stopped.
    ///
    /// It cannot catch `hashValue` on its own — that is deterministic *within*
    /// one process, and only a second process would see it move. The guard
    /// against that is `SessionPalette.fnv1a` being the only id hash there is.
    func testColumnsAreDeterministicFromTheSessionID() {
        let frame = 4_800_000_017
        let first = stream(lane("a-session-id")).columns(at: frame)
        let second = stream(lane("a-session-id")).columns(at: frame)
        XCTAssertEqual(first, second, "same id, same frame, same columns")

        let other = stream(lane("a-different-session-id")).columns(at: frame)
        XCTAssertNotEqual(first.map(\.y), other.map(\.y),
                          "a different id must fall differently")
    }

    /// Would catch: a scene that accumulates instead of computing. Injecting a
    /// stored `y` stepped once per call makes the two calls disagree, because
    /// the second one starts where the first stopped.
    func testTributariesAndBurstsAreDeterministicFromTheSessionID() {
        let frame = 4_800_000_231
        let a = stream(lane("tributary-seed", subagents: 54))
        let b = stream(lane("tributary-seed", subagents: 54))
        XCTAssertEqual(a.tributaries, b.tributaries)
        XCTAssertEqual(a.burst(at: frame)?.y, b.burst(at: frame)?.y)
    }

    /// Would catch: subagent counts that do not become tributaries — a fixed
    /// count, or a count that ignores the eight-helpers-per-stream rule.
    func testSubagentCountsBecomeTributaries() {
        XCTAssertEqual(stream(lane("trickle", subagents: 3)).tributaries.count, 0)
        XCTAssertEqual(stream(lane("small", subagents: 8)).tributaries.count, 1)
        XCTAssertEqual(stream(lane("middling", subagents: 12)).tributaries.count, 2)
        XCTAssertEqual(stream(lane("braided", subagents: 54)).tributaries.count, 7)
        // The reference caps at seven; without the cap this would be 12.
        XCTAssertEqual(stream(lane("flood", subagents: 99)).tributaries.count, 7)
    }

    // MARK: - The three states

    /// Would catch: a waiting lane that keeps falling. Injecting the working
    /// branch for `.waiting` — dropping the freeze — makes the two frames
    /// differ, and the amber lane would read as a working one.
    func testAWaitingLaneFreezesAndAWorkingLaneDoesNot() {
        let frame = 4_800_000_000
        let waiting = stream(lane("frozen", state: .waiting))
        XCTAssertEqual(waiting.columns(at: frame), waiting.columns(at: frame + 1),
                       "a waiting lane must not advance between adjacent frames")

        let working = stream(lane("frozen", state: .working))
        XCTAssertNotEqual(working.columns(at: frame).map(\.y),
                          working.columns(at: frame + 1).map(\.y),
                          "a working lane must advance between adjacent frames")
    }

    /// Would catch: a parked lane running at full speed. Injecting a parked
    /// factor of 1 instead of the reference's 0.20 makes the two advances equal.
    func testParkedLanesAdvanceMoreSlowlyThanWorkingOnes() {
        let frame = 4_800_000_000
        let parked = stream(lane("same-seed", state: .parked))
        let working = stream(lane("same-seed", state: .working))

        for index in 0..<working.columns(at: frame).count {
            let parkedStep = parked.columns(at: frame + 1)[index].y
                - parked.columns(at: frame)[index].y
            let workingStep = working.columns(at: frame + 1)[index].y
                - working.columns(at: frame)[index].y
            XCTAssertGreaterThan(parkedStep, 0, "a parked lane still creeps")
            XCTAssertLessThan(parkedStep, workingStep,
                              "column \(index) must creep rather than run")
        }
    }

    // MARK: - Bursts and the collector

    /// Would catch: a burst that is simulated rather than cycled, and so runs
    /// off the bottom of the canvas instead of resetting. Injecting the open
    /// form — `y = -30 + speed * Double(frame)` without the cycle — puts the
    /// block millions of points below the floor at the very first sample.
    func testABurstReachesTheCollectorAndResets() {
        let stream = stream(lane("burst-seed"))
        let floor = DatastreamLayout(canvas: Self.canvas, laneCount: 7).floorY

        var arrivals = 0
        var deepest = -Double.infinity
        var wasFalling = false
        for frame in 4_800_000_000..<4_800_006_000 {
            guard let burst = stream.burst(at: frame) else {
                // The block vanished: it has landed on the collector, which is
                // the only way a run is allowed to end.
                if wasFalling { arrivals += 1 }
                wasFalling = false
                continue
            }
            XCTAssertLessThanOrEqual(burst.y, floor,
                                     "a burst must never pass the collector at frame \(frame)")
            deepest = max(deepest, burst.y)
            wasFalling = true
        }
        XCTAssertGreaterThan(arrivals, 5, "the burst must reset and run again")
        XCTAssertGreaterThan(deepest, floor - 30,
                             "the burst must actually arrive at the collector")
    }

    /// Would catch: a waiting lane whose collector keeps flashing. The absence
    /// of the flash is the signal, so injecting the working branch for
    /// `.waiting` — a collector that lights regardless of state — is precisely
    /// the bug that erases it.
    func testAWaitingCollectorStaysDarkWhileAWorkingOneFlashes() {
        let waiting = stream(lane("dark-lane", state: .waiting))
        let parked = stream(lane("dark-lane", state: .parked))
        let working = stream(lane("dark-lane", state: .working))

        var workingFlashes = 0
        for frame in 4_800_000_000..<4_800_001_200 {
            XCTAssertNil(waiting.burst(at: frame))
            XCTAssertEqual(waiting.collectorGlow(at: frame), 0,
                           "a waiting collector must stay dark at frame \(frame)")
            XCTAssertEqual(parked.collectorGlow(at: frame), 0,
                           "a parked collector must stay dark at frame \(frame)")
            if working.collectorGlow(at: frame) > 0 { workingFlashes += 1 }
        }
        XCTAssertGreaterThan(workingFlashes, 0, "a working collector must flare")
    }

    // MARK: - One fixed flow rate

    /// The point of the fixed flow rate, asserted so the old inference cannot
    /// creep back: cumulative worked tokens say how long a session has been
    /// around, not how hard it is going, so they must not reach the motion at
    /// all. Two working lanes with the same id and wildly different totals must
    /// fall, churn and fire identically.
    ///
    /// Would catch: any of the three downstream uses of the removed `rate`
    /// coming back. Injecting `speed * stateFactor * (0.55 + tokenRate)` fails
    /// the columns, `5.5 + tokenRate * 5` fails the burst speed and travel, and
    /// `(0.15 + tokenRate * 0.6)` fails the glyphs — each on its own.
    func testTwoWorkingLanesWithVeryDifferentTokenTotalsAdvanceIdentically() {
        let frame = 4_800_000_053
        let busy = stream(lane("flow-seed", tokens: 400_000_000))
        let quiet = stream(lane("flow-seed", tokens: 12_000))

        XCTAssertEqual(busy.columns(at: frame), quiet.columns(at: frame),
                       "token totals must not reach the fall")
        XCTAssertEqual(busy.columns(at: frame + 1).map(\.y),
                       quiet.columns(at: frame + 1).map(\.y),
                       "nor the step between two frames")
        XCTAssertEqual(busy.burstSpeed, quiet.burstSpeed, accuracy: 1e-12,
                       "nor the burst speed")
        XCTAssertEqual(busy.burst(at: frame)?.y, quiet.burst(at: frame)?.y,
                       "nor where the block is on its run")
        for row in 0..<24 {
            XCTAssertEqual(busy.glyph(column: 0, row: row, frame: frame),
                           quiet.glyph(column: 0, row: row, frame: frame),
                           "nor the glyph churn at row \(row)")
        }
    }

    /// Would catch: a flow rate that is no longer one constant — a lane that
    /// reads it from anywhere at all. The three lanes below differ in every
    /// input the old `rate` was derived from.
    func testEveryWorkingLaneRunsAtTheSameFlowRate() {
        let frame = 4_800_000_000
        let speeds = [Int64(0), 5_000_000, 40_000_000, 900_000_000].map { tokens in
            let a = stream(lane("uniform-seed", tokens: tokens))
            return a.columns(at: frame + 1)[0].y - a.columns(at: frame)[0].y
        }
        for speed in speeds {
            XCTAssertEqual(speed, speeds[0], accuracy: 1e-12,
                           "every working lane falls at the one fixed rate")
        }
    }
}
