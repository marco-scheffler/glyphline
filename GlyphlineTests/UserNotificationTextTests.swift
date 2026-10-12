import XCTest
@testable import Glyphline

/// The words a notification carries, pinned without a notification centre.
final class UserNotificationTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ id: String, title: String, repository: String, minutesAgo: Double) -> WaitingAgent {
        WaitingAgent(sessionID: id, title: title, repository: repository,
                     waitingSince: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// One agent: its own title leads, so the notification says which one
    /// without being opened.
    func testOneAgentIsNamedByItsTitle() {
        let text = UserNotificationText.agentsWaiting(
            [agent("a", title: "Fix the sweep", repository: "glyphline", minutesAgo: 3)], now: now
        )
        XCTAssertEqual(text.title, "Fix the sweep")
        XCTAssertTrue(text.body.contains("3"), text.body)
        XCTAssertTrue(text.body.contains("glyphline"), text.body)
    }

    /// Several due on one tick are one notification, not a stack of them.
    func testSeveralAgentsAreOneNotificationListingTheirTitles() {
        let text = UserNotificationText.agentsWaiting(
            [agent("a", title: "One", repository: "r", minutesAgo: 4),
             agent("b", title: "Two", repository: "r", minutesAgo: 3)], now: now
        )
        XCTAssertTrue(text.title.contains("2"), text.title)
        XCTAssertTrue(text.body.contains("One") && text.body.contains("Two"), text.body)
    }

    /// Minutes floor, like every other duration in the app: a lower bound.
    func testWaitingMinutesFloor() {
        let text = UserNotificationText.agentsWaiting(
            [agent("a", title: "T", repository: "r", minutesAgo: 3.9)], now: now
        )
        XCTAssertTrue(text.body.contains("3"), text.body)
        XCTAssertFalse(text.body.contains("4"), text.body)
    }

    /// No repository: the body ends on the minutes, not on a dangling separator.
    func testOneAgentWithoutARepositoryHasNoTrailingSeparator() {
        let text = UserNotificationText.agentsWaiting(
            [agent("a", title: "T", repository: "", minutesAgo: 3)], now: now
        )
        XCTAssertTrue(text.body.contains("3"), text.body)
        XCTAssertFalse(text.body.contains("·"), text.body)
    }

    func testQuotaTextNamesTheWindowAndTheTime() {
        let body = UserNotificationText.quotaRunningOut(kind: .rollingFiveHours, timeToEmpty: 20 * 60)
        XCTAssertTrue(body.contains(RateWindowKind.rollingFiveHours.longName), body)
        XCTAssertTrue(body.contains("20"), body)
    }
}
