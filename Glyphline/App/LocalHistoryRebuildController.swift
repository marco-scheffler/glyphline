import Foundation

/// Runs the one-time rebuild of the inflated local usage history on the first
/// launch after updating.
///
/// App-level rather than attached to a view, for the reason
/// `SyncScheduleController` is: the local scan hangs off the dashboard's
/// appearance, and in the default mode no window opens at launch at all. A
/// correction that only runs if the user happens to open a window is a
/// correction most installations never get.
///
/// The work itself is off the main actor and off the launch path — it re-reads
/// every transcript on the machine, about twenty seconds and 3,310 files on the
/// reference machine — and it goes through `LocalHistoryWriteGate`, which is what
/// keeps the ordinary launch scan from adding its totals on top of the day this
/// has just replaced.
@MainActor
final class LocalHistoryRebuildController {
    /// Exposed so a test can await the rebuild instead of polling for its
    /// effects. Never nil: on the paths where no rebuild runs it is the task that
    /// tells the gate so, and that release has to be awaitable for the same
    /// reason the rebuild does.
    let task: Task<Void, Never>?

    /// - Parameter rebuild: reads the transcripts and applies the result in one
    ///   transaction, reporting whether the rebuild may be marked done. Throwing,
    ///   or reporting `false`, leaves the marker unset so the next launch tries
    ///   again — which is what a half-finished run wants, because the transaction
    ///   means nothing of it landed, and what a launch that could not read the
    ///   transcripts at all wants, because the single shot must not be spent on
    ///   nothing.
    init(
        settings: AppSettingsStore,
        gate: LocalHistoryWriteGate,
        rebuild: (@Sendable () throws -> Bool)?
    ) {
        let outstanding = !settings.hasRebuiltLocalHistory
            || !settings.hasRebuiltLocalSessionTokens
        guard outstanding, let rebuild else {
            // Every path that declines to rebuild must open the gate, because
            // whoever armed it is not coming. The `!outstanding` half is the
            // harmless one — the gate was never armed, so releasing it is a
            // no-op. The `rebuild == nil` half is the hazard: with no ledger the
            // markers are still unset, so `GlyphlineApp.init` armed the gate, and
            // nothing else can ever open it. Every `runScan` would then suspend
            // forever and local usage would silently stop updating, with no error
            // and no bound. Releasing on both is one line and cannot weaken the
            // exclusion: a rebuild that *is* running still holds the gate until
            // its own `defer`.
            task = Task { await gate.declineRebuild() }
            return
        }

        task = Task {
            if await gate.runRebuild(rebuild) {
                // Both markers, one verdict. The closure runs exactly the halves
                // that were outstanding and reports whether that landed; a half
                // already done is already marked, so setting it again is a no-op.
                settings.hasRebuiltLocalHistory = true
                settings.hasRebuiltLocalSessionTokens = true
            }
        }
    }

    /// The production wiring: read every transcript under the Claude Code
    /// projects directory, and hand the result to the ledger whole.
    convenience init(
        settings: AppSettingsStore,
        gate: LocalHistoryWriteGate,
        ledger: LedgerStore?,
        directory: URL = SyncCoordinator.claudeProjectsDirectory
    ) {
        guard let ledger else {
            self.init(settings: settings, gate: gate, rebuild: nil)
            return
        }

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        // Read which halves are outstanding here, on the main actor, before the
        // detached work starts — and run only those. One pass feeds both: two
        // reads of 3,310 files would be forty seconds instead of twenty, and two
        // figures read from the same lines at different times could disagree.
        let rebuildsDays = !settings.hasRebuiltLocalHistory
        let rebuildsSessions = !settings.hasRebuiltLocalSessionTokens
        self.init(settings: settings, gate: gate) {
            let scan = try reader.readForRebuild()
            var mayMarkDone = true
            if rebuildsDays {
                mayMarkDone = try ledger.applyLocalHistoryRebuild(scan) && mayMarkDone
            }
            if rebuildsSessions {
                mayMarkDone = try ledger.applyLocalSessionTokenRebuild(scan) && mayMarkDone
            }
            return mayMarkDone
        }
    }
}
