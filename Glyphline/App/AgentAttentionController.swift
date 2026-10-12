import Combine
import Foundation

/// Says when a Claude Code session has been waiting on the user for longer than
/// they asked to be left alone.
///
/// App-level, for the reason `LocalScanScheduleController` is: in the default
/// menu bar mode no window exists to hang this on. Rules live in
/// `WaitingAgentTracker`; this type only wires the watcher, the tail reader, the
/// clock and the notifier to it.
///
/// A task loop rather than a `Timer`, as in `LocalScanScheduleController`: a
/// menu bar app is subject to App Nap, under which timers fire unreliably.
@MainActor
final class AgentAttentionController {
    /// How often the tracker is asked what is due. A notification therefore lands
    /// at most this long after the configured delay.
    static let tickInterval: TimeInterval = 15

    private let settings: AppSettingsStore
    private let observer: any TranscriptChangeObserving
    private let reader: any TranscriptTailReading
    private let notifier: any UserNotifier
    private let now: @Sendable () -> Date
    private let sleepForSeconds: @Sendable (TimeInterval) async throws -> Void

    private var tracker = WaitingAgentTracker()
    private var loop: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    /// Tail reads still in flight. A tick waits for them, so a write that
    /// arrived before the tick is always seen by it.
    private var pendingReads: [UUID: Task<Void, Never>] = [:]

    init(
        settings: AppSettingsStore,
        observer: any TranscriptChangeObserving = TranscriptChangeWatcher(),
        reader: any TranscriptTailReading = ClaudeTranscriptReader(),
        notifier: any UserNotifier = SystemUserNotifier(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleepForSeconds: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.settings = settings
        self.observer = observer
        self.reader = reader
        self.notifier = notifier
        self.now = now
        self.sleepForSeconds = sleepForSeconds

        // The value Combine hands the sink, never a re-read of the store: it
        // publishes on `willSet` — the trap `SyncScheduleController` documents.
        cancellable = settings.$agentWaitingNotificationsEnabled.sink { [weak self] enabled in
            MainActor.assumeIsolated {
                enabled ? self?.start() : self?.pause()
            }
        }
    }

    func stop() {
        cancellable = nil
        pause()
    }

    /// Returns once every tail read started so far has been recorded (or
    /// dropped, if the controller was paused meanwhile).
    func waitForPendingReads() async {
        while let (id, read) = pendingReads.first {
            await read.value
            pendingReads[id] = nil
        }
    }

    private func start() {
        guard loop == nil else { return }
        observer.start { [weak self] urls in self?.read(urls) }

        let sleepForSeconds = sleepForSeconds
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleepForSeconds(Self.tickInterval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    /// Off forgets every phase, so turning it back on cannot report a wait
    /// that began while the user had asked not to be told.
    private func pause() {
        observer.stop()
        loop?.cancel()
        loop = nil
        tracker = WaitingAgentTracker()
    }

    /// Off the main actor: a tail read opens a file. Each file costs only that
    /// file — a transcript deleted between event and read is skipped.
    private func read(_ urls: [URL]) {
        let reader = reader
        let id = UUID()
        pendingReads[id] = Task { @MainActor [weak self] in
            let tails = await Task.detached(priority: .utility) {
                urls.compactMap { try? reader.readTail(at: $0) }
            }.value
            guard let self else { return }
            self.pendingReads[id] = nil
            guard self.loop != nil else { return }
            for tail in tails { self.tracker.record(tail) }
        }
    }

    private func tick() async {
        await waitForPendingReads()
        let now = now()
        let delay = TimeInterval(settings.agentWaitingDelayMinutes * 60)
        let due = tracker.due(now: now, delay: delay)
        guard !due.isEmpty else { return }
        await notifier.notifyAgentsWaiting(due, now: now)
    }
}
