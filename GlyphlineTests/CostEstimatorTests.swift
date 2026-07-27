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
}
