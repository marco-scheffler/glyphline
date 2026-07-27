import Combine
import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var activities: [UUID: SyncActivity] = [:]

    /// Set when a sync could not be attempted at all, so the failure is visible
    /// rather than a silent no-op. Per-account failures use `activities`.
    @Published private(set) var syncFailureMessage: String?

    /// Nil when the on-disk ledger could not be opened. There is deliberately no
    /// in-memory stand-in: a sync with nowhere durable to write must refuse
    /// rather than appear to succeed.
    private let ledger: LedgerStore?
    private let credentials: any CredentialStore
    private let registry: ProviderAdapterRegistry
    private let estimator: CostEstimator
    private let scheduler: SyncScheduler?
    private let adapterProvider: ((Account) -> any ProviderAdapter)?

    /// Shown whenever a sync is refused for want of a ledger. Truthful in the
    /// degraded case: nothing was fetched and nothing was written.
    static let ledgerUnavailableMessage = "Ledger unavailable. Nothing was synced."

    init(
        ledger: LedgerStore?,
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
        self.scheduler = ledger.map { SyncScheduler(ledger: $0, credentials: credentials) }
    }

    private func adapter(for account: Account) -> any ProviderAdapter {
        adapterProvider?(account) ?? registry.adapter(for: account)
    }

    func syncAll() async {
        guard let ledger else {
            syncFailureMessage = Self.ledgerUnavailableMessage
            return
        }

        let accounts: [Account]
        do {
            accounts = try ledger.fetchAccounts().filter(\.isEnabled)
        } catch {
            syncFailureMessage = "Could not read the ledger. Nothing was synced."
            return
        }

        syncFailureMessage = nil

        for account in accounts {
            await syncNow(account: account)
        }
    }

    func syncNow(account: Account) async {
        guard let ledger, let scheduler else {
            activities[account.id] = .failed(Self.ledgerUnavailableMessage)
            syncFailureMessage = Self.ledgerUnavailableMessage
            return
        }

        guard activities[account.id]?.isRunning != true else {
            return
        }

        activities[account.id] = .running(phase: "Syncing")
        let resolved = adapter(for: account)

        do {
            try await scheduler.sync(account: account, adapter: resolved)
            try estimateMissingCosts(for: account, in: ledger)
            activities[account.id] = .idle
        } catch {
            activities[account.id] = .failed(Self.describe(error))
        }
    }

    /// Produces estimate snapshots for accounts whose provider reports no actual cost.
    private func estimateMissingCosts(for account: Account, in ledger: LedgerStore) throws {
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
