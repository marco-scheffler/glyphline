import SwiftUI
import XCTest
@testable import Glyphline

/// The studio floor: who gets a desk, what the bubbles may measure, and what a
/// frame of it costs.
final class StudioFloorTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String,
                         _ activity: AgentActivity,
                         action: AgentAction = .thinking) -> AgentSession {
        var session = AgentSession(id: id, cwd: "/repo/\(id)", gitBranch: "main",
                                   activity: activity,
                                   lastActivityAt: instant.addingTimeInterval(-300))
        session.action = action
        return session
    }

    func testEveryOnTrackSessionGetsADesk() {
        let sessions = [session("A", .working), session("B", .waitingForYou),
                        session("C", .working, action: .editing(file: "x.swift"))]

        let desks = StudioFloor.desks(from: sessions)

        XCTAssertEqual(desks.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(desks[2].action, .editing(file: "x.swift"))
    }

    func testAWaitingSessionsDeskIsEmpty() {
        let desks = StudioFloor.desks(from: [session("A", .working),
                                             session("B", .waitingForYou)])

        XCTAssertFalse(desks[0].waiting)
        XCTAssertTrue(desks[1].waiting)
        XCTAssertEqual(desks[1].waitingSince, instant.addingTimeInterval(-300))
        XCTAssertNil(desks[0].waitingSince)
    }

    /// Would catch: a bubble cut to a character count, or measured with a
    /// different font than the one it is drawn with.
    func testNoBubbleIsWiderThanItsDesk() {
        let long = String(repeating: "abcdefghij", count: 20)
        XCTAssertEqual(long.count, 200)
        for (canvas, count) in [(CGSize(width: 1100, height: 480), 12),
                                (CGSize(width: 900, height: 560), 12),
                                (CGSize(width: 640, height: 300), 3)] {
            let layout = StudioLayout(canvas: canvas, deskCount: count)
            for index in 0..<count {
                let rect = layout.deskRect(index)
                for typing in [true, false] {
                    let fitted = StudioRenderer.fittedBubble(long, deskWidth: rect.width,
                                                             typing: typing)
                    XCTAssertLessThanOrEqual(
                        StudioRenderer.measureBubble(fitted),
                        rect.width - 2 * StudioRenderer.bubbleInset,
                        "bubble overflows desk \(index) at \(canvas)")
                }
            }
        }
    }

    private func waitingDesk(_ id: String, minutes: Int) -> StudioDesk {
        StudioDesk(id: id, name: "project-\(id)", waiting: true, action: .thinking,
                   waitingSince: instant.addingTimeInterval(-Double(minutes) * 60),
                   figure: .forSession(id))
    }

    /// Would catch: the floor's bubbles cut at the end, losing the minutes —
    /// the one part of a waiting sentence that changes.
    func testWaitingBubblesKeepTheirMinutesAtTheSmallestCanvas() throws {
        let layout = StudioLayout(canvas: CGSize(width: 640, height: 300), deskCount: 12)
        for minutes in [6, 42, 123] {
            let tail = "· \(minutes.formatted()) min"
            for (index, id) in ["A", "B", "C"].enumerated() {
                let desk = waitingDesk(id, minutes: minutes)
                let rect = layout.deskRect(index)
                let empty = StudioRenderer.emptyDeskBubble(for: desk, now: instant, deskWidth: rect.width)
                XCTAssertTrue(empty.hasSuffix(tail), "\(empty) lost its minutes")
                XCTAssertLessThanOrEqual(StudioRenderer.measureBubble(empty),
                                         rect.width - 2 * StudioRenderer.bubbleInset)

                for crowd in [1, 10] {
                    let spots = StudioBreakRoomLayout(room: layout.breakRoom, count: crowd)
                    let cell = try XCTUnwrap(spots.spots.first).cell
                    let room = StudioRenderer.breakRoomBubble(for: desk, now: instant,
                                                              cellWidth: cell.width)
                    XCTAssertTrue(room.hasSuffix(tail), "\(room) lost its minutes")
                    XCTAssertLessThanOrEqual(StudioRenderer.measureBubble(room),
                                             cell.width - 2 * StudioRenderer.bubbleInset)
                }
            }
        }
    }

    /// Would catch: a plate pinned to the full-size station's offset hanging
    /// into the row below, or a bobbing bubble poking into the row above.
    func testPlatesAndBubblesStayInsideTheirDesks() {
        let long = String(repeating: "abcdefghij", count: 20)
        for canvas in [CGSize(width: 640, height: 300), CGSize(width: 1100, height: 480)] {
            for count in 1...16 {
                let layout = StudioLayout(canvas: canvas, deskCount: count)
                for index in 0..<count {
                    let rect = layout.deskRect(index)
                    let slack = rect.insetBy(dx: -0.001, dy: -0.001)
                    if let plate = StudioRenderer.plateRect(name: long, rect: rect, scale: layout.deskScale) {
                        XCTAssertTrue(slack.contains(plate.rect),
                                      "plate \(index) of \(count) at \(canvas) leaves its desk")
                    }
                    let text = StudioRenderer.fittedBubble(long, deskWidth: rect.width, typing: true)
                    let top = StudioRenderer.deskBubbleTop(rect: rect, scale: layout.deskScale)
                    for bob in [0, StudioRenderer.maximumBob] {
                        let bubble = StudioRenderer.bubbleRect(text: text, typing: true,
                                                               centreX: rect.midX, top: top,
                                                               bounds: rect, bob: bob)
                        XCTAssertTrue(slack.contains(bubble),
                                      "bubble \(index) of \(count) at \(canvas) leaves its desk")
                        XCTAssertGreaterThanOrEqual(bubble.minY, rect.minY + 3 - 0.001)
                    }
                }
            }
        }
    }

    @MainActor
    func testTheFloorFitsTheFrameBudget() throws {
        let sessions = (0..<12).map { i in
            session("S\(i)", i % 3 == 0 ? .waitingForYou : .working,
                    action: .editing(file: "File\(i).swift"))
        }
        let base = 1_000_000
        func render(_ frame: Int) -> CGImage? {
            let renderer = ImageRenderer(content: StudioFloor(sessions: sessions, hovered: nil,
                                                              frame: frame, now: instant)
                .frame(width: 1100, height: 480))
            renderer.scale = 1
            return renderer.cgImage
        }
        // One warm-up so first-use font and pipeline costs do not count.
        XCTAssertNotNil(render(base - 1))

        let clock = ContinuousClock()
        var total = Duration.zero
        for frame in base..<(base + 60) {
            total += try clock.measure { _ = try XCTUnwrap(render(frame)) }
        }
        let meanMs = Double(total.components.attoseconds) / 1e15 / 60
            + Double(total.components.seconds) * 1000 / 60
        print("StudioFloor mean frame: \(meanMs) ms")
        XCTAssertLessThan(meanMs, 8.3)
    }
}
