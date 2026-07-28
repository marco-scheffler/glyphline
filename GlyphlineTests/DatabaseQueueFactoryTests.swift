import GRDB
import XCTest
@testable import Glyphline

/// The on-disk ledger is opened once per scene, so several connections share the
/// file and scheduled sync writes to it unattended. These tests pin the two
/// settings that keep a concurrent read from failing outright.
final class DatabaseQueueFactoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name, isDirectory: false).path
    }

    /// Asserted against a real database file rather than against the `Configuration`
    /// struct, so the test fails if GRDB ever stops applying either setting.
    func testTheOnDiskLedgerRunsInWALWithABusyTimeout() throws {
        let queue = try DatabaseQueue(
            path: path("configured.sqlite"),
            configuration: DatabaseQueueFactory.makeConfiguration()
        )

        let journalMode = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        let busyTimeout = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
        }

        XCTAssertEqual(journalMode, "wal", "a rollback journal takes an EXCLUSIVE lock to commit")
        XCTAssertEqual(
            busyTimeout,
            Int(DatabaseQueueFactory.busyTimeoutSeconds * 1000),
            "GRDB defaults to .immediateError, which throws SQLITE_BUSY instead of retrying"
        )
    }

    /// The negative control: GRDB's defaults, which is what `makeDefault` used to
    /// pass, give neither of the two properties above.
    func testGRDBDefaultsGiveNeitherWALNorABusyTimeout() throws {
        let queue = try DatabaseQueue(path: path("defaults.sqlite"))

        let journalMode = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        let busyTimeout = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
        }

        XCTAssertNotEqual(journalMode, "wal")
        XCTAssertEqual(busyTimeout, 0)
    }

    /// Two `LedgerStore`s on the same file are the app's real shape — one per scene.
    /// Whatever the second one reads, it must not be refused outright.
    func testASecondConnectionCanReadAfterTheFirstHasWritten() throws {
        let databasePath = path("shared.sqlite")
        let writerQueue = try DatabaseQueue(
            path: databasePath,
            configuration: DatabaseQueueFactory.makeConfiguration()
        )
        try Migrations.migrate(writerQueue)

        let readerQueue = try DatabaseQueue(
            path: databasePath,
            configuration: DatabaseQueueFactory.makeConfiguration()
        )

        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Shared",
            credentialReference: "keychain://glyphline/shared",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try LedgerStore(dbQueue: writerQueue).saveAccount(account)

        let fetched = try LedgerStore(dbQueue: readerQueue).fetchAccounts()

        XCTAssertEqual(fetched.map(\.id), [account.id])
    }
}
