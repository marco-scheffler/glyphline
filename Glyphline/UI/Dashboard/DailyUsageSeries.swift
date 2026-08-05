import Foundation

/// One day of machine-wide local token usage, priced.
///
/// The per-model breakdown is the same aggregate the statistics screen shows,
/// only narrowed to a single day — this is a sibling of `LocalUsageStatistics`,
/// not a replacement for it.
struct DailyUsageEntry: Identifiable, Equatable, Sendable {
    /// Start of the day on `LocalUsageDay.calendar`, matching how the rows are
    /// bucketed.
    var day: Date
    var statistics: LocalUsageStatistics

    var id: Date { day }

    var totalTokens: Int64 { statistics.totalTokens }

    /// Nil when nothing on this day could be priced — including a day with no
    /// rows at all. Nil is *unknown*; a zero here would read as "this was free".
    var estimatedAmountMicros: Int64? { statistics.estimatedAmountMicros }

    var currency: String? { statistics.currency }

    /// No rows landed on this day. The entry exists anyway so a chart draws a
    /// zero bar instead of silently closing the gap and shifting its x-axis.
    var isEmpty: Bool { statistics.models.isEmpty }
}

/// Machine-wide local token usage as a gap-free daily series.
///
/// The days run from the first day with rows up to today, with every silent day
/// in between present as a zero. A chart that simply skipped those days would
/// move its remaining bars along the axis and misname which day is which.
struct DailyUsageSeries: Equatable, Sendable {
    /// One entry per day, ascending, without gaps. Empty for empty input.
    var entries: [DailyUsageEntry]
    /// The whole range aggregated per model, the same figure the statistics
    /// screen shows for the period.
    var total: LocalUsageStatistics
    /// Start of the day the series was built against — today, on the user's
    /// clock.
    var referenceDay: Date

    /// Today's entry, which is a *partial* day — the clock has not finished it.
    var today: DailyUsageEntry? {
        entries.first { $0.day == referenceDay }
    }

    /// Median tokens per day over the `days` completed days ending yesterday.
    ///
    /// Today is deliberately left out: it is partial, and measuring a half
    /// finished morning against a set of complete days makes every morning look
    /// like a quiet week. Nil when the window contains no completed day.
    func median(days: Int) -> Int64? {
        guard days > 0 else { return nil }

        let window = entries
            .filter { $0.day < referenceDay }
            .suffix(days)
            .map(\.totalTokens)
            .sorted()

        guard !window.isEmpty else { return nil }

        let middle = window.count / 2
        if window.count.isMultiple(of: 2) {
            // Integer mean of the two central days; the series counts tokens,
            // so a fractional median would only be rounded away by the caller.
            return (window[middle - 1] + window[middle]) / 2
        }
        return window[middle]
    }

    /// Builds the series from raw rows.
    ///
    /// The calendar defaults to `LocalUsageDay.calendar` because that is what
    /// the stored `bucketStart` values were keyed on. Grouping them by any other
    /// one would slice a day in half and file its two parts under different,
    /// wrongly named days.
    static func from(
        rows: [LocalTokenUsage],
        estimator: CostEstimator,
        calendar: Calendar = LocalUsageDay.calendar,
        now: Date = Date(),
        providerID: ProviderID = .claude
    ) -> DailyUsageSeries {
        let referenceDay = calendar.startOfDay(for: now)
        let total = LocalUsageStatistics(rows: rows, estimator: estimator, providerID: providerID)

        var rowsByDay: [Date: [LocalTokenUsage]] = [:]
        for row in rows {
            rowsByDay[calendar.startOfDay(for: row.bucketStart), default: []].append(row)
        }

        guard let earliest = rowsByDay.keys.min() else {
            return DailyUsageSeries(entries: [], total: total, referenceDay: referenceDay)
        }

        // The last day is today, or a later day if a row somehow carries one —
        // a row must never fall outside the series it belongs to.
        let latest = max(referenceDay, rowsByDay.keys.max() ?? referenceDay)

        var entries: [DailyUsageEntry] = []
        var day = earliest
        while day <= latest {
            entries.append(DailyUsageEntry(
                day: day,
                statistics: LocalUsageStatistics(
                    rows: rowsByDay[day] ?? [],
                    estimator: estimator,
                    providerID: providerID
                )
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return DailyUsageSeries(entries: entries, total: total, referenceDay: referenceDay)
    }
}
