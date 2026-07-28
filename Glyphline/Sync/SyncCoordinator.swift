import AppKit
import Combine
import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var activities: [UUID: SyncActivity] = [:]

    /// Set when a sync could not be attempted at all, so the failure is visible
    /// rather than a silent no-op. Per-account failures use `activities`.
    @Published private(set) var syncFailureMessage: String?

    @Published private(set) var isSchedulerRunning = false

    /// The interval the running loop was started with, or nil when stopped.
    private(set) var currentIntervalSeconds: TimeInterval?

    /// Counts how many times a loop has actually been started. A restart is
    /// otherwise invisible from the outside, since a loop cancelled before its
    /// first suspension never runs at all.
    private(set) var schedulerStartCount = 0

    /// Nil when the on-disk ledger could not be opened. There is deliberately no
    /// in-memory stand-in: a sync with nowhere durable to write must refuse
    /// rather than appear to succeed.
    private let ledger: LedgerStore?
    private let credentials: any CredentialStore
    private let registry: ProviderAdapterRegistry
    private let estimator: CostEstimator
    private let scheduler: SyncScheduler?
    private let adapterProvider: ((Account) -> any ProviderAdapter)?

    /// Injected so scheduling can be exercised without waiting on wall-clock time.
    private let sleepForSeconds: @Sendable (TimeInterval) async throws -> Void
    private var schedulerTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    /// Shown whenever a sync is refused for want of a ledger. Truthful in the
    /// degraded case: nothing was fetched and nothing was written.
    static let ledgerUnavailableMessage = "Ledger unavailable. Nothing was synced."

    init(
        ledger: LedgerStore?,
        credentials: any CredentialStore,
        registry: ProviderAdapterRegistry,
        estimator: CostEstimator,
        adapterProvider: ((Account) -> any ProviderAdapter)? = nil,
        sleepForSeconds: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.sleepForSeconds = sleepForSeconds
        self.ledger = ledger
        self.credentials = credentials
        self.registry = registry
        self.estimator = estimator
        self.adapterProvider = adapterProvider
        self.scheduler = ledger.map { SyncScheduler(ledger: $0, credentials: credentials) }
    }

    /// Applies a desired schedule without disturbing one that already matches.
    ///
    /// The loop sleeps a full interval *before* its first sync, so an
    /// unconditional stop-then-start would push the next sync out by a whole
    /// interval every time it ran. This is called from `onAppear`, which fires
    /// again each time the dashboard scene is recreated, so a user reopening the
    /// window more often than the interval would never get a scheduled sync at
    /// all. Re-applying an unchanged configuration is therefore a no-op.
    func applySchedule(enabled: Bool, intervalSeconds: TimeInterval) {
        guard enabled else {
            stopScheduler()
            return
        }

        guard !(isSchedulerRunning && currentIntervalSeconds == intervalSeconds) else {
            return
        }

        stopScheduler()
        startScheduler(intervalSeconds: intervalSeconds)
    }

    /// Deliberately a long-lived task rather than a `Timer`: a menu bar app is
    /// subject to App Nap, under which timers fire unreliably.
    func startScheduler(intervalSeconds: TimeInterval) {
        guard schedulerTask == nil else {
            return
        }

        currentIntervalSeconds = intervalSeconds
        schedulerStartCount += 1
        isSchedulerRunning = true
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.sleepForSeconds(intervalSeconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.syncAll()
            }
        }

        observeWake()
    }

    func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        isSchedulerRunning = false
        currentIntervalSeconds = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// A Mac that slept through the interval would otherwise show yesterday's numbers.
    private func observeWake() {
        guard wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.syncAll()
            }
        }
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
