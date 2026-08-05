import Foundation

/// The statistics screen's period switcher.
///
/// The cut-off is counted back through `LocalUsageDay.calendar`, the same grid
/// the buckets were keyed on. Counting it on any other calendar would put the
/// boundary in the middle of a stored day and drop part of it.
enum LocalUsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case last7Days
    case last30Days
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last7Days:
            String(localized: "7 Days", comment: "Chart period picker segment: the last seven days.")
        case .last30Days:
            String(localized: "30 Days", comment: "Chart period picker segment: the last thirty days.")
        case .allTime:
            String(localized: "All Time", comment: "Chart period picker segment: everything that was scanned.")
        }
    }

    /// Number of days the period spans, today included. Nil for all time.
    var days: Int? {
        switch self {
        case .last7Days:
            7
        case .last30Days:
            30
        case .allTime:
            nil
        }
    }

    /// Earliest bucket to include, or nil for all time.
    ///
    /// Inclusive and counted with today as day one: "7 days" is today plus the
    /// six days before it, not today plus seven.
    func since(now: Date, calendar: Calendar = LocalUsageDay.calendar) -> Date? {
        guard let days else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }
}
