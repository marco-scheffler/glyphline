import Foundation

/// The cost tile's period switcher: day, week, month, half-year, year.
///
/// A sibling of `LocalUsagePeriod` rather than four more cases on it.
/// `LocalUsagePeriod.allCases` is what fills the chart's segmented picker, so
/// extending that enum would have silently grown the chart's control from three
/// segments to seven. The two controls answer different questions — "how far
/// back does the chart reach" against "what am I spending over" — and forcing
/// them to share one option list is how the two start disagreeing.
enum SpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case halfYear
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:
            "Day"
        case .week:
            "Week"
        case .month:
            "Month"
        case .halfYear:
            "6 Months"
        case .year:
            "Year"
        }
    }

    /// Length in days, today included.
    ///
    /// Fixed day counts, not calendar months or years. The baseline this tile
    /// compares against is the window immediately before the selected one, and a
    /// calendar half-year would make those two windows different lengths — 181
    /// days against 184 — so the percentage between them would be reporting the
    /// calendar as much as the spend. 182 is 26 whole weeks, which also keeps
    /// both windows carrying the same number of weekends.
    var days: Int {
        switch self {
        case .day:
            1
        case .week:
            7
        case .month:
            30
        case .halfYear:
            182
        case .year:
            365
        }
    }

    /// How the window reads inside a sentence: "Nothing recorded on this Mac
    /// *today*." / "… *in the last 30 days*."
    var windowPhrase: String {
        switch self {
        case .day:
            "today"
        default:
            "in the last \(days) days"
        }
    }

    /// The baseline window's name. `.day` never renders this — it compares
    /// against a median of completed days instead, for the reason spelled out on
    /// `SpendSummary.make` — so "the previous 1 days" is unreachable.
    var previousPhrase: String {
        "the previous \(days) days"
    }
}

/// What the cost tile shows for one period: the spend, a comparison line, and
/// the sentences it falls back to when either is missing.
///
/// Pure, and computed from a `DailyUsageSeries` rather than from a second read of
/// the ledger, so the tile and the chart can never end up describing two
/// different reads.
struct SpendSummary: Equatable, Sendable {
    /// The comparison line under the figure. `isAbove` is nil when there is
    /// nothing to compare against, so the view drops the tint rather than
    /// picking a colour for a sentence.
    struct Comparison: Equatable, Sendable {
        var text: String
        var isAbove: Bool?
    }

    var period: SpendPeriod
    /// Nil when nothing in the window could be priced. Nil is *unknown*, never
    /// free, the same rule the per-model estimates follow.
    var amountMicros: Int64?
    var currency: String?
    var totalTokens: Int64
    /// Nothing at all was recorded in the window. The view then reads
    /// `emptyText` instead of the figure: a currency-formatted zero would claim
    /// the days were scanned and quiet, which is a different fact.
    var isEmpty: Bool
    var emptyText: String?
    var comparison: Comparison
    /// Non-nil when the local scan reaches back less far than the period does,
    /// so the figure above covers fewer days than the period is named after. A
    /// "year" on a fresh install is a fortnight, and the tile says so rather
    /// than letting a fortnight pass for a year.
    var coverageText: String?

