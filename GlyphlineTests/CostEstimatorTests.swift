import XCTest
@testable import Glyphline

final class CostEstimatorTests: XCTestCase {
    func testEstimatesOpenAITokenCostInMicros() throws {
        let catalog = PricingCatalog(entries: [
            PricingEntry(
                providerID: .openAI,
                model: "gpt-5.4",
                inputMicrosPerMillionTokens: 2_500_000,
                outputMicrosPerMillionTokens: 15_000_000,
                currency: "USD",
                effectiveDate: "2026-07-27",
                source: "local"
            )
        ])
        let estimator = CostEstimator(catalog: catalog)
        let usage = UsageSnapshot(
            id: UUID(),
            accountID: UUID(),
            providerID: .openAI,
            bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
            bucketEnd: Date(timeIntervalSince1970: 1_700_003_600),
            model: "gpt-5.4",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            requests: 1,
            quality: .exact
        )

        let estimate = try estimator.estimate(snapshot: usage)

        XCTAssertEqual(estimate.estimatedAmountMicros, 17_500_000)
        XCTAssertEqual(estimate.currency, "USD")
        XCTAssertEqual(estimate.quality, .estimated)
    }

    func testThrowsMissingPricingWhenCatalogDoesNotContainEntry() {
        let catalog = PricingCatalog(entries: [])
        let estimator = CostEstimator(catalog: catalog)
        let usage = UsageSnapshot(
            id: UUID(),
            accountID: UUID(),
            providerID: .openAI,
            bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
            bucketEnd: Date(timeIntervalSince1970: 1_700_003_600),
            model: "gpt-5.4",
            inputTokens: 1_000,
            outputTokens: 2_000,
            requests: 1,
            quality: .exact
        )

        XCTAssertThrowsError(try estimator.estimate(snapshot: usage)) { error in
            XCTAssertEqual(
                error as? CostEstimatorError,
                .missingPricing(providerID: .openAI, model: "gpt-5.4")
            )
        }
    }

    func testLoadsBundledPricingCatalogFromResourceBundle() throws {
        let catalog = try PricingCatalog.bundled(in: .main)

        let entry = try XCTUnwrap(catalog.entry(providerID: .openAI, model: "gpt-5.4"))

        XCTAssertEqual(entry.providerID, .openAI)
        XCTAssertEqual(entry.model, "gpt-5.4")
        XCTAssertEqual(entry.currency, "USD")
    }

    func testEstimatePricesEachTokenClassSeparately() throws {
        let catalog = PricingCatalog(entries: [
            PricingEntry(
                providerID: .claude,
                model: "claude-opus-4-8",
                inputMicrosPerMillionTokens: 5_000_000,
                outputMicrosPerMillionTokens: 25_000_000,
                cacheCreationMicrosPerMillionTokens: 6_250_000,
                cacheReadMicrosPerMillionTokens: 500_000,
                currency: "USD",
                effectiveDate: "2026-07-27",
                source: "local"
            ),
        ])
        let estimator = CostEstimator(catalog: catalog)
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        let usage = UsageSnapshot(
            id: UUID(),
            accountID: UUID(),
            providerID: .claude,
            bucketStart: day,
            bucketEnd: day.addingTimeInterval(86_400),
            model: "claude-opus-4-8",
            inputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            outputTokens: 1_000_000,
            requests: nil,
            quality: .exact
        )

        let estimate = try estimator.estimate(snapshot: usage)

        // 5_000_000 + 6_250_000 + 500_000 + 25_000_000
        XCTAssertEqual(estimate.estimatedAmountMicros, 36_750_000)
        XCTAssertEqual(estimate.quality, .estimated)
    }

    func testCachePricesFallBackToRatiosOfInputPrice() throws {
        let entry = PricingEntry(
            providerID: .openAI,
            model: "gpt-5.4",
            inputMicrosPerMillionTokens: 2_000_000,
            outputMicrosPerMillionTokens: 8_000_000,
            cacheCreationMicrosPerMillionTokens: nil,
            cacheReadMicrosPerMillionTokens: nil,
            currency: "USD",
            effectiveDate: "2026-07-27",
            source: "local"
        )

        XCTAssertEqual(entry.effectiveCacheCreationMicrosPerMillionTokens, 2_500_000)
        XCTAssertEqual(entry.effectiveCacheReadMicrosPerMillionTokens, 200_000)
    }

    func testBundledClaudeEntriesCarryExplicitCachePrices() throws {
        let catalog = try PricingCatalog.bundled()
        let entry = try XCTUnwrap(
            catalog.entry(providerID: .claude, model: "claude-opus-4-8"),
            "expected a bundled Claude entry"
        )

        XCTAssertNotNil(entry.cacheCreationMicrosPerMillionTokens)
        XCTAssertNotNil(entry.cacheReadMicrosPerMillionTokens)
        XCTAssertLessThan(
            entry.effectiveCacheReadMicrosPerMillionTokens,
            entry.inputMicrosPerMillionTokens / 2
        )
    }
}
