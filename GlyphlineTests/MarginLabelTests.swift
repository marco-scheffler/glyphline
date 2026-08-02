import CoreGraphics
import Foundation
import XCTest
@testable import Glyphline

/// The labels used to sit on the desks, which meant they hid the very agents
/// they named. They are callouts in the pane's margin now, and the one property
/// that makes that worth doing is geometric: no plate may touch the room. So the
/// placement is a pure function and it is walked exhaustively, exactly as the fit
/// beside it is.
final class MarginLabelTests: XCTestCase {

    private let panes: [CGSize] = [
        CGSize(width: 800, height: 500),
        CGSize(width: 1300, height: 740),
        CGSize(width: 1720, height: 1020),
        CGSize(width: 900, height: 1200)
    ]

    /// Plates as wide as they can ever be — the layout is asked to clip them, so
    /// asking for far more than the column holds is the interesting case.
    private func requests(count: Int, layout: IsoLayout, pane: CGSize)
        -> [MarginLabelRequest] {
        (0..<count).map { i in
            let slot = layout.desks[i]
            let point = layout.projection.point(u: slot.u, v: slot.v + 0.42,
                                                h: 10 * layout.zoom)
            return MarginLabelRequest(id: "S\(i)",
                                      worker: CGPoint(x: point.x, y: point.y - 22),
                                      width: 400, height: 34 * max(0.86, layout.zoom))
        }
    }

    /// The whole point of the change. Caught by moving a plate back inside: with
    /// the left column's `x` set to `columnWidth + 40` instead of `padding`, this
    /// fails on every pane and count.
    func testNoLabelRectangleTouchesTheRoom() throws {
        for pane in panes {
            for count in 4...20 {
                let layout = IsoLayout.fit(sessionCount: count, canvas: pane)
                let labels = MarginLabelLayout.place(
                    requests(count: count, layout: layout, pane: pane),
                    canvas: pane,
                    columnWidth: layout.labelColumnWidth,
                    roomCentreX: layout.roomArea.midX)
                let what = "count \(count) pane \(pane)"
                XCTAssertFalse(labels.isEmpty, what)
                for label in labels {
                    XCTAssertFalse(label.rect.intersects(layout.bounds),
                                   "\(what): \(label.id) at \(label.rect) hits \(layout.bounds)")
                    // And it stays in its own column, not merely clear of the
                    // room: the room can be height-limited and leave slack the
                    // plate has no business using.
                    if label.column == .left {
                        XCTAssertLessThanOrEqual(label.rect.maxX, layout.labelColumnWidth, what)
                        XCTAssertGreaterThanOrEqual(label.rect.minX, 0, what)
                    } else {
                        XCTAssertGreaterThanOrEqual(
                            label.rect.minX, pane.width - layout.labelColumnWidth, what)
                        XCTAssertLessThanOrEqual(label.rect.maxX, pane.width, what)
                    }
                    XCTAssertGreaterThanOrEqual(label.rect.minY, 0, what)
                    XCTAssertLessThanOrEqual(label.rect.maxY, pane.height, what)
                }
            }
        }
    }

    /// Caught by dropping the downward separation sweep: without it the plates
    /// pile onto their workers' own heights and overlap.
    func testLabelsInAColumnNeverOverlapEachOther() throws {
        for pane in panes {
            for count in 4...20 {
                let layout = IsoLayout.fit(sessionCount: count, canvas: pane)
                let labels = MarginLabelLayout.place(
                    requests(count: count, layout: layout, pane: pane),
                    canvas: pane,
                    columnWidth: layout.labelColumnWidth,
                    roomCentreX: layout.roomArea.midX)
                for column in [MarginColumn.left, .right] {
                    let inColumn = labels.filter { $0.column == column }
                    for i in inColumn.indices {
                        for j in (i + 1)..<inColumn.count {
                            XCTAssertFalse(
                                inColumn[i].rect.intersects(inColumn[j].rect),
                                "count \(count) pane \(pane): \(inColumn[i].id) over "
                                    + "\(inColumn[j].id)")
                        }
                    }
                }
            }
        }
    }

    /// Ordered by the screen height of the thing each one points at, so the
    /// leader lines run roughly parallel instead of crossing.
    func testAColumnIsStackedInTheOrderOfItsWorkersHeights() throws {
        let pane = CGSize(width: 1300, height: 740)
        let layout = IsoLayout.fit(sessionCount: 16, canvas: pane)
        let labels = MarginLabelLayout.place(
            requests(count: 16, layout: layout, pane: pane),
            canvas: pane,
            columnWidth: layout.labelColumnWidth,
            roomCentreX: layout.roomArea.midX)
        for column in [MarginColumn.left, .right] {
            let inColumn = labels.filter { $0.column == column }
            let byWorker = inColumn.sorted { $0.worker.y < $1.worker.y }
            let byPlate = inColumn.sorted { $0.rect.minY < $1.rect.minY }
            XCTAssertEqual(byWorker.map(\.id), byPlate.map(\.id), "\(column)")
        }
    }

