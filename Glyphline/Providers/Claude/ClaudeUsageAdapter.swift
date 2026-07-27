import Foundation

struct ClaudeUsageAdapter: ProviderAdapter {
    enum Mode: Sendable, Equatable {
        case requiresAdminKey
        case adminAPI
    }

    let providerID: ProviderID = .claude
    var mode: Mode

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        _ = secret

        let isExact = mode == .adminAPI
        let message: String = {
            switch mode {
            case .requiresAdminKey:
                return "Claude non-admin credentials are unavailable."
            case .adminAPI:
                return "Claude admin API mode is exact."
            }
        }()

        return ProviderSyncResult(
            providerID: .claude,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: isExact,
                supportsActualCost: isExact,
                supportsResetDate: false,
                supportsModelBreakdown: isExact,
                dataQuality: isExact ? .exact : .unavailable,
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
