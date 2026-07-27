import Foundation

struct FixtureProviderAdapter: ProviderAdapter {
    let providerID: ProviderID

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        _ = secret

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(86_400)
        let usageSnapshotID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let estimateSnapshotID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        return ProviderSyncResult(
            providerID: providerID,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: false,
                supportsResetDate: true,
                supportsModelBreakdown: true,
                dataQuality: .exact,
                message: nil
            ),
            billingPeriod: BillingPeriod(
                startsAt: start,
                endsAt: nil,
                resetAt: end.addingTimeInterval(30 * 86_400)
            ),
            usageSnapshots: [
                UsageSnapshot(
                    id: usageSnapshotID,
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    model: "fixture-model",
                    inputTokens: 1_000,
                    outputTokens: 500,
                    requests: 12,
                    quality: .exact
                )
            ],
            costSnapshots: [],
            estimateSnapshots: [
                EstimateSnapshot(
                    id: estimateSnapshotID,
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    estimatedAmountMicros: 2_500,
                    currency: "USD",
                    quality: .estimated
                )
            ],
            syncedAt: start.addingTimeInterval(12)
        )
    }
}
