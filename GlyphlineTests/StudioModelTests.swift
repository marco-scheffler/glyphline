import XCTest
@testable import Glyphline

/// The studio floor's model: who looks like what, where the desks go, and what
/// the bubbles say. The drawing reads all of it and asserts none of it.
final class StudioModelTests: XCTestCase {
    private static let minimum = CGSize(width: 640, height: 300)
    private static let standard = CGSize(width: 1100, height: 480)

    func testTheSameSessionAlwaysLooksTheSame() {
        XCTAssertEqual(StudioFigure.forSession("abc"), StudioFigure.forSession("abc"))
        let looks = Set((0..<40).map { "\(StudioFigure.forSession("session-\($0)"))" })
        XCTAssertGreaterThan(looks.count, 1)
    }

    func testHoodieIsTheSessionColour() {
        for id in ["a", "b", "session-7", "f00"] {
            XCTAssertEqual(StudioFigure.forSession(id).hoodie, SessionPalette.forSession(id).shirt)
        }
    }

    func testDesksTileInsideTheFloorWithoutOverlap() {
        for canvas in [Self.minimum, Self.standard] {
            for count in 1...16 {
                let layout = StudioLayout(canvas: canvas, deskCount: count)
                let floor = CGRect(x: 0, y: 0, width: canvas.width - layout.breakRoom.width,
                                   height: canvas.height)
                let rects = (0..<count).map(layout.deskRect)
                for (i, rect) in rects.enumerated() {
                    XCTAssertTrue(floor.contains(rect), "\(canvas) \(count) desk \(i)")
                    XCTAssertFalse(rect.intersects(layout.breakRoom))
                    for other in rects[(i + 1)...] {
                        XCTAssertFalse(rect.intersects(other), "\(canvas) \(count)")
                    }
                }
            }
        }
    }

    func testTwelveDesksStayReadable() {
        XCTAssertGreaterThanOrEqual(StudioLayout(canvas: Self.minimum, deskCount: 12).deskScale, 0.45)
        XCTAssertEqual(StudioLayout(canvas: Self.standard, deskCount: 6).deskScale, 1)
    }

    private static let large = CGSize(width: 1400, height: 840)

    /// Would catch: waiting figures stacked on one another — the reference
    /// machine had ten of thirteen sessions waiting, and wandering walkers on
    /// eight shared slots drew them as one heap.
    func testWaitingSpotsNeverOverlapAndStayInTheRoom() {
        for canvas in [Self.minimum, Self.standard, Self.large] {
            let room = StudioLayout(canvas: canvas, deskCount: 6).breakRoom
            for count in 0...16 {
                let spots = StudioBreakRoomLayout(room: room, count: count)
                XCTAssertEqual(spots.spots.count + spots.overflow, count, "\(canvas) \(count)")
                let cells = spots.spots.map(\.cell) + (spots.overflowBadge.map { [$0] } ?? [])
                for (i, cell) in cells.enumerated() {
                    XCTAssertTrue(room.contains(cell), "\(canvas) \(count) cell \(i) leaves the room")
                    for other in cells[(i + 1)...] {
                        XCTAssertFalse(cell.intersects(other), "\(canvas) \(count) cells overlap")
                    }
                }
                for spot in spots.spots {
                    let s = spots.figureScale
                    let figure = CGRect(
                        x: spot.figure.x - StudioBreakRoomLayout.figureSize.width * s / 2,
                        y: spot.figure.y - StudioBreakRoomLayout.figureTop * s - 3,
                        width: StudioBreakRoomLayout.figureSize.width * s,
                        height: StudioBreakRoomLayout.figureSize.height * s + 3)
                    XCTAssertTrue(spot.cell.contains(figure), "\(canvas) \(count) figure leaves its cell")
                    XCTAssertGreaterThanOrEqual(spot.bubbleTop - StudioRenderer.maximumBob, spot.cell.minY)
                }
            }
        }
    }

    /// The case that prompted the grid: ten waiting in the default window all
    /// get a place, at a size a face is still a face.
    func testTenWaitingSessionsFitTheDefaultWindow() {
        let room = StudioLayout(canvas: Self.standard, deskCount: 13).breakRoom
        let spots = StudioBreakRoomLayout(room: room, count: 10)
        XCTAssertEqual(spots.overflow, 0)
        XCTAssertNil(spots.overflowBadge)
        XCTAssertGreaterThanOrEqual(spots.figureScale, 0.5)
    }

    /// One or two waiting keep the full-size figure.
    func testAFewWaitingSessionsKeepTheirFullSize() {
        let room = StudioLayout(canvas: Self.standard, deskCount: 6).breakRoom
        XCTAssertEqual(StudioBreakRoomLayout(room: room, count: 2).figureScale, 1)
    }

    /// Would catch: sessions silently missing from a room too small for them.
    func testARoomTooSmallSaysHowManyAreMissing() {
        let room = StudioLayout(canvas: Self.minimum, deskCount: 13).breakRoom
        let spots = StudioBreakRoomLayout(room: room, count: 10)
        XCTAssertGreaterThan(spots.overflow, 0)
        XCTAssertNotNil(spots.overflowBadge)
        XCTAssertFalse(spots.spots.isEmpty)
    }

    func testTheLongestWaitStandsFirst() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func desk(_ id: String, minutes: Double?) -> StudioDesk {
            StudioDesk(id: id, name: id, waiting: true, action: .thinking,
                       waitingSince: minutes.map { now.addingTimeInterval(-$0 * 60) },
                       figure: .forSession(id))
        }
        let ordered = StudioBreakRoomLayout.ordered([
            desk("b", minutes: 5), desk("none", minutes: nil), desk("a", minutes: 40),
            desk("c", minutes: 5)
        ])
        XCTAssertEqual(ordered.map(\.id), ["a", "b", "c", "none"])
    }

    func testWaitingBubbleCountsMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let desk = StudioDesk(id: "a", name: "A", waiting: true, action: .thinking,
                              waitingSince: now.addingTimeInterval(-6 * 60),
                              figure: .forSession("a"))
        XCTAssertTrue(StudioBubble.text(for: desk, now: now).contains(6.formatted()))
        XCTAssertTrue(StudioBubble.emptyDeskText(for: desk, now: now).contains(6.formatted()))
        XCTAssertEqual(StudioBubble.waitingText(since: now.addingTimeInterval(-30), now: now),
                       StudioBubble.waitingText(since: now, now: now))
    }
}
