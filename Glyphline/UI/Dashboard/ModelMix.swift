import Foundation

/// One model's place in the spend of a period.
///
/// The figure that ranks is the money, not the tokens: Fable is ten times Haiku
/// on output, so a little Fable outranks a lot of Haiku. A card ordered by
/// volume would hide exactly the thing worth seeing — that the expensive model
/// quietly dominates the bill.
struct ModelMixEntry: Identifiable, Equatable, Sendable {
    var model: String?
    var totalTokens: Int64
    /// Nil when the model has no entry in the pricing catalog. Nil is *unknown*,
    /// never free — a zero here would read as "this cost nothing".
    var estimatedAmountMicros: Int64?
    /// Currency of `estimatedAmountMicros`. Nil exactly when that is nil.
    var currency: String?
    /// Fraction of the period's priced spend, 0…1. Nil for an unpriced model,
    /// for the same reason its cost is nil: nobody knows, and a zero would lie.
    var shareOfSpend: Double?
    /// The same key the statistics layer groups by, so an unnamed model stays
    /// one row instead of colliding with every other unnamed one.
    var id: String

    var sharePercent: Double? { shareOfSpend.map { $0 * 100 } }

    /// The model is absent from the pricing catalog, so no estimate exists.
    var isUnpriced: Bool { estimatedAmountMicros == nil }
}

/// The models of a period, ranked by cost, with each one's share of the spend.
///
/// Built on `LocalUsageStatistics` rather than beside it: the aggregation and
/// the pricing already live there and go through the shared `CostEstimator`, so
/// a second price table here could only ever drift out of agreement with the
/// number the rest of the app shows.
struct ModelMix: Equatable, Sendable {
    /// Ranked by estimated cost descending. Unpriced models come last, among
    /// themselves by token count descending — they are still shown, because a
    /// model you cannot price is the one you most want to notice.
    var entries: [ModelMixEntry]
    /// Sum of the priced entries. Nil when nothing in the period could be priced.
    var estimatedAmountMicros: Int64?
    var currency: String?

    var totalTokens: Int64 { entries.reduce(0) { $0 + $1.totalTokens } }

    /// True when at least one model could not be priced, so the UI can say the
    /// total is incomplete rather than letting it read as the whole story.
    var hasUnpricedModels: Bool { entries.contains(where: \.isUnpriced) }

    var isEmpty: Bool { entries.isEmpty }

    init(statistics: LocalUsageStatistics) {
        let pricedTotal = statistics.estimatedAmountMicros
        entries = statistics.models.map { model in
            ModelMixEntry(
                model: model.model,
                totalTokens: model.totalTokens,
                estimatedAmountMicros: model.estimatedAmountMicros,
                currency: model.currency,
                shareOfSpend: Self.share(of: model.estimatedAmountMicros, in: pricedTotal),
                id: model.modelKey
            )
        }
        estimatedAmountMicros = pricedTotal
        currency = statistics.currency
    }

    static func from(
        rows: [LocalTokenUsage],
        estimator: CostEstimator,
        providerID: ProviderID = .claude
    ) -> ModelMix {
        ModelMix(statistics: LocalUsageStatistics(
            rows: rows,
            estimator: estimator,
            providerID: providerID
        ))
    }

    /// A period whose priced spend is zero has no proportions to report, so the
    /// share stays unknown rather than becoming a division by zero or a
    /// misleading 100 %.
    private static func share(of amount: Int64?, in total: Int64?) -> Double? {
        guard let amount, let total, total > 0 else { return nil }
        return Double(amount) / Double(total)
    }
}
