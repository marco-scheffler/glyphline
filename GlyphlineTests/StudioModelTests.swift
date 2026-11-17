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

    func testWalkersStayInTheBreakRoom() {
        for canvas in [Self.minimum, Self.standard] {
            let layout = StudioLayout(canvas: canvas, deskCount: 4)
            let room = BreakRoom(room: StudioLayout.breakRoomFloor)
            for order in 0...7 {
                for frame in stride(from: 0, through: 6000, by: 97) {
                    let point = layout.breakRoomPoint(room.walker(for: order, seed: "s\(order)", frame: frame))
                    XCTAssertTrue(layout.breakRoom.contains(point), "\(order) \(frame)")
                }
            }
        }
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
