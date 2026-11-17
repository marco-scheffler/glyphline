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

    func testBundledCatalogPricesEveryClaudeModelSeenInLocalTranscripts() throws {
        let catalog = try PricingCatalog.bundled()

        // The models the local scan actually found on this machine. A miss here
        // renders as "No price on file" and drops that model out of the total.
        let models = [
            "claude-fable-5-2",
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-sonnet-5-5",
            "claude-haiku-5-5",
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-sonnet-4-6",
            "claude-haiku-4-5-20251001",
        ]

        for model in models {
            let entry = try XCTUnwrap(
                catalog.entry(providerID: .claude, model: model),
                "no pricing for \(model)"
            )
            XCTAssertGreaterThan(entry.inputMicrosPerMillionTokens, 0, "\(model) input price")
            XCTAssertGreaterThan(entry.outputMicrosPerMillionTokens, 0, "\(model) output price")
        }
    }

    /// Pins the four published rates of each current model, so a typo in the
    /// catalog — one zero too many or too few — fails here instead of shipping
    /// as a plausible-looking figure. Values are Anthropic's API pricing page
    /// as of 2026-11-17, cache creation at the 5-minute write rate.
    func testBundledCatalogCarriesThePublishedRatesOfTheCurrentModels() throws {
        let catalog = try PricingCatalog.bundled()

        // model: (input, output, cache creation, cache read) in micros per MTok
        let published: [String: (Int64, Int64, Int64, Int64)] = [
            "claude-fable-5-2": (8_000_000, 40_000_000, 10_000_000, 200_000),
            "claude-fable-5-1": (10_000_000, 50_000_000, 12_500_000, 250_000),
            "claude-opus-5-5": (4_000_000, 20_000_000, 5_000_000, 200_000),
            "claude-sonnet-5-5": (2_000_000, 10_000_000, 2_500_000, 100_000),
            // The rate for prompts up to 100,000 tokens; see known-issues.
            "claude-haiku-5-5": (100_000, 500_000, 125_000, 10_000),
            // The introductory rate became the standard one.
            "claude-sonnet-5": (2_000_000, 10_000_000, 2_500_000, 200_000),
        ]

        for (model, rates) in published {
            let entry = try XCTUnwrap(
                catalog.entry(providerID: .claude, model: model),
                "no pricing for \(model)"
            )
            XCTAssertEqual(entry.model, model, "\(model) must match exactly, not via a fallback")
            XCTAssertEqual(entry.inputMicrosPerMillionTokens, rates.0, "\(model) input")
            XCTAssertEqual(entry.outputMicrosPerMillionTokens, rates.1, "\(model) output")
            XCTAssertEqual(entry.cacheCreationMicrosPerMillionTokens, rates.2, "\(model) cache creation")
            XCTAssertEqual(entry.cacheReadMicrosPerMillionTokens, rates.3, "\(model) cache read")
            XCTAssertEqual(entry.currency, "USD", "\(model) currency")
        }
    }

    /// The case that showed "—" for a whole day: Opus 5.5 tokens priced end to
    /// end through the bundled catalog, all four token classes at their own rate.
    func testBundledCatalogPricesADayOfOpus55Usage() throws {
        let estimator = try CostEstimator(catalog: PricingCatalog.bundled())
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = UsageSnapshot(
            id: UUID(),
            accountID: UUID(),
            providerID: .claude,
            bucketStart: day,
            bucketEnd: day.addingTimeInterval(86_400),
            model: "claude-opus-5-5",
            inputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            outputTokens: 1_000_000,
            requests: nil,
            quality: .exact
        )

        let estimate = try estimator.estimate(snapshot: usage)

        // 4_000_000 + 5_000_000 + 200_000 + 20_000_000
        XCTAssertEqual(estimate.estimatedAmountMicros, 29_200_000)
        XCTAssertEqual(estimate.currency, "USD")
    }

    /// A dated snapshot id is the alias plus `-YYYYMMDD` and names the same model
    /// at the same price, so the catalog answers for both.
    func testDatedSnapshotIDFallsBackToTheAliasEntry() {
        let catalog = PricingCatalog(entries: [
            PricingEntry(
                providerID: .claude,
                model: "claude-haiku-4-5",
                inputMicrosPerMillionTokens: 1_000_000,
                outputMicrosPerMillionTokens: 5_000_000,
                currency: "USD",
                effectiveDate: "2026-07-27",
                source: "local"
            )
        ])

        XCTAssertEqual(
            catalog.entry(providerID: .claude, model: "claude-haiku-4-5-20251001")?.model,
            "claude-haiku-4-5"
        )
    }

    /// The fallback must not turn every near-miss into a match, or an unknown
    /// model would silently borrow another model's price.
    func testOnlyADateSuffixFallsBackToTheAlias() {
        let catalog = PricingCatalog(entries: [
            PricingEntry(
                providerID: .claude,
                model: "claude-haiku-4-5",
                inputMicrosPerMillionTokens: 1_000_000,
                outputMicrosPerMillionTokens: 5_000_000,
                currency: "USD",
                effectiveDate: "2026-07-27",
                source: "local"
            )
        ])

        // Eight characters, but not digits.
        XCTAssertNil(catalog.entry(providerID: .claude, model: "claude-haiku-4-5-preview1"))
        // Digits, but not eight of them.
        XCTAssertNil(catalog.entry(providerID: .claude, model: "claude-haiku-4-5-2025"))
        // A different model that merely shares the prefix.
        XCTAssertNil(catalog.entry(providerID: .claude, model: "claude-haiku-4-5-turbo"))
        // Right shape, wrong provider.
        XCTAssertNil(catalog.entry(providerID: .openAI, model: "claude-haiku-4-5-20251001"))
    }

    /// An explicitly priced snapshot must win over its alias, otherwise a
    /// deliberate per-snapshot price could never take effect.
    func testExactSnapshotEntryWinsOverTheAlias() {
        let catalog = PricingCatalog(entries: [
            PricingEntry(
                providerID: .claude,
                model: "claude-haiku-4-5",
                inputMicrosPerMillionTokens: 1_000_000,
                outputMicrosPerMillionTokens: 5_000_000,
                currency: "USD",
                effectiveDate: "2026-07-27",
                source: "local"
            ),
            PricingEntry(
                providerID: .claude,
                model: "claude-haiku-4-5-20251001",
                inputMicrosPerMillionTokens: 2_000_000,
                outputMicrosPerMillionTokens: 9_000_000,
                currency: "USD",
                effectiveDate: "2026-07-27",
                source: "local"
            ),
        ])

        XCTAssertEqual(
            catalog.entry(providerID: .claude, model: "claude-haiku-4-5-20251001")?
                .inputMicrosPerMillionTokens,
            2_000_000
        )
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
