import XCTest
@testable import Glyphline

final class LocalUsageStatisticsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)
    private let nextDay = Date(timeIntervalSince1970: 1_800_086_400)

    private func entry(model: String, input: Int64, output: Int64) -> PricingEntry {
        PricingEntry(
            providerID: .claude,
            model: model,
            inputMicrosPerMillionTokens: input,
            outputMicrosPerMillionTokens: output,
            cacheCreationMicrosPerMillionTokens: nil,
            cacheReadMicrosPerMillionTokens: nil,
            currency: "USD",
            effectiveDate: "2026-01-01",
            source: "test"
        )
    }

    private func makeEstimator(_ entries: [PricingEntry]) -> CostEstimator {
        CostEstimator(catalog: PricingCatalog(entries: entries))
    }

    /// The test this task exists for. The screen shows one collapsed token
    /// number per model, but the money must still be computed from the four
    /// classes separately: a cache read costs a tenth of fresh input. Two models
    /// with the same total tokens split differently must not price the same.
    func testIdenticalTotalTokensWithDifferentSplitsPriceDifferently() {
        let estimator = makeEstimator([
            entry(model: "mostly-input", input: 10_000_000, output: 50_000_000),
            entry(model: "mostly-cache-read", input: 10_000_000, output: 50_000_000),
        ])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(
                    bucketStart: day,
                    model: "mostly-input",
                    inputTokens: 900_000,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 100_000,
                    outputTokens: 0
                ),
                LocalTokenUsage(
                    bucketStart: day,
                    model: "mostly-cache-read",
                    inputTokens: 100_000,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 900_000,
                    outputTokens: 0
                ),
            ],
            estimator: estimator
        )

        let mostlyInput = try? XCTUnwrap(statistics.models.first { $0.model == "mostly-input" })
        let mostlyCacheRead = try? XCTUnwrap(statistics.models.first { $0.model == "mostly-cache-read" })

        XCTAssertEqual(
            mostlyInput?.totalTokens,
            mostlyCacheRead?.totalTokens,
            "the two models must carry identical collapsed token totals"
        )
        XCTAssertNotEqual(
            mostlyInput?.estimatedAmountMicros,
            mostlyCacheRead?.estimatedAmountMicros,
            "cache reads are priced far below input; the estimate must not be derived from the token sum"
        )
        // 900_000 input at 10 micros/token-million + 100_000 cache read at a tenth of that.
        XCTAssertEqual(mostlyInput?.estimatedAmountMicros, 9_100_000)
        XCTAssertEqual(mostlyCacheRead?.estimatedAmountMicros, 1_900_000)
    }

    func testEachTokenClassIsPricedAtItsOwnRate() {
        let estimator = makeEstimator([entry(model: "m", input: 10_000_000, output: 50_000_000)])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(
                    bucketStart: day,
                    model: "m",
                    inputTokens: 1_000_000,
                    cacheCreationTokens: 1_000_000,
                    cacheReadTokens: 1_000_000,
                    outputTokens: 1_000_000
                ),
            ],
            estimator: estimator
        )

        // input 10_000_000 + cache creation 12_500_000 + cache read 1_000_000 + output 50_000_000
        XCTAssertEqual(statistics.models.first?.estimatedAmountMicros, 73_500_000)
        XCTAssertEqual(statistics.models.first?.totalTokens, 4_000_000)
        XCTAssertEqual(statistics.estimatedAmountMicros, 73_500_000)
        XCTAssertEqual(statistics.currency, "USD")
    }

    func testRowsForTheSameModelOnDifferentDaysAreSummed() {
        let estimator = makeEstimator([entry(model: "m", input: 10_000_000, output: 50_000_000)])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(bucketStart: day, model: "m", inputTokens: 3, outputTokens: 5),
                LocalTokenUsage(bucketStart: nextDay, model: "m", inputTokens: 4, outputTokens: 6),
            ],
            estimator: estimator
        )

        XCTAssertEqual(statistics.models.count, 1)
        XCTAssertEqual(statistics.models.first?.inputTokens, 7)
        XCTAssertEqual(statistics.models.first?.outputTokens, 11)
        XCTAssertEqual(statistics.totalTokens, 18)
    }

    /// A model missing from the catalog is unknown, not free. Zero would read as
    /// "this cost nothing".
    func testAnUnpricedModelYieldsTokensButNoEstimate() {
        let estimator = makeEstimator([entry(model: "known", input: 10_000_000, output: 50_000_000)])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(bucketStart: day, model: "known", inputTokens: 1_000_000),
                LocalTokenUsage(bucketStart: day, model: "stranger", inputTokens: 2_000_000),
            ],
            estimator: estimator
        )

        let stranger = try? XCTUnwrap(statistics.models.first { $0.model == "stranger" })
        XCTAssertEqual(stranger?.totalTokens, 2_000_000, "tokens are still known")
        XCTAssertNil(stranger?.estimatedAmountMicros, "an unpriced model must have no estimate, not zero")
        XCTAssertNil(stranger?.currency)
        XCTAssertEqual(stranger?.isUnpriced, true)
        XCTAssertTrue(statistics.hasUnpricedModels)
        XCTAssertEqual(
            statistics.estimatedAmountMicros,
            10_000_000,
            "the grand total covers only what could be priced"
        )
    }

    func testAModelWithoutANameIsKeptAsItsOwnUnpricedRow() {
        let estimator = makeEstimator([entry(model: "known", input: 10_000_000, output: 50_000_000)])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(bucketStart: day, model: nil, inputTokens: 7),
                LocalTokenUsage(bucketStart: nextDay, model: nil, inputTokens: 3),
            ],
            estimator: estimator
        )

        XCTAssertEqual(statistics.models.count, 1)
        XCTAssertNil(statistics.models.first?.model)
        XCTAssertEqual(statistics.models.first?.totalTokens, 10)
        XCTAssertNil(statistics.models.first?.estimatedAmountMicros)
        XCTAssertNil(statistics.estimatedAmountMicros, "nothing could be priced, so there is no grand total")
    }

    func testModelsAreSortedByEstimatedValueDescending() {
        let estimator = makeEstimator([
            entry(model: "cheap", input: 1_000_000, output: 1_000_000),
            entry(model: "dear", input: 90_000_000, output: 90_000_000),
        ])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(bucketStart: day, model: "cheap", inputTokens: 5_000_000),
                LocalTokenUsage(bucketStart: day, model: "dear", inputTokens: 1_000_000),
            ],
            estimator: estimator
        )

        XCTAssertEqual(
            statistics.models.map(\.model),
            ["dear", "cheap"],
            "the biggest estimated contributor comes first, even with fewer tokens"
        )
    }

    func testUnpricedModelsSortAfterPricedOnesAndAmongThemselvesByTokens() {
        let estimator = makeEstimator([entry(model: "known", input: 1_000_000, output: 1_000_000)])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(bucketStart: day, model: "small-stranger", inputTokens: 10),
                LocalTokenUsage(bucketStart: day, model: "big-stranger", inputTokens: 999),
                LocalTokenUsage(bucketStart: day, model: "known", inputTokens: 1),
            ],
            estimator: estimator
        )

        XCTAssertEqual(statistics.models.map(\.model), ["known", "big-stranger", "small-stranger"])
    }

    func testEmptyInputProducesNoModelsAndNoEstimate() {
        let estimator = makeEstimator([entry(model: "known", input: 1_000_000, output: 1_000_000)])
        let statistics = LocalUsageStatistics(rows: [], estimator: estimator)

        XCTAssertTrue(statistics.models.isEmpty)
        XCTAssertEqual(statistics.totalTokens, 0)
        XCTAssertNil(statistics.estimatedAmountMicros)
        XCTAssertNil(statistics.currency)
        XCTAssertFalse(statistics.hasUnpricedModels)
    }

    /// Rows stored before the reader learned to skip Claude Code's `<synthetic>`
    /// placeholder are all zeros and will never grow. They would otherwise sit in
    /// the table permanently, named after something that is not a model and can
    /// never be priced.
    func testModelsWithNoTokensAreDropped() {
        let estimator = makeEstimator([entry(model: "known", input: 1_000_000, output: 1_000_000)])

        let statistics = LocalUsageStatistics(
            rows: [
                LocalTokenUsage(bucketStart: day, model: "<synthetic>"),
                LocalTokenUsage(bucketStart: nextDay, model: "<synthetic>"),
                LocalTokenUsage(bucketStart: day, model: "known", inputTokens: 100),
            ],
            estimator: estimator
        )

        XCTAssertEqual(statistics.models.map(\.model), ["known"])
        XCTAssertFalse(statistics.hasUnpricedModels)
    }

    /// The money is an estimate of API billing, never a paid amount.
    func testDisclaimerSaysTheAmountWasNeverBilled() {
        XCTAssertTrue(LocalUsageStatistics.estimateDisclaimer.contains("Estimated"))
        XCTAssertTrue(LocalUsageStatistics.estimateDisclaimer.contains("never billed"))
    }

    /// The row's key and the store's key are the same primary-key encoding, and
    /// nothing but this test makes them move together. They were two literal
    /// copies until now: a comment claimed they matched, which is a promise the
    /// compiler cannot keep. A divergence does not raise — it produces a row
    /// that silently never joins.
    func testModelKeyMatchesTheStoreEncoding() {
        for model in ["claude-opus-5", "gpt-5.4", "", "value:weird"] {
            let row = LocalModelUsageStatistic(
                model: model,
                inputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                outputTokens: 0,
                estimatedAmountMicros: nil,
                currency: nil
            )
            XCTAssertEqual(row.modelKey, LedgerModelIdentity.makeKey(for: model))
        }

        let unnamed = LocalModelUsageStatistic(
            model: nil,
            inputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            outputTokens: 0,
            estimatedAmountMicros: nil,
            currency: nil
        )
        XCTAssertEqual(unnamed.modelKey, LedgerModelIdentity.makeKey(for: nil))
    }
}
