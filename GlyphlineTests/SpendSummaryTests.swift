import XCTest

@testable import Glyphline

/// The cost tile's arithmetic: which days each period covers, what it compares
/// against, what it says when there is nothing there, and what it says when the
/// local scan reaches back less far than the period does.
final class SpendSummaryTests: XCTestCase {
    /// A fixed grid rather than `LocalUsageDay.calendar`, and fixed on UTC so
    /// that no fixture below ever spans a clock change. What these tests are
    /// about is which days a window covers and what it is compared against —
    /// arithmetic that must come out the same on a machine in Auckland as on one
    /// in Los Angeles. Where the grid itself is the subject, the test names its
    /// own calendar.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func day(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// A gap-free run of days ending on `reference`, each carrying `tokens[i]`
    /// tokens and one micro of spend per token, oldest first.
    private func series(endingOn reference: String, tokens: [Int64]) -> DailyUsageSeries {
        let end = day(reference)
        let entries = tokens.enumerated().map { offset, count -> DailyUsageEntry in
            let date = calendar.date(
                byAdding: .day,
                value: -(tokens.count - 1 - offset),
                to: end
            )!
            return DailyUsageEntry(
                day: date,
                statistics: LocalUsageStatistics(
                    models: [
                        LocalModelUsageStatistic(
                            model: "claude-sonnet-5",
                            inputTokens: count,
                            cacheCreationTokens: 0,
                            cacheReadTokens: 0,
                            outputTokens: 0,
                            estimatedAmountMicros: count,
                            currency: "USD"
                        ),
                    ],
                    estimatedAmountMicros: count,
                    currency: "USD"
                )
            )
        }

        return DailyUsageSeries(
            entries: entries,
            total: LocalUsageStatistics(models: [], estimatedAmountMicros: nil, currency: nil),
            referenceDay: end
        )
    }

    private static let reference = "2026-08-02T00:00:00Z"

    // MARK: - The date range each period covers

    /// Each period sums exactly its own `days`, today included. A window one day
    /// too long or too short would still look like a plausible figure, which is
    /// why the fixture gives every day a different token count.
    func testEachPeriodSumsExactlyItsOwnNumberOfDaysEndingToday() {
        // 400 days of history, day n back carrying (n + 1) tokens.
        let counts: [Int64] = (0..<400).reversed().map { Int64($0 + 1) }
        let history = series(endingOn: Self.reference, tokens: counts)

        // Today carries 1, yesterday 2, and so on, so a window of N days sums to
        // 1 + 2 + … + N.
        func expected(_ days: Int) -> Int64 { Int64(days) * Int64(days + 1) / 2 }

        for period in SpendPeriod.allCases {
            let summary = SpendSummary.make(for: period, series: history, calendar: calendar)
            XCTAssertEqual(
                summary.totalTokens,
                expected(period.days),
                "\(period) covered the wrong number of days"
            )
            // One micro per token in the fixture, so the money follows the same
            // window and is not summed over some other range.
            XCTAssertEqual(summary.amountMicros, expected(period.days), "\(period) priced the wrong window")
            XCTAssertEqual(summary.currency, "USD")
        }
    }

    /// The half-year is 182 days and the year 365 — fixed day counts, not
    /// calendar months. A calendar half-year would make the current and previous
    /// windows different lengths.
    func testThePeriodLengthsAreTheFixedDayCountsTheComparisonNeeds() {
        XCTAssertEqual(SpendPeriod.allCases.map(\.days), [1, 7, 30, 182, 365])
    }

    func testTheDayPeriodCoversTodayAloneAndNotYesterday() {
        let history = series(endingOn: Self.reference, tokens: [500, 7])
        let summary = SpendSummary.make(for: .day, series: history, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, 7)
        XCTAssertEqual(summary.amountMicros, 7)
    }

    // MARK: - The comparison baseline

    /// A week is set against the seven days immediately before it, not against a
    /// median and not against the whole history.
    func testAWeekIsComparedAgainstThePrecedingSevenDays() {
        // Fourteen days: the older seven carry 10 each (70), the newer seven 14
        // each (98). 98 against 70 is +40 %.
        let history = series(
            endingOn: Self.reference,
            tokens: Array(repeating: 10, count: 7) + Array(repeating: 14, count: 7)
        )
        let summary = SpendSummary.make(for: .week, series: history, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, 98)
        XCTAssertEqual(summary.comparison.text, "+40 % vs. the previous 7 days")
        XCTAssertEqual(summary.comparison.isAbove, true)
    }

    func testAQuieterWeekReadsAsAPercentageBelowThePrecedingSeven() {
        let history = series(
            endingOn: Self.reference,
            tokens: Array(repeating: 20, count: 7) + Array(repeating: 5, count: 7)
        )
        let summary = SpendSummary.make(for: .week, series: history, calendar: calendar)

        XCTAssertEqual(summary.comparison.text, "−75 % vs. the previous 7 days")
        XCTAssertEqual(summary.comparison.isAbove, false)
    }

    /// The day period keeps the median of completed days rather than measuring a
    /// partial morning against a complete yesterday.
    func testTheDayPeriodIsComparedAgainstTheMedianOfCompletedDays() {
        // Seven completed days of 100, then a today of 138.
        let history = series(
            endingOn: Self.reference,
            tokens: Array(repeating: 100, count: 7) + [138]
        )
        let summary = SpendSummary.make(for: .day, series: history, calendar: calendar)

        XCTAssertEqual(summary.comparison.text, "+38 % vs. 7-day median")
        XCTAssertEqual(summary.comparison.isAbove, true)
        // Not the previous-window wording: a single previous day is both partial
        // in the wrong direction and far too noisy.
        XCTAssertFalse(summary.comparison.text.contains("previous"), summary.comparison.text)
    }

