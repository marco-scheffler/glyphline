import XCTest
@testable import Glyphline

final class DailyUsageSeriesTests: XCTestCase {
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

    private func entry(model: String) -> PricingEntry {
        PricingEntry(
            providerID: .claude,
            model: model,
            inputMicrosPerMillionTokens: 1_000_000,
            outputMicrosPerMillionTokens: 1_000_000,
            cacheCreationMicrosPerMillionTokens: nil,
            cacheReadMicrosPerMillionTokens: nil,
            currency: "USD",
            effectiveDate: "2026-01-01",
            source: "test"
        )
    }

    private var estimator: CostEstimator {
        CostEstimator(catalog: PricingCatalog(entries: [entry(model: "m"), entry(model: "n")]))
    }

    // MARK: - Shape

    func testRowsAcrossThreeDaysProduceThreeEntriesInAscendingOrder() {
        let series = DailyUsageSeries.from(
            rows: [
                LocalTokenUsage(bucketStart: date("2026-07-20T00:00:00Z"), model: "m", inputTokens: 3),
                LocalTokenUsage(bucketStart: date("2026-07-18T00:00:00Z"), model: "m", inputTokens: 1),
                LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "m", inputTokens: 2),
            ],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertEqual(
            series.entries.map(\.day),
            [
                date("2026-07-18T00:00:00Z"),
                date("2026-07-19T00:00:00Z"),
                date("2026-07-20T00:00:00Z"),
            ],
            "one entry per UTC day, oldest first"
        )
        XCTAssertEqual(series.entries.map(\.totalTokens), [1, 2, 3])
        XCTAssertEqual(series.total.totalTokens, 6)
    }

    /// A gap in a bar chart that silently shifts the x-axis lies about which
    /// days are being shown, so a day without rows must be a zero bar.
    func testADayWithoutRowsInsideTheRangeAppearsWithZero() {
        let series = DailyUsageSeries.from(
            rows: [
                LocalTokenUsage(bucketStart: date("2026-07-18T00:00:00Z"), model: "m", inputTokens: 5),
                LocalTokenUsage(bucketStart: date("2026-07-20T00:00:00Z"), model: "m", inputTokens: 7),
            ],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertEqual(series.entries.count, 3, "the silent day must still occupy its slot")
        XCTAssertEqual(series.entries[1].day, date("2026-07-19T00:00:00Z"))
        XCTAssertEqual(series.entries[1].totalTokens, 0)
        XCTAssertTrue(series.entries[1].isEmpty)
        XCTAssertNil(
            series.entries[1].estimatedAmountMicros,
            "no rows means nothing to price, not a priced zero"
        )
    }

    /// The days between the last row and today are just as silent, and a chart
    /// that stops at the last busy day hides a quiet week.
    func testTheRangeRunsUpToTodayEvenWhenTheLastRowsAreOlder() {
        let series = DailyUsageSeries.from(
            rows: [
                LocalTokenUsage(bucketStart: date("2026-07-18T00:00:00Z"), model: "m", inputTokens: 5),
            ],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertEqual(series.entries.map(\.totalTokens), [5, 0, 0])
        XCTAssertEqual(series.today?.day, date("2026-07-20T00:00:00Z"))
        XCTAssertEqual(series.today?.totalTokens, 0)
    }

    func testPerModelTotalsWithinADaySumToTheDayTotal() {
        let series = DailyUsageSeries.from(
            rows: [
                LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "m", inputTokens: 40),
                LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "n", inputTokens: 2),
                LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "m", outputTokens: 60),
                // A different day must not leak into the day under test.
                LocalTokenUsage(bucketStart: date("2026-07-20T00:00:00Z"), model: "m", inputTokens: 900),
            ],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        let day = try? XCTUnwrap(series.entries.first { $0.day == self.date("2026-07-19T00:00:00Z") })
        XCTAssertEqual(day?.statistics.models.count, 2)
        XCTAssertEqual(
            day?.statistics.models.reduce(Int64(0)) { $0 + $1.totalTokens },
            day?.totalTokens,
            "the per-model rows must add up to the day's bar"
        )
        XCTAssertEqual(day?.totalTokens, 102)
        XCTAssertEqual(day?.statistics.models.first { $0.model == "m" }?.totalTokens, 100)
        XCTAssertEqual(day?.statistics.models.first { $0.model == "n" }?.totalTokens, 2)
        // 102 tokens at 1 micro per token.
        XCTAssertEqual(day?.estimatedAmountMicros, 102)
    }

    // MARK: - Median

