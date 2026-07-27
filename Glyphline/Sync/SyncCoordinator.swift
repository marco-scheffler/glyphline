import Combine
import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var activities: [UUID: SyncActivity] = [:]

    private let ledger: LedgerStore
    private let credentials: any CredentialStore
    private let registry: ProviderAdapterRegistry
    private let estimator: CostEstimator
    private let scheduler: SyncScheduler
    private let adapterProvider: ((Account) -> any ProviderAdapter)?

    init(
        ledger: LedgerStore,
        credentials: any CredentialStore,
        registry: ProviderAdapterRegistry,
        estimator: CostEstimator,
        adapterProvider: ((Account) -> any ProviderAdapter)? = nil
    ) {
        self.ledger = ledger
        self.credentials = credentials
        self.registry = registry
        self.estimator = estimator
        self.adapterProvider = adapterProvider
        self.scheduler = SyncScheduler(ledger: ledger, credentials: credentials)
    }

    private func adapter(for account: Account) -> any ProviderAdapter {
        adapterProvider?(account) ?? registry.adapter(for: account)
    }

    func syncAll() async {
        let accounts: [Account]
        do {
            accounts = try ledger.fetchAccounts().filter(\.isEnabled)
        } catch {
            return
        }

        for account in accounts {
            await syncNow(account: account)
        }
    }

    func syncNow(account: Account) async {
        guard activities[account.id]?.isRunning != true else {
            return
        }

        activities[account.id] = .running(phase: "Syncing")
        let resolved = adapter(for: account)

        do {
            try await scheduler.sync(account: account, adapter: resolved)
            try estimateMissingCosts(for: account)
            activities[account.id] = .idle
        } catch {
            activities[account.id] = .failed(Self.describe(error))
        }
    }

    /// Produces estimate snapshots for accounts whose provider reports no actual cost.
    private func estimateMissingCosts(for account: Account) throws {
        guard try ledger.fetchCostSnapshots(accountID: account.id).isEmpty else {
            return
        }

        let usage = try ledger.fetchUsageSnapshots(accountID: account.id)
        let estimates = usage.compactMap { try? estimator.estimate(snapshot: $0) }

        guard !estimates.isEmpty else {
            return
        }

        try ledger.upsertEstimateSnapshots(estimates)
    }

    /// Never interpolates the raw error: adapter errors can carry request detail.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case SyncSchedulerError.missingCredential:
            return "Credential missing in Keychain."
        case SyncSchedulerError.providerMismatch:
            return "Account and adapter provider disagree."
        default:
            return "Sync failed."
        }
    }
}
