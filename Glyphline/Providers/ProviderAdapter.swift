import Foundation

struct ProviderCapabilities: Codable, Equatable, Sendable {
    var supportsUsage: Bool
    var supportsActualCost: Bool
    var supportsResetDate: Bool
    var supportsModelBreakdown: Bool
    var dataQuality: DataQuality
    var message: String?
}

struct ProviderSyncResult: Sendable {
    var providerID: ProviderID
    var accountID: UUID
    var capabilities: ProviderCapabilities
    var billingPeriod: BillingPeriod?
    var usageSnapshots: [UsageSnapshot]
    var costSnapshots: [CostSnapshot]
    var estimateSnapshots: [EstimateSnapshot]
    var syncedAt: Date
}

protocol ProviderAdapter {
    var providerID: ProviderID { get }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult
}
