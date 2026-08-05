import XCTest
@testable import Glyphline

final class LocalUsagePeriodTests: XCTestCase {
    /// 2024-03-15T12:00:00Z — midday, so a cut-off computed on another grid
    /// would not be mistaken for this one by accident.
    private static let now = Date(timeIntervalSince1970: 1_710_504_000)

    /// The grid the expected instants below are written on. Fixed, so that
    /// "seven days back" is the same assertion on every machine; the grid the
    /// app actually uses has its own test.
    private static let fixedGrid: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

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
            LocalUsagePeriod.last7Days.since(now: Self.now, calendar: Self.fixedGrid),
            utcDay("2024-03-09T00:00:00Z")
        )
    }

    func testThirtyDaysCountsTodayAsDayOne() {
        XCTAssertEqual(
            LocalUsagePeriod.last30Days.since(now: Self.now, calendar: Self.fixedGrid),
            utcDay("2024-02-15T00:00:00Z")
        )
    }

    /// The cut-off is a day *start* on the grid it counts back through, whatever
    /// time of day it is asked. Landing anywhere else would cut a stored bucket
    /// in half and drop the part below the line.
    func testTheCutOffIsADayStartEvenLateInTheDay() {
        let lateInTheDay = utcDay("2024-03-15T23:30:00Z")
        XCTAssertEqual(
            LocalUsagePeriod.last7Days.since(now: lateInTheDay, calendar: Self.fixedGrid),
            utcDay("2024-03-09T00:00:00Z")
        )
    }

    /// And left alone it counts back through the grid the buckets were written
    /// on: the user's.
    ///
    /// The expectation is built from `Calendar.autoupdatingCurrent` rather than
    /// from `LocalUsageDay.calendar`, which is the thing under test — written in
    /// terms of it, this would follow it back to UTC and pass either way. Would
    /// catch the default going back to a fixed timezone: the cut-off would then
    /// sit hours inside a stored day. It discriminates wherever the machine's
    /// offset is not zero.
    func testTheDefaultGridIsTheUsersOwnClock() {
        let user = Calendar.autoupdatingCurrent
        let today = user.startOfDay(for: Self.now)

        XCTAssertEqual(
            LocalUsagePeriod.last7Days.since(now: Self.now),
            user.date(byAdding: .day, value: -6, to: today)
        )
    }

    func testEveryPeriodHasADistinctTitle() {
        let titles = LocalUsagePeriod.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, LocalUsagePeriod.allCases.count)
    }
}
