import XCTest
@testable import Glyphline

final class AgentverseModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, ago: TimeInterval, subagents: Int = 0) -> AgentSession {
        AgentSession(
            id: id,
            cwd: "/repo/\(id)",
            gitBranch: "main",
            activity: .working,
            lastActivityAt: now.addingTimeInterval(-ago),
            subagentCount: subagents
        )
    }

    private func parked(_ id: String, parkedAgo: TimeInterval) -> ParkedAgentSession {
        ParkedAgentSession(
            sessionID: id,
            cwd: "/repo/\(id)",
            gitBranch: "main",
            subagentCount: 0,
            lastActivityAt: now.addingTimeInterval(-parkedAgo - 3600),
            parkedAt: now.addingTimeInterval(-parkedAgo)
        )
    }

    func testARecentSessionIsOnTrack() throws {
        let out = AgentverseRules.reconcile(scanned: [session("S1", ago: 120)], parked: [], now: now)

        XCTAssertEqual(out.onTrack.map(\.id), ["S1"])
        XCTAssertTrue(out.newlyParked.isEmpty)
    }

    /// The heart of it: a session already cold at launch was never on the map, so
    /// it must not arrive in the pit lane. Otherwise the first launch offers 320
    /// cards to throw away.
    func testASessionAlreadyColdIsNotParkedRetroactively() throws {
        let out = AgentverseRules.reconcile(scanned: [session("OLD", ago: 5400)], parked: [], now: now)

        XCTAssertTrue(out.onTrack.isEmpty)
        XCTAssertTrue(out.newlyParked.isEmpty, "never seen live means never parked")
        XCTAssertTrue(out.parked.isEmpty)
    }

    /// Crossing the horizon while the app is watching is what parks a session —
    /// "watching" being the previous sweep having had it on track.
    func testASessionThatGoesQuietWhileWatchedIsParked() throws {
        let first = AgentverseRules.reconcile(scanned: [session("S1", ago: 60)], parked: [], now: now)
        XCTAssertEqual(first.onTrack.map(\.id), ["S1"])

        let later = now.addingTimeInterval(70 * 60)
        let second = AgentverseRules.reconcile(
            scanned: [session("S1", ago: 60)],
            parked: [],
            liveSessionIDs: Set(first.onTrack.map(\.id)),
            now: later
        )

        XCTAssertTrue(second.onTrack.isEmpty)
        XCTAssertEqual(second.newlyParked.map(\.sessionID), ["S1"])
        XCTAssertEqual(second.newlyParked[0].parkedAt, later)
        XCTAssertEqual(second.newlyParked[0].lastActivityAt, now.addingTimeInterval(-60))
    }

    func testAParkedSessionThatWritesAgainReturnsToTheTrack() throws {
        let out = AgentverseRules.reconcile(
            scanned: [session("S1", ago: 30)],
            parked: [parked("S1", parkedAgo: 7200)],
            now: now
        )

        XCTAssertEqual(out.onTrack.map(\.id), ["S1"])
        XCTAssertEqual(out.unparked, ["S1"], "its pit-lane row has to go")
        XCTAssertTrue(out.parked.isEmpty)
    }

    func testParkedSessionsPastTheExpiryAreDropped() throws {
        let out = AgentverseRules.reconcile(
            scanned: [],
            parked: [parked("OLD", parkedAgo: 97 * 3600), parked("FRESH", parkedAgo: 95 * 3600)],
            now: now
        )

        XCTAssertEqual(out.parked.map(\.sessionID), ["FRESH"])
        XCTAssertEqual(out.expired, ["OLD"])
    }

    func testOnTrackIsOrderedByWhatHappenedLast() throws {
        let out = AgentverseRules.reconcile(
            scanned: [session("B", ago: 600), session("A", ago: 5), session("C", ago: 1800)],
            parked: [],
            now: now
        )

        XCTAssertEqual(out.onTrack.map(\.id), ["A", "B", "C"])
    }
}