    /// Today is a partial day. Measuring a half-finished morning against a set
    /// of complete days makes every morning look like a quiet week.
    func testMedianOverSevenDaysReturnsTheKnownMedianAndIgnoresToday() {
        var rows: [LocalTokenUsage] = [
            // 2026-07-13 … 2026-07-19, totals 1…7 hundred tokens.
            LocalTokenUsage(bucketStart: date("2026-07-13T00:00:00Z"), model: "m", inputTokens: 100),
            LocalTokenUsage(bucketStart: date("2026-07-14T00:00:00Z"), model: "m", inputTokens: 200),
            LocalTokenUsage(bucketStart: date("2026-07-15T00:00:00Z"), model: "m", inputTokens: 300),
            LocalTokenUsage(bucketStart: date("2026-07-16T00:00:00Z"), model: "m", inputTokens: 400),
            LocalTokenUsage(bucketStart: date("2026-07-17T00:00:00Z"), model: "m", inputTokens: 500),
            LocalTokenUsage(bucketStart: date("2026-07-18T00:00:00Z"), model: "m", inputTokens: 600),
            LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "m", inputTokens: 700),
        ]
        // Today, far off the scale: including it would move the median to 450.
        rows.append(LocalTokenUsage(bucketStart: date("2026-07-20T00:00:00Z"), model: "m", inputTokens: 99_999))

        let series = DailyUsageSeries.from(
            rows: rows,
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertEqual(series.median(days: 7), 400, "median of 100…700, with today left out")
        XCTAssertEqual(series.today?.totalTokens, 99_999)
    }

    /// The window is the completed days, so a shorter window sees fewer of them.
    func testMedianWindowIsBoundedByTheRequestedNumberOfDays() {
        let series = DailyUsageSeries.from(
            rows: [
                LocalTokenUsage(bucketStart: date("2026-07-13T00:00:00Z"), model: "m", inputTokens: 100),
                LocalTokenUsage(bucketStart: date("2026-07-18T00:00:00Z"), model: "m", inputTokens: 600),
                LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "m", inputTokens: 700),
            ],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertEqual(series.median(days: 2), 650, "only 2026-07-18 and 2026-07-19 are in the window")
    }

    func testMedianIsNilWithoutAnyCompletedDay() {
        let series = DailyUsageSeries.from(
            rows: [
                LocalTokenUsage(bucketStart: date("2026-07-20T00:00:00Z"), model: "m", inputTokens: 5),
            ],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertNil(series.median(days: 7), "today alone is not a completed day")
    }

    // MARK: - Empty

    func testEmptyInputProducesAnEmptySeries() {
        let series = DailyUsageSeries.from(
            rows: [],
            estimator: estimator,
            now: date("2026-07-20T09:00:00Z")
        )

        XCTAssertTrue(series.entries.isEmpty)
        XCTAssertEqual(series.total.totalTokens, 0)
        XCTAssertNil(series.today)
        XCTAssertNil(series.median(days: 7))
    }

    // MARK: - UTC

    /// The stored buckets are UTC day starts, and the grouping must be UTC too.
    /// The fixture is picked so a local calendar cannot agree: 23:00 UTC is the
    /// same UTC day as 00:00 UTC but the next day in Berlin, and Berlin's start
    /// of day is 22:00 UTC, not midnight. A grouping that used the local
    /// calendar would split this into two entries with the wrong day keys.
    func testGroupingUsesUTCAndNotTheLocalCalendar() {
        let rows = [
            LocalTokenUsage(bucketStart: date("2026-07-19T00:00:00Z"), model: "m", inputTokens: 10),
            LocalTokenUsage(bucketStart: date("2026-07-19T23:00:00Z"), model: "m", inputTokens: 5),
        ]

        let series = DailyUsageSeries.from(
            rows: rows,
            estimator: estimator,
            now: date("2026-07-19T23:30:00Z")
        )

        XCTAssertEqual(series.entries.count, 1, "both instants fall on the same UTC day")
        XCTAssertEqual(
            series.entries.first?.day,
            date("2026-07-19T00:00:00Z"),
            "the day key is UTC midnight, not a local start of day"
        )
        XCTAssertEqual(series.entries.first?.totalTokens, 15)

        // The same fixture under a local calendar, to show the assertion above
        // is discriminating rather than true either way.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let localSeries = DailyUsageSeries.from(
            rows: rows,
            estimator: estimator,
            calendar: berlin,
            now: date("2026-07-19T23:30:00Z")
        )

        XCTAssertEqual(localSeries.entries.count, 2, "a local calendar slices the UTC day — this is the bug")
        XCTAssertNotEqual(localSeries.entries.first?.day, self.date("2026-07-19T00:00:00Z"))
    }
}