    /// The baseline has to lie entirely inside the scanned history. A
    /// half-scanned previous window would report a rise that is really the edge
    /// of the scan.
    func testAPartlyScannedBaselineIsRefusedRatherThanDividedBy() {
        // Ten days of history: the current week is fully covered, the previous
        // week only three days of it.
        let history = series(endingOn: Self.reference, tokens: Array(repeating: 10, count: 10))
        let summary = SpendSummary.make(for: .week, series: history, calendar: calendar)

        XCTAssertEqual(summary.comparison.text, SpendSummary.notEnoughHistoryText(for: .week))
        XCTAssertNil(summary.comparison.isAbove)
        XCTAssertFalse(summary.comparison.text.contains("%"), summary.comparison.text)
    }

    /// Exactly fourteen days is the first history that can carry a week's
    /// baseline — the boundary the refusal above is drawn at.
    func testExactlyTwoWeeksOfHistoryIsEnoughForAWeeksBaseline() {
        let history = series(endingOn: Self.reference, tokens: Array(repeating: 10, count: 14))
        let summary = SpendSummary.make(for: .week, series: history, calendar: calendar)

        XCTAssertEqual(summary.comparison.text, "Level with the previous 7 days")
        XCTAssertNil(summary.comparison.isAbove)
    }

    /// A fully scanned but silent baseline is a sentence, not a division by zero.
    func testASilentBaselineReadsAsASentenceRatherThanAnInfinity() {
        let history = series(
            endingOn: Self.reference,
            tokens: Array(repeating: 0, count: 7) + Array(repeating: 9, count: 7)
        )
        let summary = SpendSummary.make(for: .week, series: history, calendar: calendar)

        XCTAssertEqual(summary.comparison.text, "Nothing recorded in the previous 7 days.")
        XCTAssertNil(summary.comparison.isAbove)
    }

    // MARK: - The empty period

    /// A period with no data reads as a sentence. A formatted zero would claim
    /// the days were scanned and quiet, which is a different fact.
    func testAPeriodWithNoDataReadsAsASentenceRatherThanAZero() {
        let history = DailyUsageSeries(
            entries: [],
            total: LocalUsageStatistics(models: [], estimatedAmountMicros: nil, currency: nil),
            referenceDay: day(Self.reference)
        )
        let summary = SpendSummary.make(for: .month, series: history, calendar: calendar)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.emptyText, "Nothing recorded on this Mac in the last 30 days.")
        XCTAssertEqual(summary.totalTokens, 0)
        XCTAssertNil(summary.amountMicros)
    }

    func testAnEmptyDayNamesTheDayRatherThanAWindowOfOne() {
        let history = DailyUsageSeries(
            entries: [],
            total: LocalUsageStatistics(models: [], estimatedAmountMicros: nil, currency: nil),
            referenceDay: day(Self.reference)
        )
        let summary = SpendSummary.make(for: .day, series: history, calendar: calendar)

        XCTAssertEqual(summary.emptyText, "Nothing recorded on this Mac today.")
    }

    /// A window whose days exist but carry nothing is empty too — the tile must
    /// not print a currency-formatted zero for it either.
    func testAScannedButSilentWindowIsStillEmpty() {
        let history = series(endingOn: Self.reference, tokens: Array(repeating: 0, count: 40))
        let summary = SpendSummary.make(for: .month, series: history, calendar: calendar)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertNotNil(summary.emptyText)
    }

    // MARK: - A period longer than the scanned history

    /// The one the brief turns on: a year on a fresh install is a fortnight, and
    /// the tile reports the fortnight rather than implying a year of history.
    func testAYearOnAFortnightOfHistoryReportsTheFortnightAndSaysSo() {
        let history = series(endingOn: Self.reference, tokens: Array(repeating: 100, count: 14))
        let summary = SpendSummary.make(for: .year, series: history, calendar: calendar)

        // The figure is the fourteen days that exist, never scaled up to 365.
        XCTAssertEqual(summary.totalTokens, 1_400)
        XCTAssertEqual(summary.coverageText, "Only 14 of 365 days have been scanned so far.")
        // And no percentage is invented against a baseline that was never scanned.
        XCTAssertEqual(summary.comparison.text, SpendSummary.notEnoughHistoryText(for: .year))
        XCTAssertNil(summary.comparison.isAbove)
    }

    /// The note appears only when the scan really does start inside the window.
    /// A history that covers the period says nothing, or it would be crying wolf
    /// on every screen.
    func testAFullyScannedPeriodCarriesNoCoverageNote() {
        let history = series(endingOn: Self.reference, tokens: Array(repeating: 100, count: 60))

        XCTAssertNil(SpendSummary.make(for: .month, series: history, calendar: calendar).coverageText)
        XCTAssertNil(SpendSummary.make(for: .week, series: history, calendar: calendar).coverageText)
        XCTAssertNotNil(
            SpendSummary.make(for: .halfYear, series: history, calendar: calendar).coverageText
        )
    }

    /// The boundary: history starting exactly on the window's first day is full
    /// coverage, not partial.
    func testHistoryStartingOnTheWindowsFirstDayIsFullCoverage() {
        let history = series(endingOn: Self.reference, tokens: Array(repeating: 100, count: 30))

        XCTAssertNil(SpendSummary.make(for: .month, series: history, calendar: calendar).coverageText)
        XCTAssertEqual(
            SpendSummary.make(for: .month, series: history, calendar: calendar).totalTokens,
            3_000
        )
    }

    // MARK: - Titles

    func testEveryPeriodHasItsOwnTitle() {
        let titles = SpendPeriod.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, SpendPeriod.allCases.count)
        XCTAssertEqual(titles, ["Day", "Week", "Month", "6 Months", "Year"])
    }
}
