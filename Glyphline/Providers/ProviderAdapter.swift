import Foundation

struct ProviderCapabilities: Codable, Equatable, Sendable {
    var supportsUsage: Bool
    var supportsActualCost: Bool
    var supportsResetDate: Bool
    var supportsModelBreakdown: Bool
    var dataQuality: DataQuality
    var message: String?
}

struct ProviderSyncResult: Codable, Equatable, Sendable {
    var providerID: ProviderID
    var accountID: UUID
    var capabilities: ProviderCapabilities
    var billingPeriod: BillingPeriod?
    var usageSnapshots: [UsageSnapshot]
    var costSnapshots: [CostSnapshot]
    var estimateSnapshots: [EstimateSnapshot]
    var syncedAt: Date
}

/// Tells "this credential was refused" apart from "this provider is unwell".
///
/// Every adapter degrades a refused credential to `.unavailable` carrying an
/// instruction about the kind of key the provider needs. That message is wrong,
/// and actively misleading, for a 500 or a 429: it sends the user looking for a
/// key problem that does not exist. Only these statuses may take that branch.
enum ProviderHTTPStatus {
    static func isCredentialRejection(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }
}

protocol ProviderAdapter: Sendable {
    var providerID: ProviderID { get }

    /// False for adapters that read local files rather than a credentialed API.
    var requiresSecret: Bool { get }

    /// True when `scoped(to:)` cannot narrow this adapter, so backfill has nothing
    /// to slice. Local sources read whole files and cannot address a date range.
    var scopedIsNoOp: Bool { get }

    /// Returns a copy that fetches the given window instead of its default one.
    /// Adapters that cannot address arbitrary history return themselves unchanged.
    ///
    /// The interval is always UTC-day-aligned (see `SyncCoordinator.backfill`), so
    /// an adapter may assume it will never be asked for half a day bucket.
    func scoped(to interval: DateInterval) -> any ProviderAdapter

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult
}

extension ProviderAdapter {
    var requiresSecret: Bool { true }

    var scopedIsNoOp: Bool { true }

    func scoped(to interval: DateInterval) -> any ProviderAdapter { self }
}
