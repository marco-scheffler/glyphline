import XCTest
@testable import Glyphline

final class QuotaRunwayRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two hours into a five-hour window; `used` decides the pace.
    private func window(used: Double, kind: RateWindowKind = .rollingFiveHours) -> RateWindow {
        RateWindow(kind: kind, usedFraction: used,
                   resetAt: now.addingTimeInterval(3 * 3600), observedAt: now)
    }

    func testAWindowEmptyWithinTheLeadTimeIsReported() {
        // 80% in two hours: empty in 30 min, reset in 3 h.
        let result = QuotaRunwayRule.runningOut([window(used: 0.8)], now: now, leadTime: 30 * 60)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.timeToEmpty ?? 0, 30 * 60, accuracy: 1e-6)
    }

    func testAWindowEmptyLaterThanTheLeadTimeIsNotReportedYet() {
        // 60% in two hours: empty in 80 min.
        XCTAssertTrue(QuotaRunwayRule.runningOut([window(used: 0.6)], now: now, leadTime: 30 * 60).isEmpty)
    }

    func testAWindowThatOutlastsItsResetIsNeverReported() {
        XCTAssertTrue(QuotaRunwayRule.runningOut([window(used: 0.2)], now: now, leadTime: 10 * 3600).isEmpty)
    }

    func testASpentWindowIsNotReported() {
        XCTAssertTrue(QuotaRunwayRule.runningOut([window(used: 1)], now: now, leadTime: 30 * 60).isEmpty)
    }

    /// A 60-minute interval must not sleep past the moment.
    func testTheLeadTimeIsNeverShorterThanTheSyncInterval() {
        XCTAssertEqual(QuotaRunwayRule.leadTime(syncInterval: 900), 30 * 60)
        XCTAssertEqual(QuotaRunwayRule.leadTime(syncInterval: 3600), 3600)
        XCTAssertEqual(QuotaRunwayRule.leadTime(syncInterval: nil), 30 * 60)
    }
}
