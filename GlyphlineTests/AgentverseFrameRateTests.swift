import Foundation
import XCTest

@testable import Glyphline

/// The rate the Agentverse animates at, and the rate it can express.
///
/// These have to be the same number. The scene is a pure function of an integer
/// frame index derived from the clock, so asking the timeline for frames faster
/// than the index advances buys nothing: the extra ticks rebuild the whole scene
/// and rasterise it to produce a picture identical to the one already on screen.
///
/// That was the state on any 120 Hz display, where `TimelineView(.animation)`
/// without a minimum interval runs at the refresh rate. Measured at the window's
/// real size, the datastream view costs about 6 ms a frame at six sessions and
/// 8.6 ms at twelve, against an 8.3 ms budget at 120 Hz.
final class AgentverseFrameRateTests: XCTestCase {
    private let instant = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The interval and the rate are one decision, not two that happen to agree.
    func testTheIntervalIsTheReciprocalOfTheFrameRate() {
        XCTAssertEqual(
            AgentverseRefreshSchedule.frameInterval * AgentverseRefreshSchedule.framesPerSecond,
            1,
            accuracy: 0.000_001
        )
    }

    /// One interval advances the picture by exactly one frame. Less than that is
    /// the same picture — which is the whole reason for the cap.
    func testOneIntervalAdvancesExactlyOneFrame() {
        let interval = AgentverseRefreshSchedule.frameInterval
        let start = AgentverseRefreshSchedule.frameIndex(at: instant)

        XCTAssertEqual(
            AgentverseRefreshSchedule.frameIndex(at: instant.addingTimeInterval(interval)),
            start + 1
        )
        XCTAssertEqual(
            AgentverseRefreshSchedule.frameIndex(at: instant.addingTimeInterval(interval * 10)),
            start + 10
        )
    }

    /// Would catch: lifting the cap. Half an interval later the scene is
    /// identical, so a timeline running twice as fast spends a full render per
    /// tick to redraw what is already there.
    func testHalfAnIntervalLaterIsTheSamePicture() {
        let half = AgentverseRefreshSchedule.frameInterval / 2

        XCTAssertEqual(
            AgentverseRefreshSchedule.frameIndex(at: instant.addingTimeInterval(half)),
            AgentverseRefreshSchedule.frameIndex(at: instant),
            "a tick inside one frame's interval produces a different index"
        )
    }

    /// The frame index has to keep counting forward across whole seconds rather
    /// than resetting inside one — a scene that restarted its animation every
    /// second would read as a stutter of its own.
    func testTheIndexKeepsCountingAcrossSeconds() {
        let aSecondLater = AgentverseRefreshSchedule.frameIndex(at: instant.addingTimeInterval(1))

        XCTAssertEqual(
            aSecondLater - AgentverseRefreshSchedule.frameIndex(at: instant),
            Int(AgentverseRefreshSchedule.framesPerSecond)
        )
    }
}
