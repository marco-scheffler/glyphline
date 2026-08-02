import SwiftUI
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

    /// A session count of zero is one of the four empty states: the tile still
    /// opens the map, it simply says there is nobody in it.
    func testNoSessionsAtAllSaysSoAndStaysQuiet() {
        let cta = DashboardPresentation.callToAction(waiting: 0, working: 0, resting: 0)

        XCTAssertTrue(cta.isEmpty)
        XCTAssertFalse(cta.isUrgent)
        XCTAssertEqual(cta.headline, "No agents on this Mac")
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

    // MARK: - Naming a day

    /// A timezone far enough west that a UTC midnight is still the previous
    /// afternoon there — the case the panel used to get wrong.
    private var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Every day in this pipeline is a UTC midnight, so its name has to be read
    /// off the UTC calendar too.
    ///
    /// Would catch: the panel's old `entry.day.formatted(.dateTime…)`, which
    /// takes the *current* timezone and ignores the one it is handed. Under that
    /// code both calls below return the same string and the inequality fails —
    /// in Berlin as well as in Los Angeles, which is the point: a fixture that
    /// only discriminates where the machine happens to stand is no fixture.
    func testADayIsNamedInUTCRatherThanLocally() {
        let midnight = day("2026-03-15T00:00:00Z")

        XCTAssertEqual(DashboardPresentation.dayTitle(of: midnight),
                       DashboardPresentation.dayTitle(of: midnight, calendar: calendar))
        XCTAssertNotEqual(DashboardPresentation.dayTitle(of: midnight, calendar: losAngeles),
                          DashboardPresentation.dayTitle(of: midnight, calendar: calendar))
    }

    /// And it is wrong by exactly one day, which is what makes the fixture a
    /// discriminating one rather than merely a differing one: read locally in
    /// Los Angeles, this instant names the *day before* the day it stands for.
    func testReadLocallyAWesternMachineNamesThePreviousDay() {
        let midnight = day("2026-03-15T00:00:00Z")
        let dayBefore = day("2026-03-14T00:00:00Z")

        XCTAssertEqual(DashboardPresentation.dayTitle(of: midnight, calendar: losAngeles),
                       DashboardPresentation.dayTitle(of: dayBefore, calendar: calendar))
    }

    /// The axis labels bar centres, not day starts, so it survived a local
    /// formatter almost everywhere — and stopped at UTC+12, where noon UTC is
    /// already tomorrow. Would catch the axis label going back to a formatter
    /// that ignores the calendar: both calls would then agree.
    func testTheAxisLabelIsAlsoReadInUTC() {
        let centre = DashboardPresentation.barCentre(of: day("2026-03-15T00:00:00Z"))
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!

        XCTAssertEqual(DashboardPresentation.axisDayLabel(of: centre),
                       DashboardPresentation.axisDayLabel(of: centre, calendar: calendar))
        XCTAssertNotEqual(DashboardPresentation.axisDayLabel(of: centre, calendar: auckland),
                          DashboardPresentation.axisDayLabel(of: centre, calendar: calendar))
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

    // MARK: - Colouring a model

    private func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    /// The approved palette, verbatim. The scheme is what does the work — a
    /// glance says whether purple dominates the bill — and it survives only if
    /// every hue is the one the design named.
    func testEveryKnownModelKeepsItsApprovedColour() {
        let expected: [String: UInt32] = [
            "claude-fable-5": 0xff_7a_b8,
            "claude-opus-5": 0xa9_7b_ff,
            "claude-opus-4-8": 0x8a_63_d6,
            "claude-sonnet-5": 0x5b_a9_ff,
            "claude-sonnet-4-6": 0x4a_86_c8,
            "claude-haiku-4-5": 0x3d_dc_91,
        ]
        for (identifier, hex) in expected {
            XCTAssertEqual(DashboardPresentation.modelColor(identifier), color(hex), identifier)
        }
    }

    /// The dated builds are folded onto their model here exactly as they are in
    /// the naming, or Haiku would arrive in the chart twice in two colours.
    func testADatedVariantKeepsItsModelsColour() {
        XCTAssertEqual(
            DashboardPresentation.modelColor("claude-haiku-4-5-20251001"),
            DashboardPresentation.modelColor("claude-haiku-4-5")
        )
        XCTAssertEqual(
            DashboardPresentation.modelColor("claude-haiku-4-5-20251001"),
            color(0x3d_dc_91)
        )
    }

    /// A model nobody has a colour for gets grey, and grey is nobody else's.
    /// Left to the chart it would be dressed in a default hue and read as a
    /// family it does not belong to.
    func testAnUnknownModelIsGreyAndNotAKnownModelsColour() {
        let grey = color(0x8e_8e_93)
        XCTAssertEqual(DashboardPresentation.modelColor("claude-mystery-9"), grey)
        XCTAssertEqual(DashboardPresentation.modelColor("claude-mystery-9-20260114"), grey)
        XCTAssertEqual(DashboardPresentation.modelColor(""), grey)
        XCTAssertEqual(DashboardPresentation.modelColor(DashboardPresentation.otherModelsLabel), grey)

        for known in [
            "claude-fable-5", "claude-opus-5", "claude-opus-4-8",
            "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5",
        ] {
            XCTAssertNotEqual(DashboardPresentation.modelColor(known), grey, known)
        }
    }

    // MARK: - The chart's legend

    private func slice(_ model: String) -> DashboardPresentation.DayModelSlice {
        DashboardPresentation.DayModelSlice(day: day("2026-07-01T00:00:00Z"), model: model, tokens: 1)
    }

    /// The legend prints the series keys, so the keys are names and not
    /// identifiers. A legend reading `claude-haiku-4-5-20251001` is the chart
    /// showing its plumbing.
    func testTheLegendNamesItsModelsRatherThanRecitingTheirIdentifiers() {
        let scale = DashboardPresentation.chartStyleScale(for: [
            slice("claude-opus-5"),
            slice("claude-opus-4-8"),
            slice("claude-haiku-4-5-20251001"),
            slice("claude-mystery-9"),
            slice(DashboardPresentation.otherModelsLabel),
        ])

        XCTAssertEqual(
            scale.domain,
            ["Opus 5", "Opus 4.8", "Haiku 4.5", "claude-mystery-9", "Other"]
        )
        // The colour still comes from the identifier, so naming a model has not
        // recoloured it.
        XCTAssertEqual(
            scale.range,
            [
                DashboardPresentation.modelColor("claude-opus-5"),
                DashboardPresentation.modelColor("claude-opus-4-8"),
                DashboardPresentation.modelColor("claude-haiku-4-5"),
                DashboardPresentation.modelColor("claude-mystery-9"),
                DashboardPresentation.modelColor(DashboardPresentation.otherModelsLabel),
            ]
        )
    }

    /// A dated build and its undated model are one name and one colour, so they
    /// are one legend entry. Two identical entries would read as two models.
    func testTwoIdentifiersWithOneNameAreOneLegendEntry() {
        let scale = DashboardPresentation.chartStyleScale(for: [
            slice("claude-haiku-4-5"),
            slice("claude-haiku-4-5-20251001"),
        ])

        XCTAssertEqual(scale.domain, ["Haiku 4.5"])
        XCTAssertEqual(scale.range.count, 1)
        XCTAssertEqual(DashboardPresentation.chartStyleScale(for: []).domain, [])
    }

    // MARK: - The chart's x axis

    /// A run of consecutive UTC days, as `DailyUsageSeries` produces them.
    private func days(from iso: String, count: Int) -> [Date] {
        let first = day(iso)
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    /// A point `fraction` of the way across `day`'s bar, in scale units — what
    /// `ChartProxy.value(atX:)` hands back for a tap at that spot.
    private func inBar(_ day: Date, at fraction: Double) -> Date {
        day.addingTimeInterval(24 * 60 * 60 * fraction)
    }

    /// The one that matters: the bar the reader clicks is the day that gets
    /// selected, everywhere along the axis.
    ///
    /// The mapping this replaced snapped the raw scale value to the nearest day
    /// *start*, and a bar runs forward from its start — so every tap past a
    /// bar's middle fell to the following day. The 0.75 samples are what catch
    /// that; the centre sample alone would not, because a tie there resolves to
    /// the earlier day either way.
    func testATapAnywhereInABarSelectsThatBarsDay() {
        let axis = days(from: "2026-07-01T00:00:00Z", count: 30)

        for index in [0, 15, 29] {
            let bar = axis[index]
            for fraction in [0.05, 0.25, 0.5, 0.75, 0.95] {
                XCTAssertEqual(
                    DashboardPresentation.day(atChartValue: inBar(bar, at: fraction), among: axis),
                    bar,
                    "day \(index) at \(fraction) of its bar"
                )
            }
        }
    }

    /// A tap in a gap in the series belongs to no bar, and still has to select
    /// one rather than nothing.
    func testATapInAGapSnapsToTheNearestBar() {
        let axis = [day("2026-07-01T00:00:00Z"), day("2026-07-10T00:00:00Z")]
        let gap = day("2026-07-03T00:00:00Z")

        XCTAssertEqual(DashboardPresentation.day(atChartValue: gap, among: axis), axis[0])
        XCTAssertEqual(
            DashboardPresentation.day(atChartValue: day("2026-07-08T00:00:00Z"), among: axis),
            axis[1]
        )
        XCTAssertNil(DashboardPresentation.day(atChartValue: gap, among: []))
    }

    /// The centre is the middle of the span the bar actually covers, which is
    /// the day it starts on — not a tick at that day.
    func testABarsCentreIsTheMiddleOfTheDayItCovers() {
        let start = day("2026-07-01T00:00:00Z")
        XCTAssertEqual(DashboardPresentation.barEnd(of: start), day("2026-07-02T00:00:00Z"))
        XCTAssertEqual(DashboardPresentation.barCentre(of: start), day("2026-07-01T12:00:00Z"))
    }

    /// The axis is labelled on the series' own days, thinned rather than
    /// crowded, and the newest bar is always one of them.
    func testTheAxisIsLabelledOnTheSeriesOwnDaysAndAlwaysTheLast() {
        let axis = days(from: "2026-07-01T00:00:00Z", count: 30)
        let marks = DashboardPresentation.axisDays(for: axis, desiredCount: 6)

        XCTAssertEqual(marks.count, 6)
        XCTAssertEqual(marks.last, axis.last)
        XCTAssertEqual(marks, marks.sorted())
        XCTAssertTrue(marks.allSatisfy(axis.contains))

        // A short series is labelled in full; there is nothing to thin.
        let short = days(from: "2026-07-01T00:00:00Z", count: 4)
        XCTAssertEqual(DashboardPresentation.axisDays(for: short, desiredCount: 6), short)
        XCTAssertEqual(DashboardPresentation.axisDays(for: short, desiredCount: 0), [])
    }
}
