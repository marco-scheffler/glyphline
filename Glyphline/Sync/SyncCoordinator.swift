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
    private let rateWindowSourceProvider: @MainActor (Account) -> (any RateWindowSource)?

    /// Per-account reason why quota is not being shown. Cleared on a good fetch.
    @Published private(set) var rateWindowMessages: [UUID: String] = [:]

    /// Accounts currently being fetched, so an on-demand refresh cannot double up
    /// with a scheduled one. Mirrors the `activities[...]?.isRunning` guard the
    /// cost path already uses.
    private var rateWindowFetchesInFlight: Set<UUID> = []

    /// When a successful fetch last confirmed each window, per account and kind.
    ///
    /// Freshness lives here rather than on the stored row. `observedAt` records
    /// when a value was *first* seen and does not advance when an unchanged
    /// observation is dropped, so measuring freshness from it made a provider
    /// that keeps confirming the same figure look silent after two poll
    /// intervals — grey icon and no "Next free" minutes after a good fetch,
    /// precisely for the idle user the feature exists for.
    ///
    /// Per kind, not merely per account: the billing cycle comes from the cost
    /// path and the short windows from the quota source, and those two succeed
    /// and fail independently. One timestamp for both would let a derived
    /// billing cycle vouch for a rate window nobody fetched.
    ///
    /// In memory only. After a relaunch nothing is confirmed yet and the stored
    /// `observedAt` stands in until the first fetch, which the menu triggers on
    /// open.
    private var rateWindowConfirmations: [UUID: [RateWindowKind: Date]] = [:]

    private func confirm(_ window: RateWindow, accountID: UUID) {
        rateWindowConfirmations[accountID, default: [:]][window.kind] = window.observedAt
    }

    /// What the menu renders: every enabled account, including those with no
    /// data, which appear with their reason rather than being filtered out.
    @Published private(set) var quotaStates: [QuotaAccountState] = []

    var quotaLight: QuotaLightState {
        QuotaIndicator.light(for: quotaStates, now: now(), freshness: quotaFreshness)
    }

    /// Computed here rather than in the view, so no call site can invent its own
    /// freshness bound: the symbol and this string must never disagree about
    /// which observations are still believable.
    var nextFreeText: String? {
        QuotaIndicator.nextFree(for: quotaStates, now: now(), freshness: quotaFreshness)
    }

    /// The menu's account blocks, rows already rendered against the same bound.
    ///
    /// Third of three consumers of the same freshness rule, beside `quotaLight`
    /// and `nextFreeText`, and the one that used to apply no bound at all. Kept
    /// here for the same reason as the other two: `quotaFreshness` stays private,
    /// so no call site can invent a bound of its own.
    var quotaRows: [QuotaRowGroup] {
        QuotaIndicator.rowGroups(for: quotaStates, now: now(), freshness: quotaFreshness)
    }

    /// Twice the poll interval: an observation older than that is not displayed.
    private var quotaFreshness: TimeInterval {
        (currentIntervalSeconds ?? 1_800) * 2
    }

    /// Called when the menu opens, so the figure is current at the moment it is
    /// read. The in-flight guard inside `collectRateWindows` keeps this from
    /// racing a scheduled tick.
    func refreshRateWindowsOnDemand() async {
        await collectRateWindows()
    }

    /// Injected so scheduling can be exercised without waiting on wall-clock time.
    private let sleepForSeconds: @Sendable (TimeInterval) async throws -> Void
    private var schedulerTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    /// Injected so backfill windows are deterministic in tests.
    private let now: @Sendable () -> Date

    /// UTC, because every adapter buckets by UTC day. Built once: `Calendar` is not
    /// `Sendable`, so it cannot be a `static let`.
    private let utcCalendar: Calendar

    private var backfillTasks: [UUID: Task<Void, Never>] = [:]

    /// Phase two reaches back a year, matching the longest range the history charts
    /// offer. Weekly slices stay inside both API caps: Anthropic's 31 daily buckets
    /// per request and Cursor's 30-day window.
    static let backfillHorizonDays = 365
    static let backfillSliceDays = 7

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
        },
        now: @escaping @Sendable () -> Date = Date.init,
        rateWindowSourceProvider: (@MainActor (Account) -> (any RateWindowSource)?)? = nil
    ) {
        self.sleepForSeconds = sleepForSeconds
        self.now = now
        self.rateWindowSourceProvider = rateWindowSourceProvider ?? { account in
            registry.rateWindowSource(for: account)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        self.utcCalendar = utc
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
                await self.collectRateWindows()
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

    /// Collects quota windows for every enabled account, then applies retention.
    ///
    /// Runs in an error scope entirely separate from the cost sync: a failing
    /// quota fetch must not fail the cost sync, and the reverse. This is the
    /// direct lesson from the Cursor adapter, where a failing spend call
    /// discarded usage data that had already been fetched successfully.
    func collectRateWindows() async {
        guard let ledger else { return }

        let accounts: [Account]
        do {
            accounts = try ledger.fetchAccounts().filter(\.isEnabled)
        } catch {
            return
        }

        // One aggregate query for the whole tick rather than one per account: this
        // runs on the main actor every time the menu opens.
        let summaries = (try? ledger.fetchAccountSummaries()) ?? []

        for account in accounts {
            // A menu opened during a scheduled tick must not issue a second
            // concurrent fetch for the same account.
            guard !rateWindowFetchesInFlight.contains(account.id) else { continue }
            rateWindowFetchesInFlight.insert(account.id)
            defer { rateWindowFetchesInFlight.remove(account.id) }

            // A billing cycle the cost sync already established is worth showing
            // even when no quota source exists for this account.
            if let summary = summaries.first(where: { $0.account.id == account.id }),
               let period = summary.billingPeriod,
               let resetAt = period.resetAt {
                let cycle = RateWindow(
                    kind: .billingCycle,
                    usedFraction: nil,
                    resetAt: resetAt,
                    observedAt: now()
                )
                // Confirmed only when the store accepted it. An implausible
                // reading is one the app has decided not to believe, and
                // vouching for it here would make an older stored row look
                // freshly checked.
                if (try? ledger.saveRateWindow(cycle, accountID: account.id)) == true {
                    confirm(cycle, accountID: account.id)
                }
            }

            guard let source = rateWindowSourceProvider(account) else {
                // `notAvailable`, not `notConfigured`: the spike found no route to
                // quota for these subscriptions, so inviting the user to set one up
                // would send them after something that does not exist.
                rateWindowMessages[account.id] = RateWindowSourceError.notAvailable.message
                continue
            }

            do {
                let secret = account.quotaCredentialReference.flatMap { try? credentials.readSecret(for: $0) }
                let result = try await source.fetchWindows(account: account, secret: secret)

                if result.dataQuality == .unavailable {
                    rateWindowMessages[account.id] = result.message
                        ?? RateWindowSourceError.notAvailable.message
                    continue
                }

                rateWindowMessages[account.id] = nil
                for window in result.windows where try ledger.saveRateWindow(
                    window,
                    accountID: account.id
                ) {
                    // The row may not have been written — an unchanged
                    // observation is dropped — but the value was confirmed, and
                    // that is what freshness is measured from.
                    confirm(window, accountID: account.id)
                }
            } catch let error as RateWindowSourceError {
                rateWindowMessages[account.id] = error.message
            } catch {
                rateWindowMessages[account.id] = RateWindowSourceError.transportFailure.message
            }
        }

        // Rebuilt for every enabled account, including ones that were skipped or
        // failed: an account with no data belongs in the menu with its reason,
        // not filtered out.
        //
        // Sorted by display name rather than left in ledger order: `nextFree`
        // names the *first* account with headroom, so an unstable order would
        // make it name a different account run to run. It does not follow that
        // the named account is the first row on screen — it is the first row
        // *with headroom*, which may sit below exhausted or silent neighbours.
        // The sort buys determinism, not adjacency.
        quotaStates = accounts
            .sorted {
                let byName = $0.displayName.localizedStandardCompare($1.displayName)
                return byName == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString
                    : byName == .orderedAscending
            }
            .map { account in
                let confirmations = rateWindowConfirmations[account.id] ?? [:]
                let latest = (try? ledger.fetchLatestRateWindows(accountID: account.id)) ?? []

                return QuotaAccountState(
                    accountID: account.id,
                    displayName: account.displayName,
                    windows: latest.map {
                        QuotaWindowState(window: $0, confirmedAt: confirmations[$0.kind])
                    },
                    message: rateWindowMessages[account.id]
                )
            }

        // Retention runs regardless of how the fetches went.
        try? ledger.deleteRateWindowSamples(olderThan: now().addingTimeInterval(-365 * 86_400))
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

    func cancelBackfill(account: Account) {
        backfillTasks[account.id]?.cancel()
        backfillTasks[account.id] = nil
    }

    /// Phase two: walk backwards in weekly slices, recording progress after each so
    /// a cancelled or interrupted run resumes rather than restarting.
    ///
    /// Every slice boundary is a UTC midnight, and the newest boundary is the start
    /// of today rather than "now". Adapters label each bucket as a whole UTC day and
    /// the ledger upsert *replaces* a bucket rather than adding to it, so a slice
    /// that began or ended mid-day would emit a fragment as if it were a full day
    /// and shrink a total that a routine sync had already written correctly. Leaving
    /// today entirely to routine sync also means backfill can never overwrite the
    /// one bucket that is still open and growing. For completed days both writers
    /// produce the same absolute total, so either order is safe.
    func backfill(account: Account) async {
        guard let ledger, let scheduler else {
            activities[account.id] = .failed(Self.ledgerUnavailableMessage)
            syncFailureMessage = Self.ledgerUnavailableMessage
            return
        }

        // Same guard `syncNow` uses, so a backfill cannot race a scheduled or
        // wake-triggered sync of the same account.
        guard backfillTasks[account.id] == nil, activities[account.id]?.isRunning != true else {
            return
        }

        let resolved = adapter(for: account)
        let today = utcCalendar.startOfDay(for: now())
        let horizon = utcCalendar.date(
            byAdding: .day,
            value: -Self.backfillHorizonDays,
            to: today
        ) ?? today

        // A source that cannot address a date range already ingested everything it
        // has during phase one. Record completion rather than slicing pointlessly.
        //
        // Surfaced, not swallowed: `saveBackfillCompletedThrough` throws
        // `LedgerStoreError.unknownAccount`, which a Task 3 fix was written to make
        // visible, and the slicing path below already reports it as `.failed`. A
        // `try?` here made the same failure silent on this branch alone.
        guard !resolved.scopedIsNoOp else {
            do {
                try ledger.saveBackfillCompletedThrough(horizon, accountID: account.id)
            } catch {
                activities[account.id] = .failed(Self.describe(error))
            }
            return
        }

        // Snapped down, never up: resuming must not skip a day a previous run left
        // half-finished, and a stored watermark from an older build may be mid-day.
        let resumePoint = utcCalendar.startOfDay(
            for: (try? ledger.fetchBackfillCompletedThrough(accountID: account.id)) ?? today
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var cursor = resumePoint

            while cursor > horizon, !Task.isCancelled {
                let sliceEnd = cursor
                let sliceStart = max(
                    horizon,
                    self.utcCalendar.date(
                        byAdding: .day,
                        value: -Self.backfillSliceDays,
                        to: sliceEnd
                    ) ?? horizon
                )

                guard sliceStart < sliceEnd else { break }

                self.activities[account.id] = .running(
                    phase: Self.backfillPhase(from: sliceStart, today: today)
                )

                do {
                    try await scheduler.sync(
                        account: account,
                        adapter: resolved.scoped(to: DateInterval(start: sliceStart, end: sliceEnd))
                    )
                    try ledger.saveBackfillCompletedThrough(sliceStart, accountID: account.id)
                } catch {
                    self.activities[account.id] = .failed(Self.describe(error))
                    self.backfillTasks[account.id] = nil
                    return
                }

                cursor = sliceStart
            }

            self.activities[account.id] = .idle
            self.backfillTasks[account.id] = nil
        }

        backfillTasks[account.id] = task
        await task.value
    }

    private static func backfillPhase(from sliceStart: Date, today: Date) -> String {
        let days = Int(today.timeIntervalSince(sliceStart) / 86_400)
        return "Backfilling \(days) days of history"
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
