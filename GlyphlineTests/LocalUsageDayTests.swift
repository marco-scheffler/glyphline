import XCTest

@testable import Glyphline

/// The one definition of a day the scanner, the ledger and the chart all read
/// from — and the arithmetic that moved the days recorded under the old one.
final class LocalUsageDayTests: XCTestCase {
    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: text) else {
            XCTFail("unparseable fixture date \(text)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    // MARK: - The grid itself

    /// The days are cut on the user's clock. This is the property the whole
    /// change rests on: it is what makes the bucket labelled "today" hold the
    /// hours the user has actually worked through.
    func testTheGridFollowsTheUsersClock() {
        XCTAssertEqual(LocalUsageDay.calendar.timeZone, .autoupdatingCurrent)
        XCTAssertEqual(LocalUsageDay.calendar.identifier, .gregorian)
    }

    // MARK: - Moving a day off the old grid

    /// East of Greenwich a UTC midnight is already two hours into the day, so
    /// the day it names begins two hours *earlier*.
    func testAUTCMidnightBecomesTheLocalMidnightOfTheSameDate() {
        XCTAssertEqual(
            LocalUsageDay.regridded(
                utcDayStart: date("2026-07-01T00:00:00Z"),
                calendar: calendar("Europe/Berlin")
            ),
            date("2026-06-30T22:00:00Z")
        )
    }

    /// And west of it the day has not started yet.
    func testAWesternTimezoneMovesTheDayForward() {
        XCTAssertEqual(
            LocalUsageDay.regridded(
                utcDayStart: date("2026-07-01T00:00:00Z"),
                calendar: calendar("America/Los_Angeles")
            ),
            date("2026-07-01T07:00:00Z")
        )
    }

    /// At UTC+0 the two grids are one grid, and a migration that moved anything
    /// there would be moving it for no reason.
    func testItIsTheIdentityAtUTC() {
        let midnight = date("2026-07-01T00:00:00Z")

        XCTAssertEqual(
            LocalUsageDay.regridded(utcDayStart: midnight, calendar: calendar("UTC")),
            midnight
        )
    }

    /// The offset is not a constant: it changes across a clock change, so the
    /// same calendar date maps differently in January and in July. Would catch a
    /// migration that subtracted one fixed offset from every row — half the
    /// history would land an hour off its own day.
    func testTheOffsetIsReadPerDateRatherThanOnce() {
        let berlin = calendar("Europe/Berlin")

        XCTAssertEqual(
            LocalUsageDay.regridded(utcDayStart: date("2026-01-15T00:00:00Z"), calendar: berlin),
            date("2026-01-14T23:00:00Z"),
            "central European winter is one hour ahead of UTC"
        )
        XCTAssertEqual(
            LocalUsageDay.regridded(utcDayStart: date("2026-07-15T00:00:00Z"), calendar: berlin),
            date("2026-07-14T22:00:00Z"),
            "summer is two"
        )
    }

    /// Two days may never become one row. The primary key is
    /// `(bucketStart, modelKey)`, so a mapping that collided would not fail —
    /// it would silently merge two days' tokens into whichever row was written
    /// last.
    func testConsecutiveDaysStayDistinct() {
        for timeZone in ["Europe/Berlin", "America/Los_Angeles", "Pacific/Auckland",
                         "Asia/Kolkata", "Pacific/Kiritimati", "UTC"] {
            let grid = calendar(timeZone)
            let moved = (0 ..< 400).map { offset in
                LocalUsageDay.regridded(
                    utcDayStart: date("2026-01-01T00:00:00Z")
                        .addingTimeInterval(Double(offset) * 24 * 60 * 60),
                    calendar: grid
                )
            }

            XCTAssertEqual(Set(moved).count, moved.count, "\(timeZone) collapsed two days into one")
        }
    }
}
