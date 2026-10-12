import Foundation

struct QuotaRunway: Equatable {
    var window: RateWindow
    var timeToEmpty: TimeInterval
}

/// Which windows are worth a warning: empty before their own reset at the pace
/// so far, and soon. The pace is `QuotaIndicator.pace`, the same number the row
/// shows as "empty in …", so the warning and the row cannot disagree.
enum QuotaRunwayRule {
    static let minimumLeadTime: TimeInterval = 30 * 60

    /// At least one sync interval: a check every hour with a half-hour lead
    /// would find most windows already empty.
    static func leadTime(syncInterval: TimeInterval?) -> TimeInterval {
        max(minimumLeadTime, syncInterval ?? 0)
    }

    static func runningOut(_ windows: [RateWindow], now: Date, leadTime: TimeInterval) -> [QuotaRunway] {
        windows.compactMap { window in
            guard case .emptyIn(let remaining)? = QuotaIndicator.pace(for: window, now: now),
                  remaining <= leadTime
            else { return nil }
            return QuotaRunway(window: window, timeToEmpty: remaining)
        }
    }
}
