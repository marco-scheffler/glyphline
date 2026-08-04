import Combine
import Foundation

/// Keeps "Usage on this Mac" current: scans the transcripts once at launch and
/// then on the interval the user already set.
///
/// App-level rather than attached to a view, for the reason
/// `SyncScheduleController` and `LocalHistoryRebuildController` are. The scan
/// used to hang off `DashboardView`'s `task` and latch after one run, so in the
/// default menu bar mode — where no window opens at launch — it never ran at
/// all, and a dashboard reopened hours later showed hours-old figures.
///
/// **Deliberately not gated on `automaticSyncEnabled`.** That toggle is about
/// syncing accounts: network calls against a provider, with quota and credential
/// consequences. Reading files this machine wrote has none of those, and nothing
/// else refreshes these figures — the menu bar's Refresh button calls
/// `refreshRateWindowsOnDemand()`, which is quotas, not this. Switching network
/// sync off must not silently freeze the local usage screen forever.
///
/// A repeat scan is cheap: `ClaudeCodeLogReader` prefetches size and modification
/// date, compares each file against its stored watermark and never opens one that
/// has not grown. Only the directory walk is paid per pass.
///
/// The interval is followed as it changes, with the trap `SyncScheduleController`
/// documents: `@Published` publishes on `willSet`, so the sink must use the value
/// Combine hands it and never re-read the store.
@MainActor
final class LocalScanScheduleController {
    /// The interval the running loop was started with, in seconds. Nil only
    /// before the first emission, which arrives on subscription.
    private(set) var currentIntervalSeconds: TimeInterval?

    /// Counts how many loops have been started, so a re-timing is observable
    /// from the outside.
    private(set) var startCount = 0

    private var cancellable: AnyCancellable?
    private var loop: Task<Void, Never>?
    private let scan: @MainActor () async -> Void
    private let sleepForSeconds: @Sendable (TimeInterval) async throws -> Void

    /// - Parameter scan: one pass. Awaited before the next sleep, so a slow scan
    ///   delays the cadence rather than overlapping with itself — which is also
    ///   what keeps a tick from parking a second waiter on
    ///   `LocalHistoryWriteGate` during the one-time rebuild.
    init(
        settings: AppSettingsStore,
        scan: @escaping @MainActor () async -> Void,
        sleepForSeconds: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.scan = scan
        self.sleepForSeconds = sleepForSeconds

        cancellable = settings.$syncIntervalMinutes.sink { [weak self] minutes in
            MainActor.assumeIsolated {
                // `minutes` as Combine passed it, never `settings.syncIntervalMinutes`:
                // the store still holds the value being replaced at this point.
                self?.restart(intervalSeconds: TimeInterval(minutes * 60))
            }
        }
    }

    deinit {
        loop?.cancel()
    }

    /// Deliberately a long-lived task rather than a `Timer`, as in
    /// `SyncCoordinator.startScheduler`: a menu bar app is subject to App Nap,
    /// under which timers fire unreliably.
    private func restart(intervalSeconds: TimeInterval) {
        guard currentIntervalSeconds != intervalSeconds else { return }

        loop?.cancel()
        currentIntervalSeconds = intervalSeconds
        startCount += 1

        let scan = scan
        let sleepForSeconds = sleepForSeconds
        loop = Task { @MainActor in
            // Scan before the first sleep, otherwise nothing is read for a whole
            // interval after launch — which is the stale-at-launch half of the
            // bug this controller exists for.
            while !Task.isCancelled {
                await scan()

                guard !Task.isCancelled else { return }
                do {
                    try await sleepForSeconds(intervalSeconds)
                } catch {
                    return
                }
            }
        }
    }
}
