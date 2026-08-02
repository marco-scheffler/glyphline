import Foundation

/// One model's share of the machine-wide local token usage.
///
/// `totalTokens` collapses the four token classes into a single figure because
/// that is what the screen shows. `estimatedAmountMicros` is *not* derived from
/// it: input, output, cache-creation and cache-read tokens are priced very
/// differently — a cache read costs roughly a tenth of fresh input — so the
/// money is computed from the four classes separately. Collapsing that maths
/// would produce a confidently wrong number.
struct LocalModelUsageStatistic: Identifiable, Equatable, Sendable {
    var model: String?
    var inputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var outputTokens: Int64
    /// Nil when the model has no entry in the pricing catalog. Nil means
    /// *unknown*, never free — a zero here would read as "this cost nothing".
    var estimatedAmountMicros: Int64?
    /// Currency of `estimatedAmountMicros`. Nil exactly when that is nil.
    var currency: String?

    var id: String { modelKey }

    /// Same key the store groups rows by, so an unnamed model stays one row.
    /// Delegated rather than repeated: this is a primary-key encoding, and a
    /// second copy diverges silently — a mismatched key does not raise, it
    /// produces a row that never joins.
    var modelKey: String { LedgerModelIdentity.makeKey(for: model) }

    var totalTokens: Int64 {
        inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
    }

    /// The model is absent from the pricing catalog, so no estimate exists.
    var isUnpriced: Bool { estimatedAmountMicros == nil }
}

/// Machine-wide local token usage for a period, aggregated per model and priced.
struct LocalUsageStatistics: Equatable, Sendable {
    /// Sorted by estimated value descending; unpriced models come last, among
    /// themselves by token count descending, so the biggest contributor is first.
    var models: [LocalModelUsageStatistic]
    /// Sum of the per-model estimates. Nil when no model in the period could be
    /// priced at all.
    var estimatedAmountMicros: Int64?
    var currency: String?

    /// The money is what Anthropic's API would have billed for these tokens.
    /// A subscription is a flat fee — nobody charged this amount.
    static let estimateDisclaimer =
        "Estimated API-equivalent value. A subscription is a flat fee, so this was never billed."

    var totalTokens: Int64 { models.reduce(0) { $0 + $1.totalTokens } }

    /// True when at least one model could not be priced, so the UI can say the
    /// total is incomplete rather than letting it read as the whole story.
    var hasUnpricedModels: Bool { models.contains(where: \.isUnpriced) }

    init(models: [LocalModelUsageStatistic], estimatedAmountMicros: Int64?, currency: String?) {
        self.models = models
        self.estimatedAmountMicros = estimatedAmountMicros
        self.currency = currency
    }

    init(rows: [LocalTokenUsage], estimator: CostEstimator, providerID: ProviderID = .claude) {
        var totals: [String: LocalModelUsageStatistic] = [:]
        var order: [String] = []

        for row in rows {
            let key = row.modelKey
            if var existing = totals[key] {
                existing.inputTokens += row.inputTokens
                existing.cacheCreationTokens += row.cacheCreationTokens
                existing.cacheReadTokens += row.cacheReadTokens
                existing.outputTokens += row.outputTokens
                totals[key] = existing
            } else {
                order.append(key)
                totals[key] = LocalModelUsageStatistic(
                    model: row.model,
                    inputTokens: row.inputTokens,
                    cacheCreationTokens: row.cacheCreationTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    outputTokens: row.outputTokens,
                    estimatedAmountMicros: nil,
                    currency: nil
                )
            }
        }

        // A model with no tokens in the period contributes nothing to either
        // figure and only adds a row. This also retires rows stored before the
        // reader learned to skip Claude Code's `<synthetic>` placeholder: those
        // are all zeros and will never grow, so they would otherwise sit in the
        // table forever, permanently unpriceable.
        var priced = order.compactMap { totals[$0] }
            .filter { $0.totalTokens > 0 }
            .map { statistic in
                Self.priced(statistic, estimator: estimator, providerID: providerID)
            }

        priced.sort { left, right in
            switch (left.estimatedAmountMicros, right.estimatedAmountMicros) {
            case let (lhs?, rhs?):
                lhs == rhs ? left.totalTokens > right.totalTokens : lhs > rhs
            case (_?, nil):
                true
            case (nil, _?):
                false
            case (nil, nil):
                left.totalTokens > right.totalTokens
            }
        }

        models = priced
        estimatedAmountMicros = priced.compactMap(\.estimatedAmountMicros)
            .reduce(nil) { total, amount in (total ?? 0) + amount }
        currency = priced.first(where: { $0.currency != nil })?.currency
    }

    /// Prices one model through the shared `CostEstimator`, which reads all four
    /// token classes at their own rate. The snapshot is a carrier for that call:
    /// local transcripts have no account, and only the amount is read back.
    private static func priced(
        _ statistic: LocalModelUsageStatistic,
        estimator: CostEstimator,
        providerID: ProviderID
    ) -> LocalModelUsageStatistic {
        let snapshot = UsageSnapshot(
            id: UUID(),
            accountID: UUID(),
            providerID: providerID,
            bucketStart: Date(timeIntervalSince1970: 0),
            bucketEnd: Date(timeIntervalSince1970: 0),
            model: statistic.model,
            inputTokens: statistic.inputTokens,
            cacheCreationTokens: statistic.cacheCreationTokens,
            cacheReadTokens: statistic.cacheReadTokens,
            outputTokens: statistic.outputTokens,
            requests: nil,
            quality: .estimated
        )

        guard let estimate = try? estimator.estimate(snapshot: snapshot) else {
            return statistic
        }

        var result = statistic
        result.estimatedAmountMicros = estimate.estimatedAmountMicros
        result.currency = estimate.currency
        return result
    }
}
