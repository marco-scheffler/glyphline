import XCTest
@testable import Glyphline

final class LocalUsagePeriodTests: XCTestCase {
    /// 2024-03-15T12:00:00Z — midday, so a local-time cut-off would not be
    /// mistaken for the UTC one by accident.
    private static let now = Date(timeIntervalSince1970: 1_710_504_000)

    private func utcDay(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    func testAllTimeHasNoCutOff() {
        XCTAssertNil(LocalUsagePeriod.allTime.since(now: Self.now))
    }

    func testSevenDaysCountsTodayAsDayOne() {
        XCTAssertEqual(
            LocalUsagePeriod.last7Days.since(now: Self.now),
            utcDay("2024-03-09T00:00:00Z")
        )
    }

    func testThirtyDaysCountsTodayAsDayOne() {
        XCTAssertEqual(
            LocalUsagePeriod.last30Days.since(now: Self.now),
            utcDay("2024-02-15T00:00:00Z")
        )
    }

    /// The stored buckets are UTC day starts. A cut-off computed in a
    /// behind-UTC local time would land mid-bucket and drop part of a day.
    func testTheCutOffIsAUTCDayStartEvenLateInTheUTCDay() {
        let lateInTheUTCDay = utcDay("2024-03-15T23:30:00Z")
        XCTAssertEqual(
            LocalUsagePeriod.last7Days.since(now: lateInTheUTCDay),
            utcDay("2024-03-09T00:00:00Z")
        )
    }

    func testEveryPeriodHasADistinctTitle() {
        let titles = LocalUsagePeriod.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, LocalUsagePeriod.allCases.count)
    }
}
