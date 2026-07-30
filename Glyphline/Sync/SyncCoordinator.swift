import AppKit
import Combine
import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    /// Set when a collection could not be attempted at all, so the failure is
    /// visible rather than a silent no-op. Per-account failures use
    /// `rateWindowMessages`.
    @Published private(set) var syncFailureMessage: String?

    @Published private(set) var isSchedulerRunning = false

    /// The interval the running loop was started with, or nil when stopped.
    private(set) var currentIntervalSeconds: TimeInterval?

    /// Counts how many times a loop has actually been started. A restart is
    /// otherwise invisible from the outside, since a loop cancelled before its
    /// first suspension never runs at all.
    private(set) var schedulerStartCount = 0

    /// Nil when the on-disk ledger could not be opened. There is deliberately no
    /// in-memory stand-in: a collection with nowhere durable to write must
    /// refuse rather than appear to succeed.
    private let ledger: LedgerStore?
    private let credentials: any CredentialStore
    private let rateWindowSourceProvider: @MainActor (Account) -> (any RateWindowSource)?
    private let quotaNotifier: any QuotaNotifier

    /// Accounts already told about, so an expired session is announced on the
    /// transition and not on every tick. Cleared by the next successful fetch, so
    /// a session that expires again after a recovery is news again.
    ///
    /// Without this, three subscriptions on a half-hourly schedule would produce
    /// 144 notifications a day for one expired sign-in.
    private var sessionExpiryNotified: Set<UUID> = []

    /// Per-account reason why quota is not being shown. Cleared on a good fetch.
    @Published private(set) var rateWindowMessages: [UUID: String] = [:]

    /// Accounts currently being fetched, so an on-demand refresh cannot double up
    /// with a scheduled one.
    private var rateWindowFetchesInFlight: Set<UUID> = []

    /// When a successful fetch last confirmed each window, per account and kind.
    ///
    /// Freshness lives here rather than on the stored row. `observedAt` records
    /// when a value was *first* seen and does not advance when an unchanged
    /// observation is dropped, so measuring freshness from it made a provider
    /// that keeps confirming the same figure look silent after two poll
    /// intervals — a grey icon minutes after a good fetch, precisely for the
    /// idle user the feature exists for.
    ///
    /// Per kind, not merely per account: window kinds are fetched and can fail
    /// independently, and one timestamp for all of them would let a freshly
    /// confirmed window vouch for one nobody managed to fetch.
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

    /// The menu's account blocks, rows already rendered against the same bound.
    ///
    /// Second consumer of the same freshness rule, beside `quotaLight`, and the
    /// one that used to apply no bound at all. Kept here for the same reason:
    /// `quotaFreshness` stays private, so no call site can invent a bound of its
    /// own.
    var quotaRows: [QuotaRowGroup] {
        QuotaIndicator.rowGroups(for: quotaStates, now: now(), freshness: quotaFreshness)
    }

    /// The card's blocks, with fractions intact so a bar can be drawn. Same bound
    /// as `quotaRows` and `quotaLight` — computed here so no view can invent one.
    var quotaBars: [QuotaBarGroup] {
        QuotaIndicator.barGroups(for: quotaStates, now: now(), freshness: quotaFreshness)
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

    /// Injected so the quota windows are deterministic in tests.
    private let now: @Sendable () -> Date

    /// Shown whenever a collection is refused for want of a ledger. Truthful in
    /// the degraded case: nothing was fetched and nothing was written.
    static let ledgerUnavailableMessage = "Ledger unavailable. Nothing was synced."

    init(
        ledger: LedgerStore?,
        credentials: any CredentialStore,
        registry: ProviderAdapterRegistry,
        sleepForSeconds: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @Sendable () -> Date = Date.init,
        rateWindowSourceProvider: (@MainActor (Account) -> (any RateWindowSource)?)? = nil,
        quotaNotifier: any QuotaNotifier = UserNotificationQuotaNotifier()
    ) {
        self.quotaNotifier = quotaNotifier
        self.sleepForSeconds = sleepForSeconds
        self.now = now
        self.rateWindowSourceProvider = rateWindowSourceProvider ?? { account in
            registry.rateWindowSource(for: account)
        }
        self.ledger = ledger
        self.credentials = credentials
    }

    /// Applies a desired schedule without disturbing one that already matches.
    ///
    /// The loop sleeps a full interval between collections, so an unconditional
    /// stop-then-start would push the next collection out by a whole interval
    /// every time it ran. This is called from `onAppear`, which fires again each
    /// time the dashboard scene is recreated, so a user reopening the window more
    /// often than the interval would never get a scheduled collection at all.
    /// Re-applying an unchanged configuration is therefore a no-op.
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
            // Collect once before the first sleep, otherwise nothing is fetched
            // for a whole interval (30 minutes by default) after launch, and an
            // app that exists to show remaining capacity opens showing stale
            // figures.
            if let self, !Task.isCancelled {
                await self.collectRateWindows()
            }

            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.sleepForSeconds(intervalSeconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
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
                await self?.collectRateWindows()
            }
        }
    }

    /// Collects quota windows for every enabled account, then applies retention.
    ///
    /// A per-account failure is recorded against that account alone, in
    /// `rateWindowMessages`. `syncFailureMessage` is reserved for the conditions
    /// that stop the whole collection before any account is reached.
    func collectRateWindows() async {
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
            // A menu opened during a scheduled tick must not issue a second
            // concurrent fetch for the same account.
            guard !rateWindowFetchesInFlight.contains(account.id) else { continue }
            rateWindowFetchesInFlight.insert(account.id)
            defer { rateWindowFetchesInFlight.remove(account.id) }

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
                    let message = result.message ?? RateWindowSourceError.notAvailable.message
                    rateWindowMessages[account.id] = message
                    await noteQuotaFailure(message: message, account: account)
                    continue
                }

                // A successful fetch may still have something to say — a source
                // that answered with no window at all explains itself here — so
                // the message is carried through rather than cleared. Nil stays
                // nil, which is the ordinary case.
                rateWindowMessages[account.id] = result.message
                // The fetch worked, so the next expiry is a fresh transition.
                sessionExpiryNotified.remove(account.id)
                for window in result.windows {
                    // The row may not have been written — an unchanged
                    // observation is dropped — but the value was confirmed, and
                    // that is what freshness is measured from. An implausible
                    // reading confirms nothing.
                    let believable = try ledger.saveRateWindow(window, accountID: account.id)
                    if believable {
                        confirm(window, accountID: account.id)
                    }
                }
            } catch let error as RateWindowSourceError {
                rateWindowMessages[account.id] = error.message
                await noteQuotaFailure(message: error.message, account: account)
            } catch {
                rateWindowMessages[account.id] = RateWindowSourceError.transportFailure.message
            }
        }

        // Rebuilt for every enabled account, including ones that were skipped or
        // failed: an account with no data belongs in the menu with its reason,
        // not filtered out.
        //
        // Sorted by display name rather than left in ledger order, so the menu
        // and the cards do not reorder themselves between ticks.
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

    /// Announces an expired sign-in once, on the transition into it.
    ///
    /// Only an expired session is announced. A transport blip is transient and
    /// asks nothing of the user, and notifying on it would train them to ignore
    /// the one notification that does ask for something. It also leaves the flag
    /// alone, so a blip in the middle of an expiry does not re-arm and re-announce
    /// a session the user has already been told about.
    ///
    /// The message is compared against the app's own constant. Nothing from a
    /// response body ever reaches this comparison, or the notification.
    private func noteQuotaFailure(message: String, account: Account) async {
        guard message == RateWindowSourceError.sessionExpired.message,
              !sessionExpiryNotified.contains(account.id)
        else {
            return
        }

        sessionExpiryNotified.insert(account.id)
        await quotaNotifier.notifySessionExpired(accountDisplayName: account.displayName)
    }

    /// Deletes an account and drops everything this coordinator holds for it.
    func deleteAccount(_ account: Account, using flow: DeleteAccountFlow) async -> DeleteAccountFlow.Outcome {
        let outcome = await flow.delete(account)
        if case .deleted = outcome {
            forgetAccount(id: account.id)
        }
        return outcome
    }

    /// Drops everything this coordinator remembers about an account.
    ///
    /// Called after the account is deleted.
    func forgetAccount(id accountID: UUID) {
        rateWindowMessages[accountID] = nil
        rateWindowConfirmations[accountID] = nil
        // Defence in depth, and provably a no-op today: the in-flight marker is
        // inserted and removed within one iteration of `collectRateWindows` via
        // `defer`, so it is always empty between ticks and no test can observe
        // this line. It stays so that a future fetch which outlives its tick
        // cannot leave a deleted account permanently marked as busy.
        rateWindowFetchesInFlight.remove(accountID)
        sessionExpiryNotified.remove(accountID)
        quotaStates.removeAll { $0.accountID == accountID }
    }
}