    /// Each plate to its nearer margin, and neither column left carrying the
    /// whole room. Caught by dropping the `cap` clamp in `split`: twenty desks
    /// whose workers all project left of centre then all land in one column.
    func testEachLabelGoesToTheNearerMarginAndTheColumnsStayBalanced() throws {
        let pane = CGSize(width: 1300, height: 740)
        let layout = IsoLayout.fit(sessionCount: 20, canvas: pane)
        let items = requests(count: 20, layout: layout, pane: pane)
        let labels = MarginLabelLayout.place(items, canvas: pane,
                                             columnWidth: layout.labelColumnWidth,
                                             roomCentreX: layout.roomArea.midX)
        let left = labels.filter { $0.column == .left }
        let right = labels.filter { $0.column == .right }
        XCTAssertLessThanOrEqual(abs(left.count - right.count), 1)
        // Monotone in x: nothing in the left column stands to the right of
        // anything in the right column.
        let leftMax = left.map(\.worker.x).max() ?? -.infinity
        let rightMin = right.map(\.worker.x).min() ?? .infinity
        XCTAssertLessThanOrEqual(leftMax, rightMin)
    }

    /// A short pane cannot hold ten plates a side. The overflow is dropped
    /// rather than pushed off the bottom of the window — a label half off-screen
    /// names nobody. Caught by removing the capacity clip: the last plates then
    /// leave the pane.
    func testAColumnThatRunsOutOfRoomDropsTheOverflowInsteadOfOverflowing() throws {
        let pane = CGSize(width: 1000, height: 240)
        let layout = IsoLayout.fit(sessionCount: 20, canvas: pane)
        let labels = MarginLabelLayout.place(
            requests(count: 20, layout: layout, pane: pane),
            canvas: pane,
            columnWidth: layout.labelColumnWidth,
            roomCentreX: layout.roomArea.midX)
        XCTAssertLessThan(labels.count, 20, "the short pane cannot hold them all")
        XCTAssertGreaterThan(labels.count, 0)
        for label in labels {
            XCTAssertGreaterThanOrEqual(label.rect.minY, 0)
            XCTAssertLessThanOrEqual(label.rect.maxY, pane.height)
        }
    }

    /// The leader line starts on the plate's *inner* edge, so it never runs back
    /// across its own text.
    func testTheLeaderStartsOnTheEdgeFacingTheRoom() throws {
        let pane = CGSize(width: 1300, height: 740)
        let layout = IsoLayout.fit(sessionCount: 12, canvas: pane)
        let labels = MarginLabelLayout.place(
            requests(count: 12, layout: layout, pane: pane),
            canvas: pane,
            columnWidth: layout.labelColumnWidth,
            roomCentreX: layout.roomArea.midX)
        for label in labels {
            XCTAssertEqual(label.leaderStart.y, label.rect.midY, accuracy: 1e-9)
            switch label.column {
            case .left: XCTAssertEqual(label.leaderStart.x, label.rect.maxX, accuracy: 1e-9)
            case .right: XCTAssertEqual(label.leaderStart.x, label.rect.minX, accuracy: 1e-9)
            }
        }
    }

