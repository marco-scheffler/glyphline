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
