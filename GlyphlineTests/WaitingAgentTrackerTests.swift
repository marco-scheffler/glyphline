import XCTest
@testable import Glyphline

final class WaitingAgentTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let delay: TimeInterval = 3 * 60

    private func tail(_ id: String = "S1", _ activity: AgentActivity, at offset: TimeInterval,
                      sidechain: Bool = false) -> TranscriptTail {
        TranscriptTail(sessionID: id, isSidechain: sidechain, cwd: "/code/glyphline", gitBranch: "main",
                       timestamp: t0.addingTimeInterval(offset), activity: activity,
                       aiTitle: "Fix the sweep", slug: nil)
    }

    /// Swift does not skip a leading unlabeled defaulted parameter, so the
    /// single-session calls need their own overload.
    private func tail(_ activity: AgentActivity, at offset: TimeInterval,
                      sidechain: Bool = false) -> TranscriptTail {
        tail("S1", activity, at: offset, sidechain: sidechain)
    }

    func testAWaitingSessionIsReportedOnceTheDelayHasPassed() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))

        XCTAssertTrue(tracker.due(now: t0.addingTimeInterval(delay - 1), delay: delay).isEmpty)
        let due = tracker.due(now: t0.addingTimeInterval(delay), delay: delay)

        XCTAssertEqual(due.map(\.sessionID), ["S1"])
        XCTAssertEqual(due.first?.title, "Fix the sweep")
        XCTAssertEqual(due.first?.repository, "glyphline")
        XCTAssertEqual(due.first?.waitingSince, t0)
    }

    func testAPhaseIsReportedOnlyOnce() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))
        _ = tracker.due(now: t0.addingTimeInterval(delay), delay: delay)

        XCTAssertTrue(tracker.due(now: t0.addingTimeInterval(delay * 5), delay: delay).isEmpty)
    }

    func testWorkingBeforeTheDelayCancelsTheReport() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))
        tracker.record(tail(.working, at: 60))

        XCTAssertTrue(tracker.due(now: t0.addingTimeInterval(delay * 2), delay: delay).isEmpty)
    }

    func testAfterWorkingTheNextWaitIsANewPhase() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))
        _ = tracker.due(now: t0.addingTimeInterval(delay), delay: delay)
        tracker.record(tail(.working, at: 600))
        tracker.record(tail(.waitingForYou, at: 900))

        XCTAssertEqual(tracker.due(now: t0.addingTimeInterval(900 + delay), delay: delay).map(\.sessionID), ["S1"])
    }

    /// Coalesced events: the working record in between was never seen.
    func testANewerWaitingTailStartsANewPhase() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))
        _ = tracker.due(now: t0.addingTimeInterval(delay), delay: delay)
        tracker.record(tail(.waitingForYou, at: 900))

        XCTAssertEqual(tracker.due(now: t0.addingTimeInterval(900 + delay), delay: delay).count, 1)
    }

    /// Non-conversational records (a title, say) re-deliver the same last turn.
    func testTheSameWaitingTailAgainChangesNothing() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))
        _ = tracker.due(now: t0.addingTimeInterval(delay), delay: delay)
        tracker.record(tail(.waitingForYou, at: 0))

        XCTAssertTrue(tracker.due(now: t0.addingTimeInterval(delay * 2), delay: delay).isEmpty)
    }

    func testASubagentFinishingIsNotTheSessionWaiting() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0, sidechain: true))

        XCTAssertTrue(tracker.due(now: t0.addingTimeInterval(delay), delay: delay).isEmpty)
    }

    func testAWaitingTailOlderThanTheHorizonIsNeverReported() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail(.waitingForYou, at: 0))

        let late = t0.addingTimeInterval(AgentSessionScanner.horizon + 1)
        XCTAssertTrue(tracker.due(now: late, delay: delay).isEmpty)
    }

    func testSessionsDueOnOneTickComeBackTogetherOldestFirst() {
        var tracker = WaitingAgentTracker()
        tracker.record(tail("B", .waitingForYou, at: 30))
        tracker.record(tail("A", .waitingForYou, at: 0))

        XCTAssertEqual(tracker.due(now: t0.addingTimeInterval(delay + 30), delay: delay).map(\.sessionID), ["A", "B"])
    }
}
