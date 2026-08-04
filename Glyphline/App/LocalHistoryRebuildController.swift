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
/// reference machine.
@MainActor
final class LocalHistoryRebuildController {
    /// Exposed so a test can await the rebuild instead of polling for its
    /// effects. Nil when the rebuild had already run, or when there was nothing
    /// to run it against.
    let task: Task<Void, Never>?

    /// - Parameter rebuild: reads the transcripts and applies the result in one
    ///   transaction. Throwing leaves the marker unset, so the next launch tries
    ///   again — which is exactly what a half-finished run wants, because the
    ///   transaction means nothing of it landed.
    init(settings: AppSettingsStore, rebuild: (@Sendable () throws -> Void)?) {
        guard !settings.hasRebuiltLocalHistory, let rebuild else {
            task = nil
            return
        }

        task = Task {
            let succeeded = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try rebuild()
                    return true
                } catch {
                    return false
                }
            }.value

            if succeeded {
                settings.hasRebuiltLocalHistory = true
            }
        }
    }

    /// The production wiring: read every transcript under the Claude Code
    /// projects directory, and hand the result to the ledger whole.
    convenience init(
        settings: AppSettingsStore,
        ledger: LedgerStore?,
        directory: URL = SyncCoordinator.claudeProjectsDirectory
    ) {
        guard let ledger else {
            self.init(settings: settings, rebuild: nil)
            return
        }

        let reader = ClaudeCodeLogReader(directory: directory, watermarkStore: ledger)
        self.init(settings: settings) {
            try ledger.applyLocalHistoryRebuild(reader.readForRebuild())
        }
    }
}
