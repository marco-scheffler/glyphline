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
    /// effects. Nil when the rebuild had already run, or when there was nothing
    /// to run it against.
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
        guard !settings.hasRebuiltLocalHistory, let rebuild else {
            task = nil
            return
        }

        task = Task {
            if await gate.runRebuild(rebuild) {
                settings.hasRebuiltLocalHistory = true
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
        self.init(settings: settings, gate: gate) {
            try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
        }
    }
}
