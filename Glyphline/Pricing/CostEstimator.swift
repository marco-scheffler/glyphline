import Foundation

enum CostEstimatorError: Error, Equatable {
    case missingPricing(providerID: ProviderID, model: String?)
}

struct CostEstimator: Sendable {
    let catalog: PricingCatalog

    func estimate(snapshot: UsageSnapshot) throws -> EstimateSnapshot {
        guard let entry = catalog.entry(providerID: snapshot.providerID, model: snapshot.model) else {
            throw CostEstimatorError.missingPricing(providerID: snapshot.providerID, model: snapshot.model)
        }

        let inputMicros = snapshot.inputTokens * entry.inputMicrosPerMillionTokens / 1_000_000
        let outputMicros = snapshot.outputTokens * entry.outputMicrosPerMillionTokens / 1_000_000

        return EstimateSnapshot(
            id: UUID(),
            accountID: snapshot.accountID,
            providerID: snapshot.providerID,
            bucketStart: snapshot.bucketStart,
            bucketEnd: snapshot.bucketEnd,
            estimatedAmountMicros: inputMicros + outputMicros,
            currency: entry.currency,
            quality: estimatedQuality(for: snapshot.quality)
        )
    }

    private func estimatedQuality(for quality: DataQuality) -> DataQuality {
        quality.isBetterThan(.estimated) ? .estimated : quality
    }
}
