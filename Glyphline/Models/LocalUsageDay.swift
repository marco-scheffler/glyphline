import Foundation

/// The calendar the machine-wide local usage is cut into days by: the user's.
///
/// One definition, named once, because three layers have to agree on it. The
/// scanner keys `LocalTokenUsage.bucketStart` with it, the chart bins and labels
/// with it, and the period cut-offs count back through it. A second answer
/// anywhere along that chain is a day sliced in half and filed under two names.
///
/// It was UTC until this version, and that is what made "today" begin at 02:00
/// in Berlin and hand everything before it to yesterday: measured against the
/// same transcripts on the same morning, 120M tokens where 288M had been spent.
/// A day is what the clock on the wall says it is — nothing else can be labelled
/// "today".
///
/// Gregorian rather than the user's calendar *identifier*: only the timezone
/// decides where a day begins, and every day count in this pipeline — "the last
/// 30 days", "the day after this one" — means a Gregorian day.
enum LocalUsageDay {
    /// Autoupdating, so a Mac carried into another timezone buckets on the new
    /// clock at the next scan rather than at the next launch.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    /// Where a day recorded under the old UTC grid belongs on this one.
    ///
    /// Reads the calendar *date* off a stored `bucketStart` — a UTC midnight —
    /// and returns that date's local midnight. Nothing is re-cut here: the
    /// bucket keeps its contents and only its key moves, which is what lets the
    /// rebuild that follows delete the day it is about to replace. Without it,
    /// the rebuild's delete would miss the old row and add its own beside it,
    /// counting every corrected day twice.
    ///
    /// Injective for every real timezone — offsets run from −12 to +14 hours, so
    /// a local midnight is never some other date's UTC midnight — which is why
    /// two days can never collide into one row. At UTC+0 it is the identity.
    ///
    /// Migration `v15` is the only caller. The arithmetic lives here rather than
    /// inside it because it is a statement about the grid, and because it is the
    /// one part of that migration a test can hold without a database.
    static func regridded(utcDayStart: Date, calendar: Calendar = LocalUsageDay.calendar) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let date = utc.dateComponents([.year, .month, .day], from: utcDayStart)
        guard let midnight = calendar.date(
            from: DateComponents(year: date.year, month: date.month, day: date.day)
        ) else { return utcDayStart }

        // Through `startOfDay` rather than straight out of `date(from:)`: in the
        // timezones that skip midnight on a DST change there is no 00:00 to
        // return, and this lands on the first instant that does exist.
        return calendar.startOfDay(for: midnight)
    }
}