    /// The endpoint is the *person*, which is the thing the reader is trying to
    /// identify — and for a waiting session the person is not at the desk at all
    /// but in the break room. Caught by having `workerAnchors` return the desk's
    /// own projected point: both halves of this go red.
    func testEveryLeaderEndsOnItsOwnWorkerRatherThanOnItsDesk() throws {
        let pane = CGSize(width: 1300, height: 740)
        let layout = IsoLayout.fit(sessionCount: 6, canvas: pane)
        let lighting = OfficeLighting.at(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            place: UserPlace.Coordinates(latitude: 52.52, longitude: 13.405,
                                         source: .table),
            weather: .clear)
        let desks = (0..<6).map { i in
            OfficeDesk(id: "S\(i)", name: "session \(i)", repository: "glyphline",
                       waiting: i == 2, subagentCount: 0, workTokens: 0)
        }
        let renderer = OfficeRenderer(layout: layout, frame: 0,
                                      hovered: nil, lighting: lighting)
        let anchors = renderer.workerAnchors(desks: desks)
        XCTAssertEqual(anchors.map(\.id), desks.map(\.id))

        for (i, anchor) in anchors.enumerated() where i != 2 {
            let slot = layout.desks[i]
            let seat = layout.projection.point(u: slot.u, v: slot.v + 0.42,
                                               h: 10 * layout.zoom)
            let deskPoint = layout.projection.point(u: slot.u, v: slot.v)
            XCTAssertEqual(anchor.point.x, seat.x, accuracy: 1e-9, "S\(i)")
            XCTAssertLessThan(anchor.point.y, seat.y, "S\(i): not on the figure")
            XCTAssertNotEqual(anchor.point.x, deskPoint.x, accuracy: 1e-6,
                              "S\(i): that is the desk, not the person")
        }

        // The waiting session has got up: its line has to reach the break room.
        let walker = BreakRoom(room: layout.breakRoom).walker(for: 0, seed: "S2", frame: 0)
        let pos = walker.position
        let sitting = !walker.isMoving && walker.slot.sitting
        let expected = layout.projection.point(u: pos.u, v: pos.v,
                                               h: sitting ? 9 * layout.zoom : 0)
        XCTAssertEqual(anchors[2].point.x, expected.x, accuracy: 1e-9)
        XCTAssertLessThan(anchors[2].point.y, expected.y)
        XCTAssertGreaterThan(pos.u, layout.span, "the break room is past the office")

        // And what is placed keeps that endpoint: every label's leader lands on
        // its own worker.
        let byID = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0.point) })
        let items = anchors.map {
            MarginLabelRequest(id: $0.id, worker: $0.point, width: 200, height: 34)
        }
        let labels = MarginLabelLayout.place(items, canvas: pane,
                                             columnWidth: layout.labelColumnWidth,
                                             roomCentreX: layout.roomArea.midX)
        XCTAssertEqual(labels.count, 6)
        for label in labels {
            XCTAssertEqual(label.worker, byID[label.id], "\(label.id)")
        }
    }

    // MARK: - Nothing leaves the pane

    /// Panes the user actually drags the window to, including two narrow enough
    /// that the columns are a fraction rather than the 240 pt ceiling.
    private let allPanes: [CGSize] = [
        CGSize(width: 380, height: 300),
        CGSize(width: 520, height: 420),
        CGSize(width: 800, height: 500),
        CGSize(width: 1300, height: 740),
        CGSize(width: 1720, height: 1020),
        CGSize(width: 900, height: 1200)
    ]

    /// The user's own bug: plates ran off both edges of the canvas. Asserted
    /// directly, on all four sides. Caught by dropping the `min(request.width,
    /// inner)` clip in `stack` — a 400 pt plate then hangs out of a 380 pt pane
    /// and both the clamp and this assertion go red.
    func testNoPlateEverExtendsBeyondThePane() throws {
        for pane in allPanes {
            for count in 4...20 {
                let layout = IsoLayout.fit(sessionCount: count, canvas: pane)
                let labels = MarginLabelLayout.place(
                    requests(count: count, layout: layout, pane: pane),
                    canvas: pane,
                    columnWidth: layout.labelColumnWidth,
                    roomCentreX: layout.roomArea.midX)
                for label in labels {
                    let what = "count \(count) pane \(pane): \(label.id) at \(label.rect)"
                    XCTAssertGreaterThanOrEqual(label.rect.minX, 0, what)
                    XCTAssertLessThanOrEqual(label.rect.maxX, pane.width, what)
                    XCTAssertGreaterThanOrEqual(label.rect.minY, 0, what)
                    XCTAssertLessThanOrEqual(label.rect.maxY, pane.height, what)
                }
            }
        }
    }

    /// And no plate is wider than the column that was reserved for it — the room
    /// was fitted against that reservation, so a plate wider than it is a plate
    /// over the room. Caught by the same mutation.
    func testNoPlateIsWiderThanItsColumn() throws {
        for pane in allPanes {
            for count in 4...20 {
                let layout = IsoLayout.fit(sessionCount: count, canvas: pane)
                let labels = MarginLabelLayout.place(
                    requests(count: count, layout: layout, pane: pane),
                    canvas: pane,
                    columnWidth: layout.labelColumnWidth,
                    roomCentreX: layout.roomArea.midX)
                for label in labels {
                    XCTAssertLessThanOrEqual(
                        label.rect.width, layout.labelColumnWidth,
                        "count \(count) pane \(pane): \(label.id) is \(label.rect.width) "
                            + "in a \(layout.labelColumnWidth) column")
                }
            }
        }
    }

    // MARK: - Cutting to a width rather than to a character count

    /// A stand-in for the text metrics, monotone in the prefix length exactly as
    /// the real one is. The rule under test is the fitting, not the font.
    private func measure(_ text: String) -> Double { Double(text.count) * 7 }

    /// A title far longer than the column comes back fitting it, and says so with
    /// an ellipsis. Caught by returning the text unchanged when it is too wide:
    /// the width assertion and the ellipsis assertion both go red.
    func testATitleLongerThanTheColumnIsCutToFitAndEndsInAnEllipsis() throws {
        let title = "Issue 558 auf Umstellung des Agentsverse in die zweite Ansicht "
            + "und weiteres"
        for limit in [40.0, 90.0, 202.0, 260.0] {
            let cut = LabelFit.truncated(title, to: limit, measure: measure)
            XCTAssertLessThanOrEqual(measure(cut), limit, "limit \(limit)")
            XCTAssertTrue(cut.hasSuffix("…"), "limit \(limit): \(cut)")
            XCTAssertTrue(title.hasPrefix(String(cut.dropLast())), "limit \(limit): \(cut)")
            // And it uses the room it has: one character more would not fit.
            XCTAssertGreaterThan(measure(cut + "x"), limit, "limit \(limit): \(cut)")
        }
    }

    /// A rule that truncates everything is as wrong as one that truncates
    /// nothing. Caught by cutting unconditionally instead of measuring first.
    func testAShortTitleIsLeftAlone() throws {
        for title in ["glyphline", "Issue 558", "a"] {
            XCTAssertEqual(LabelFit.truncated(title, to: 202, measure: measure), title)
        }
    }

    /// A hairline column takes no plate rather than an overflowing one.
    func testAColumnTooNarrowForEvenTheEllipsisTakesNoText() throws {
        XCTAssertEqual(LabelFit.truncated("glyphline", to: 4, measure: measure), "")
        XCTAssertEqual(LabelFit.truncated("glyphline", to: 0, measure: measure), "")
    }

    /// The end-to-end shape of the fix: a plate sized off a line cut to
    /// `labelTextWidth` fits its column at every pane size. This is the arithmetic
    /// that ties the fitter's limit to the layout's clip, and it is asserted
    /// rather than assumed because the two live in different files.
    func testAPlateSizedOffTheFittedWidthNeedsNoClipping() throws {
        for pane in allPanes {
            let layout = IsoLayout.fit(sessionCount: 8, canvas: pane)
            let renderer = OfficeRenderer(
                layout: layout, frame: 0, hovered: nil,
                lighting: OfficeLighting.at(
                    date: Date(timeIntervalSince1970: 1_800_000_000),
                    place: UserPlace.Coordinates(latitude: 52.52, longitude: 13.405,
                                                 source: .table),
                    weather: .clear))
            let widest = renderer.labelTextWidth + OfficeRenderer.plateTextInset
            let inner = layout.labelColumnWidth - 2 * MarginLabelLayout.padding
            XCTAssertLessThanOrEqual(widest, inner, "pane \(pane)")
        }
    }

    /// The off-the-clock strip stands its sleepers a fixed pitch apart and
    /// centres each name on its sleeper, so a name wider than the pitch runs into
    /// the next one. Its budget therefore has to be narrower than the pitch, and
    /// a long name has to come back inside it.
    ///
    /// Would catch: the hard-coded `prefix(13)` this replaced. Thirteen
    /// characters of a proportional 10 pt name measure past the slot, which is
    /// the same unit mismatch the plates had.
    func testASleepersNameIsCutToItsSlotRatherThanToACharacterCount() throws {
        XCTAssertLessThan(OfficeRenderer.offClockTextWidth,
                          OfficeRenderer.offClockSlotPitch,
                          "two sleepers' names must not meet in the middle")

        let name = "Issue 558 auf Umstellung des Agentverse"
        let cut = LabelFit.truncated(name, to: OfficeRenderer.offClockTextWidth,
                                     measure: measure)
        XCTAssertLessThanOrEqual(measure(cut), OfficeRenderer.offClockTextWidth)
        XCTAssertTrue(cut.hasSuffix("…"), cut)
        XCTAssertEqual(LabelFit.truncated("glyphline", to: OfficeRenderer.offClockTextWidth,
                                          measure: measure),
                       "glyphline")
    }

    func testAnEmptyOrDegenerateInputPlacesNothingRatherThanCrashing() throws {
        XCTAssertTrue(MarginLabelLayout.place([], canvas: CGSize(width: 900, height: 600),
                                              columnWidth: 170, roomCentreX: 450).isEmpty)
        let one = [MarginLabelRequest(id: "S0", worker: CGPoint(x: 10, y: 10),
                                      width: 100, height: 34)]
        XCTAssertTrue(MarginLabelLayout.place(one, canvas: .zero,
                                              columnWidth: 0, roomCentreX: 0).isEmpty)
    }
}
