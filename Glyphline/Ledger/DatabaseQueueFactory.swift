import Foundation
import GRDB

enum DatabaseQueueFactory {
    /// How long a connection waits for a lock before it gives up.
    ///
    /// Long enough to outlast any write this app makes — the largest is one
    /// backfill slice — and short enough that a genuinely wedged connection
    /// still surfaces rather than hanging the UI.
    static let busyTimeoutSeconds: TimeInterval = 5

    static func makeInMemory() throws -> DatabaseQueue {
        try DatabaseQueue()
    }

    /// Configuration for the on-disk ledger.
    ///
    /// The app opens a separate `DatabaseQueue` on the same file from each scene
    /// — the app itself, the dashboard, the menu bar and the add-account sheet —
    /// so a queue serializes only its own access, never access across
    /// connections. Scheduled sync made that matter: writes now happen unattended
    /// at arbitrary instants and can overlap a read from another connection.
    ///
    /// Under GRDB's defaults that read fails. The rollback journal takes an
    /// EXCLUSIVE lock for the duration of a commit, and `busyMode` defaults to
    /// `.immediateError`, so the reader gets `SQLITE_BUSY` thrown at it rather
    /// than retried. WAL lets readers proceed against the last committed snapshot
    /// while a writer works, and the busy timeout makes what contention remains
    /// wait instead of fail.
    static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(busyTimeoutSeconds)
        return configuration
    }

    static func makeDefault() throws -> DatabaseQueue {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("Glyphline", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("glyphline.sqlite", isDirectory: false)
        return try DatabaseQueue(path: databaseURL.path, configuration: makeConfiguration())
    }
}