    /// Builds the tile's contents for one period.
    ///
    /// **What each period compares against.** Every period but `.day` is set
    /// against the window of the same length immediately before it — 30 days
    /// against the 30 before those. `.day` keeps the median of the last
    /// `medianDays` completed days, because today is a *partial* day: measuring
    /// a half-finished morning against a complete yesterday says nothing about
    /// spending and everything about the clock. Over seven days and more that
    /// partial day is at most a seventh of the window, which is a bias worth
    /// accepting for a baseline the reader can name.
    ///
    /// The baseline must lie **entirely** inside the scanned history. A
    /// half-scanned previous window is not a smaller previous window, it is an
    /// unknown one, and dividing by it would report a rise that is really just
    /// the edge of the scan.
    static func make(
        for period: SpendPeriod,
        series: DailyUsageSeries,
        medianDays: Int = 7,
        calendar: Calendar = LocalUsagePeriod.utcCalendar
    ) -> SpendSummary {
        let end = series.referenceDay
        let start = calendar.date(byAdding: .day, value: -(period.days - 1), to: end) ?? end

        // No upper bound on the window. A row dated in the future is a defect
        // worth seeing, which is why the chart's padding keeps one too; trimming
        // to today would quietly drop the spend it carries.
        let window = series.entries.filter { $0.day >= start }
        let totalTokens = window.reduce(Int64(0)) { $0 + $1.totalTokens }

        let isEmpty = totalTokens == 0

        return SpendSummary(
            period: period,
            amountMicros: window
                .compactMap(\.estimatedAmountMicros)
                .reduce(nil) { total, amount in (total ?? 0) + amount },
            currency: window.first(where: { $0.currency != nil })?.currency,
            totalTokens: totalTokens,
            isEmpty: isEmpty,
            emptyText: isEmpty ? "Nothing recorded on this Mac \(period.windowPhrase)." : nil,
            comparison: comparison(
                for: period,
                tokens: totalTokens,
                series: series,
                start: start,
                medianDays: medianDays,
                calendar: calendar
            ),
            coverageText: coverageText(for: period, series: series, start: start, calendar: calendar)
        )
    }

    private static func comparison(
        for period: SpendPeriod,
        tokens: Int64,
        series: DailyUsageSeries,
        start: Date,
        medianDays: Int,
        calendar: Calendar
    ) -> Comparison {
        if period == .day {
            // Reuses the Today card's own rule rather than restating it, so the
            // day view of this tile cannot start wording the comparison
            // differently from the one it replaced.
            let median = DashboardPresentation.todayVersusMedian(
                todayTokens: series.today?.totalTokens ?? 0,
                median: series.median(days: medianDays),
                days: medianDays
            )
            return Comparison(text: median.text, isAbove: median.isAbove)
        }

        guard let previousEnd = calendar.date(byAdding: .day, value: -1, to: start),
              let previousStart = calendar.date(
                  byAdding: .day,
                  value: -(period.days - 1),
                  to: previousEnd
              )
        else {
            return Comparison(text: notEnoughHistoryText(for: period), isAbove: nil)
        }

        guard let scannedFrom = series.entries.first?.day, scannedFrom <= previousStart else {
            return Comparison(text: notEnoughHistoryText(for: period), isAbove: nil)
        }

        let previousTokens = series.entries
            .filter { $0.day >= previousStart && $0.day <= previousEnd }
            .reduce(Int64(0)) { $0 + $1.totalTokens }

        guard previousTokens > 0 else {
            return Comparison(
                text: "Nothing recorded in \(period.previousPhrase).",
                isAbove: nil
            )
        }

        let change = (Double(tokens - previousTokens) / Double(previousTokens) * 100).rounded()
        guard change != 0 else {
            return Comparison(text: "Level with \(period.previousPhrase)", isAbove: nil)
        }

        let sign = change > 0 ? "+" : "−"
        return Comparison(
            text: "\(sign)\(Int(abs(change))) % vs. \(period.previousPhrase)",
            isAbove: change > 0
        )
    }

    static func notEnoughHistoryText(for period: SpendPeriod) -> String {
        "Not enough scanned history to compare against \(period.previousPhrase) yet."
    }

    private static func coverageText(
        for period: SpendPeriod,
        series: DailyUsageSeries,
        start: Date,
        calendar: Calendar
    ) -> String? {
        guard let scannedFrom = series.entries.first?.day, scannedFrom > start else { return nil }
        guard let elapsed = calendar.dateComponents(
            [.day],
            from: scannedFrom,
            to: series.referenceDay
        ).day else { return nil }

        // Inclusive of both ends, matching how `days` counts: a scan that starts
        // today covers one day, not zero.
        let covered = max(elapsed + 1, 0)
        return "Only \(covered) of \(period.days) days have been scanned so far."
    }
}
