import XCTest

@testable import Glyphline

/// The dashboard's layout has no surface a test can hold on to. These are the
/// parts of it that were extracted precisely because they can be wrong in a way
/// a reader would not notice: a padded axis, a percentage against a median, a
/// plural, and a chart's model buckets.
final class DashboardPresentationTests: XCTestCase {
    private let calendar = LocalUsagePeriod.utcCalendar

    private func day(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func entry(_ iso: String, tokens: Int64, model: String? = "claude-sonnet-5") -> DailyUsageEntry {
        DailyUsageEntry(
            day: day(iso),
            statistics: LocalUsageStatistics(
                models: [
                    LocalModelUsageStatistic(
                        model: model,
                        inputTokens: tokens,
                        cacheCreationTokens: 0,
                        cacheReadTokens: 0,
                        outputTokens: 0,
                        estimatedAmountMicros: 1_000,
                        currency: "USD"
                    ),
                ],
                estimatedAmountMicros: 1_000,
                currency: "USD"
            )
        )
    }

    private func series(_ entries: [DailyUsageEntry], reference: String) -> DailyUsageSeries {
        DailyUsageSeries(
            entries: entries,
            total: LocalUsageStatistics(models: [], estimatedAmountMicros: nil, currency: nil),
            referenceDay: day(reference)
        )
    }

    // MARK: - Padding the leading edge

    /// The one that matters: a series starting three days ago must still draw a
    /// 30-day axis, or a quiet fortnight renders as a shorter chart instead of a
    /// run of zero bars.
    func testAQuietFortnightPadsToZeroDaysRatherThanShorteningTheAxis() {
        let padded = DashboardPresentation.entries(
            of: series(
                [entry("2026-07-31T00:00:00Z", tokens: 10), entry("2026-08-01T00:00:00Z", tokens: 20)],
                reference: "2026-08-01T00:00:00Z"
            ),
            over: 30,
            calendar: calendar
        )

        XCTAssertEqual(padded.count, 30)
        XCTAssertEqual(padded.first?.day, day("2026-07-03T00:00:00Z"))
        XCTAssertEqual(padded.last?.day, day("2026-08-01T00:00:00Z"))
        // Everything before the first day with rows is present and is a zero.
        XCTAssertTrue(padded.prefix(28).allSatisfy(\.isEmpty))
        XCTAssertEqual(padded.prefix(28).map(\.totalTokens).reduce(0, +), 0)
        XCTAssertEqual(padded[28].totalTokens, 10)
        XCTAssertEqual(padded[29].totalTokens, 20)
    }

    /// A padded day is *unknown*, not free. Its cost stays nil for the same
    /// reason an unpriced model's does.
    func testAPaddedDayCarriesNoCostRatherThanAZeroOne() {
        let padded = DashboardPresentation.entries(
            of: series([entry("2026-08-01T00:00:00Z", tokens: 5)], reference: "2026-08-01T00:00:00Z"),
            over: 7,
            calendar: calendar
        )

        XCTAssertNil(padded.first?.estimatedAmountMicros)
        XCTAssertEqual(padded.first?.totalTokens, 0)
    }

    /// All time has no leading edge to pad to, so the series is left as it is.
    func testAllTimeIsLeftAlone() {
        let source = series(
            [entry("2026-07-31T00:00:00Z", tokens: 10), entry("2026-08-01T00:00:00Z", tokens: 20)],
            reference: "2026-08-01T00:00:00Z"
        )

        XCTAssertEqual(
            DashboardPresentation.entries(of: source, over: nil, calendar: calendar).map(\.day),
            source.entries.map(\.day)
        )
    }

    /// A row dated in the future is a defect worth seeing. Trimming the window
    /// to today would hide it.
    func testADayAfterTodayIsKeptRatherThanTrimmedAway() {
        let padded = DashboardPresentation.entries(
            of: series(
                [entry("2026-08-01T00:00:00Z", tokens: 3), entry("2026-08-03T00:00:00Z", tokens: 4)],
                reference: "2026-08-01T00:00:00Z"
            ),
            over: 7,
            calendar: calendar
        )

        XCTAssertEqual(padded.last?.day, day("2026-08-03T00:00:00Z"))
        XCTAssertEqual(padded.count, 9)
    }

    // MARK: - Today against the median

    func testNoCompletedDayReadsAsASentenceRatherThanABlank() {
        let comparison = DashboardPresentation.todayVersusMedian(
            todayTokens: 1_000,
            median: nil,
            days: 7
        )

        XCTAssertEqual(comparison.text, DashboardPresentation.noMedianYetText)
        XCTAssertNil(comparison.isAbove)
        XCTAssertFalse(comparison.text.contains("0"))
    }

    func testABusyDayReadsAsAPercentageAboveTheMedian() {
        let comparison = DashboardPresentation.todayVersusMedian(
            todayTokens: 138,
            median: 100,
            days: 7
        )

        XCTAssertEqual(comparison.text, "+38 % vs. 7-day median")
        XCTAssertEqual(comparison.isAbove, true)
    }

    func testAQuietDayReadsAsAPercentageBelowTheMedian() {
        let comparison = DashboardPresentation.todayVersusMedian(
            todayTokens: 50,
            median: 100,
            days: 7
        )

        XCTAssertEqual(comparison.text, "−50 % vs. 7-day median")
        XCTAssertEqual(comparison.isAbove, false)
    }

    /// A median of zero has no proportion to report. Dividing by it would be a
    /// NaN reaching the layout as a blank.
    func testAZeroMedianReadsAsASentenceRatherThanAnInfinity() {
        let comparison = DashboardPresentation.todayVersusMedian(
            todayTokens: 900,
            median: 0,
            days: 7
        )

        XCTAssertEqual(comparison.text, "Nothing recorded on the last 7 completed days.")
        XCTAssertNil(comparison.isAbove)
    }

    // MARK: - The call to action

    func testTheCallToActionIsQuietWhenNobodyIsWaiting() {
        let cta = DashboardPresentation.callToAction(waiting: 0, working: 4, resting: 2)

        XCTAssertFalse(cta.isUrgent)
        XCTAssertFalse(cta.isEmpty)
        XCTAssertEqual(cta.headline, "Nobody is waiting on you")
        XCTAssertEqual(cta.detail, "4 working · 2 resting — open the Agentverse")
    }

    func testOneWaitingAgentIsSingular() {
        let cta = DashboardPresentation.callToAction(waiting: 1, working: 0, resting: 0)

        XCTAssertTrue(cta.isUrgent)
        XCTAssertEqual(cta.headline, "1 agent is waiting on you")
    }

    func testSeveralWaitingAgentsArePlural() {
        let cta = DashboardPresentation.callToAction(waiting: 3, working: 4, resting: 2)

        XCTAssertTrue(cta.isUrgent)
        XCTAssertEqual(cta.headline, "3 agents are waiting on you")
    }

    /// A session count of zero is one of the four empty states: the button still
    /// opens the map, it simply says there is nobody in it.
    func testNoSessionsAtAllSaysSoAndStaysQuiet() {
        let cta = DashboardPresentation.callToAction(waiting: 0, working: 0, resting: 0)

        XCTAssertTrue(cta.isEmpty)
        XCTAssertFalse(cta.isUrgent)
        XCTAssertEqual(cta.headline, "No agents on this Mac")
        XCTAssertEqual(cta.detail, "Open the Agentverse")
    }

    // MARK: - Chart slices

    /// Models beyond the legend's limit are folded into one bucket, never
    /// dropped: a dropped model makes the bar shorter than the day it describes.
    func testModelsBeyondTheLegendAreFoldedIntoOneBucketRatherThanDropped() {
        let statistics = LocalUsageStatistics(
            models: [
                LocalModelUsageStatistic(
                    model: "a", inputTokens: 100, cacheCreationTokens: 0,
                    cacheReadTokens: 0, outputTokens: 0,
                    estimatedAmountMicros: 900, currency: "USD"
                ),
                LocalModelUsageStatistic(
                    model: "b", inputTokens: 30, cacheCreationTokens: 0,
                    cacheReadTokens: 0, outputTokens: 0,
                    estimatedAmountMicros: 50, currency: "USD"
                ),
                LocalModelUsageStatistic(
                    model: "c", inputTokens: 7, cacheCreationTokens: 0,
                    cacheReadTokens: 0, outputTokens: 0,
                    estimatedAmountMicros: 10, currency: "USD"
                ),
            ],
            estimatedAmountMicros: 960,
            currency: "USD"
        )
        let mix = ModelMix(statistics: statistics)
        let kept = DashboardPresentation.chartModels(from: mix, limit: 2)
        let slices = DashboardPresentation.slices(
            for: [DailyUsageEntry(day: day("2026-08-01T00:00:00Z"), statistics: statistics)],
            keeping: kept
        )

        XCTAssertEqual(kept, ["a", "b"])
        XCTAssertEqual(slices.map(\.model), ["a", "b", DashboardPresentation.otherModelsLabel])
        // The stack still adds up to the day.
        XCTAssertEqual(slices.map(\.tokens).reduce(0, +), 137)
    }

    func testAnUnnamedModelGetsAWordRatherThanABlankSwatch() {
        let statistics = LocalUsageStatistics(
            models: [
                LocalModelUsageStatistic(
                    model: nil, inputTokens: 12, cacheCreationTokens: 0,
                    cacheReadTokens: 0, outputTokens: 0,
                    estimatedAmountMicros: nil, currency: nil
                ),
            ],
            estimatedAmountMicros: nil,
            currency: nil
        )
        let slices = DashboardPresentation.slices(
            for: [DailyUsageEntry(day: day("2026-08-01T00:00:00Z"), statistics: statistics)],
            keeping: [DashboardPresentation.unknownModelLabel]
        )

        XCTAssertEqual(slices.map(\.model), [DashboardPresentation.unknownModelLabel])
    }

    // MARK: - Naming a window inside its account's card

    /// The card header names the account; the rows inside only have to name
    /// their window. These are the words the rows carry.
    func testTheWindowLabelsAreSpelledOutRatherThanAbbreviated() {
        XCTAssertEqual(DashboardPresentation.quotaWindowLabel(for: .rollingFiveHours), "5-hour")
        XCTAssertEqual(DashboardPresentation.quotaWindowLabel(for: .weekly), "Weekly")
    }

    /// Two windows stacked in one card must not read alike, or the card says one
    /// figure twice instead of two windows. Every kind, so a fourth added later
    /// cannot quietly duplicate an existing label.
    func testEveryWindowKindHasItsOwnLabel() {
        let labels = RateWindowKind.allCases.map { DashboardPresentation.quotaWindowLabel(for: $0) }

        XCTAssertEqual(Set(labels).count, labels.count, "\(labels)")
        XCTAssertFalse(labels.contains { $0.isEmpty }, "\(labels)")
    }

    // MARK: - Wording

    /// The quota cards can show percentages and pace but not the reference's
    /// "12.4M / 19.8M" — `RateWindow` carries no token cap. The caption says so
    /// rather than leaving the reader to wonder what the percentage is of.
    func testTheQuotaCaptionSaysThereIsNoTokenCapToShow() {
        let note = DashboardPresentation.quotaNoCapNote
        XCTAssertTrue(note.contains("not a token cap"), note)
        XCTAssertTrue(note.contains("percentages"), note)
    }

    /// `ModelMix` shares are over priced spend only, so a period with an
    /// unpriced model must say what the percentages are a percentage of.
    func testTheShareNoteSaysTheSharesCoverOnlyWhatCouldBePriced() {
        let note = DashboardPresentation.unpricedShareNote
        XCTAssertTrue(note.contains("priced spend only"), note)
        XCTAssertTrue(note.contains("no price on file"), note)
    }

    // MARK: - Naming a model

    /// Every identifier the pricing catalog carries has a name a person reads.
    func testEveryCatalogIdentifierHasItsFriendlyName() {
        let expected = [
            "claude-fable-5": "Fable 5",
            "claude-opus-5": "Opus 5",
            "claude-opus-4-8": "Opus 4.8",
            "claude-sonnet-5": "Sonnet 5",
            "claude-sonnet-4-6": "Sonnet 4.6",
            "claude-haiku-4-5": "Haiku 4.5",
            "gpt-5.4": "GPT-5.4",
        ]
        for (identifier, name) in expected {
            XCTAssertEqual(DashboardPresentation.modelDisplayName(identifier), name, identifier)
        }
    }

    /// The transcripts carry dated builds of the same model. The date is
    /// stripped, so a variant nobody listed still reads as its model.
    func testADatedVariantIsNamedAsItsUndatedModel() {
        XCTAssertEqual(
            DashboardPresentation.modelDisplayName("claude-haiku-4-5-20251001"),
            "Haiku 4.5"
        )
        XCTAssertEqual(
            DashboardPresentation.modelDisplayName("claude-opus-4-8-20260114"),
            "Opus 4.8"
        )
    }

    /// A suffix that is not a date must not be eaten: `claude-opus-4-8` ends in
    /// digits too, and chopping nine characters off anything would rename it.
    func testASuffixThatIsNotADateIsNotStripped() {
        XCTAssertEqual(
            DashboardPresentation.modelDisplayName("claude-opus-4-8-preview7"),
            "claude-opus-4-8-preview7"
        )
    }

    /// A model this app has never seen is the one most worth noticing, so it
    /// keeps its raw identifier rather than vanishing or going blank.
    func testAnUnknownIdentifierKeepsItsRawID() {
        XCTAssertEqual(
            DashboardPresentation.modelDisplayName("claude-mystery-9"),
            "claude-mystery-9"
        )
        XCTAssertEqual(
            DashboardPresentation.modelDisplayName("claude-mystery-9-20260114"),
            "claude-mystery-9-20260114"
        )
    }

    /// An empty identifier has nothing to print, so it falls back to the words
    /// an absent model gets instead of drawing an empty row.
    func testAnEmptyIdentifierFallsBackToTheUnknownModelLabel() {
        XCTAssertEqual(
            DashboardPresentation.modelDisplayName(""),
            DashboardPresentation.unknownModelLabel
        )
    }
}
