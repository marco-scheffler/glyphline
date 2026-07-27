import Foundation

struct CursorUsageAdapter: ProviderAdapter {
    enum Mode: Sendable, Equatable {
        case localStatusOnly
        case teamAPI
    }

    let providerID: ProviderID = .cursor
    var mode: Mode

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        _ = secret

        let isExact = mode == .teamAPI
        let message: String = {
            switch mode {
            case .localStatusOnly:
                return "Cursor local-status-only mode is partial."
            case .teamAPI:
                return "Cursor team/API mode is exact."
            }
        }()

        return ProviderSyncResult(
            providerID: .cursor,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: isExact,
                supportsActualCost: false,
                supportsResetDate: false,
                supportsModelBreakdown: false,
                dataQuality: isExact ? .exact : .partial,
                message: message
            ),
            billingPeriod: nil,
            usageSnapshots: [],
            costSnapshots: [],
            estimateSnapshots: [],
            syncedAt: Date()
        )
    }
}
