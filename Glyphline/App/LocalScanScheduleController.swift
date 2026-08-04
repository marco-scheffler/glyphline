import AppKit
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
///
/// Wake is handled the way `SyncCoordinator.startScheduler` handles it, and for
/// the same reason: a sleeping Mac does not run the loop, so a machine that slept
/// overnight would come back and wait out the remainder of an interval that
/// elapsed while it was asleep — stale figures for up to a full interval at
/// exactly the moment the user looks. The wake scan is unconditional rather than
/// "only if the interval has elapsed", because the elapsed case is the common one
/// and a scan that finds nothing costs a directory walk, not a re-read.
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
    /// `nonisolated(unsafe)` because `deinit` is nonisolated and the token is not
    /// `Sendable`. Safe in fact: it is written once, from `init` on the main
    /// actor, and read only by `deinit`, which by definition has no other
    /// reference left to race with.
    private nonisolated(unsafe) var wakeObserver: (any NSObjectProtocol)?
    private let wakeNotificationCenter: NotificationCenter
    private var isScanning = false
    private let scan: @MainActor () async -> Void
    private let sleepForSeconds: @Sendable (TimeInterval) async throws -> Void

    /// - Parameter scan: one pass. Awaited before the next sleep, so a slow scan
    ///   delays the cadence rather than overlapping with itself — which is also
    ///   what keeps a tick from parking a second waiter on
    ///   `LocalHistoryWriteGate` during the one-time rebuild.
    /// - Parameter wakeNotificationCenter: injected only so a test can post
    ///   `NSWorkspace.didWakeNotification` without putting the machine to sleep.
    init(
        settings: AppSettingsStore,
        scan: @escaping @MainActor () async -> Void,
        sleepForSeconds: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.scan = scan
        self.sleepForSeconds = sleepForSeconds
        self.wakeNotificationCenter = wakeNotificationCenter
        observeWake()

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
        if let wakeObserver {
            wakeNotificationCenter.removeObserver(wakeObserver)
        }
    }

    /// A Mac that slept through the interval would otherwise show figures from
    /// before it went to sleep, for up to a whole interval after it came back.
    private func observeWake() {
        guard wakeObserver == nil else { return }

        wakeObserver = wakeNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.performScan()
            }
        }
    }

    /// The single entry point for a scan, so a wake that lands during a scheduled
    /// pass cannot start a second one alongside it. Both readers share the same
    /// watermarks, and two passes reading the same growth at once would add it
    /// twice.
    private func performScan() async {
        guard !isScanning else { return }
        isScanning = true
        await scan()
        isScanning = false
    }

    /// Deliberately a long-lived task rather than a `Timer`, as in
    /// `SyncCoordinator.startScheduler`: a menu bar app is subject to App Nap,
    /// under which timers fire unreliably.
    private func restart(intervalSeconds: TimeInterval) {
        guard currentIntervalSeconds != intervalSeconds else { return }

        loop?.cancel()
        currentIntervalSeconds = intervalSeconds
        startCount += 1

        let sleepForSeconds = sleepForSeconds
        loop = Task { @MainActor [weak self] in
            // Scan before the first sleep, otherwise nothing is read for a whole
            // interval after launch — which is the stale-at-launch half of the
            // bug this controller exists for.
            while !Task.isCancelled {
                // Optional-chained rather than bound with `guard let self`. A
                // binding would live to the end of the iteration — across the
                // sleep below — so the loop would hold the controller alive for a
                // whole interval at a time, `deinit` would never run while the
                // loop was parked, and the wake observer would never be removed.
                guard self != nil else { return }
                _ = await self?.performScan()

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
