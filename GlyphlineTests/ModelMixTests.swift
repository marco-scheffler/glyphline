import XCTest
@testable import Glyphline

final class ModelMixTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    /// The real pricing-v1 figures for the two models the ranking rule is about,
    /// plus one middle model. Fable is ten times Haiku on output, which is the
    /// whole reason cost and volume disagree.
    private var estimator: CostEstimator {
        CostEstimator(catalog: PricingCatalog(entries: [
            entry(model: "claude-fable-5", input: 10_000_000, output: 50_000_000),
            entry(model: "claude-opus-5", input: 5_000_000, output: 25_000_000),
            entry(model: "claude-haiku-4-5", input: 1_000_000, output: 5_000_000)
        ]))
    }

    private func entry(model: String, input: Int64, output: Int64) -> PricingEntry {
        PricingEntry(
            providerID: .claude,
            model: model,
            inputMicrosPerMillionTokens: input,
            outputMicrosPerMillionTokens: output,
            cacheCreationMicrosPerMillionTokens: input * 5 / 4,
            cacheReadMicrosPerMillionTokens: input / 10,
            currency: "USD",
            effectiveDate: "2026-07-30",
            source: "test"
        )
    }

    private func row(model: String?, output: Int64) -> LocalTokenUsage {
        LocalTokenUsage(bucketStart: day, model: model, outputTokens: output)
    }

    private func entry(named model: String?, in mix: ModelMix) -> ModelMixEntry? {
        mix.entries.first { $0.model == model }
    }

    // The point of the card: ranked by cost, not by volume.
    func testASmallNumberOfExpensiveTokensOutranksALargeNumberOfCheapOnes() {
        // 2M Fable output = $100. 10M Haiku output = $50. Five times the tokens,
        // half the money — so a volume ranking puts these in the other order.
        let mix = ModelMix.from(
            rows: [row(model: "claude-haiku-4-5", output: 10_000_000),
                   row(model: "claude-fable-5", output: 2_000_000)],
            estimator: estimator
        )

        guard let fable = entry(named: "claude-fable-5", in: mix),
              let haiku = entry(named: "claude-haiku-4-5", in: mix) else {
            return XCTFail("both models must appear in the mix")
        }

        // Guards on the fixture itself: without these the assertion below would
        // also pass under a volume ranking and would prove nothing.
        XCTAssertLessThan(fable.totalTokens, haiku.totalTokens)
        XCTAssertGreaterThan(fable.estimatedAmountMicros ?? 0, haiku.estimatedAmountMicros ?? 0)

        XCTAssertEqual(mix.entries.map(\.model), ["claude-fable-5", "claude-haiku-4-5"])
        XCTAssertEqual(fable.estimatedAmountMicros, 100_000_000)
        XCTAssertEqual(haiku.estimatedAmountMicros, 50_000_000)
    }

    func testSharesOfSpendSumToOneHundredPercent() {
        // Deliberately not a round split: $100 / $17.5 / $3 of $120.5.
        let mix = ModelMix.from(
            rows: [row(model: "claude-fable-5", output: 2_000_000),
                   row(model: "claude-opus-5", output: 700_000),
                   row(model: "claude-haiku-4-5", output: 600_000)],
            estimator: estimator
        )

        XCTAssertEqual(mix.entries.count, 3)
        let total = mix.entries.compactMap(\.shareOfSpend).reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 1e-9)
        XCTAssertEqual(mix.entries.compactMap(\.sharePercent).reduce(0, +), 100.0, accuracy: 1e-7)

        // And the shares are the real proportions, not three equal thirds.
        XCTAssertEqual(entry(named: "claude-fable-5", in: mix)?.shareOfSpend ?? 0,
                       100_000_000.0 / 120_500_000.0, accuracy: 1e-9)
        XCTAssertEqual(entry(named: "claude-haiku-4-5", in: mix)?.shareOfSpend ?? 0,
                       3_000_000.0 / 120_500_000.0, accuracy: 1e-9)
    }

    // A model that cannot be priced is exactly the one worth noticing: dropping
    // it makes the total quietly wrong and the card quietly complete-looking.
    func testAModelMissingFromThePricingCatalogStillAppearsWithUnknownCost() {
        let mix = ModelMix.from(
            rows: [row(model: "claude-fable-5", output: 1_000_000),
                   row(model: "some-unlisted-model", output: 9_000_000)],
            estimator: estimator
        )

        guard let unpriced = entry(named: "some-unlisted-model", in: mix) else {
            return XCTFail("an unpriced model must still appear")
        }

        XCTAssertEqual(unpriced.totalTokens, 9_000_000)
        XCTAssertNil(unpriced.estimatedAmountMicros)
        XCTAssertTrue(unpriced.isUnpriced)
        // Unknown, never zero — a zero share would read as "this cost nothing".
        XCTAssertNil(unpriced.shareOfSpend)
        XCTAssertNil(unpriced.sharePercent)

        // It ranks last (no cost to rank by) but is counted in the tokens, and
        // the mix says out loud that the money is incomplete.
        XCTAssertEqual(mix.entries.map(\.model), ["claude-fable-5", "some-unlisted-model"])
        XCTAssertEqual(mix.totalTokens, 10_000_000)
        XCTAssertTrue(mix.hasUnpricedModels)
        XCTAssertEqual(mix.estimatedAmountMicros, 50_000_000)
    }

    func testEmptyInputProducesAnEmptyMix() {
        let mix = ModelMix.from(rows: [], estimator: estimator)

        XCTAssertTrue(mix.entries.isEmpty)
        XCTAssertTrue(mix.isEmpty)
        XCTAssertEqual(mix.totalTokens, 0)
        XCTAssertNil(mix.estimatedAmountMicros)
        XCTAssertFalse(mix.hasUnpricedModels)
    }
}
