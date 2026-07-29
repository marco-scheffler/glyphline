import GRDB
import XCTest
@testable import Glyphline

final class MigrationTests: XCTestCase {
    func testV4PreservesExistingRowsAndDefaultsCacheColumnsToZero() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()

        // Bring the database up to the state that shipped before this task.
        try migrator.migrate(dbQueue, upTo: "v3_create_account_sync_states")

        let accountID = UUID()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO usageSnapshots (
                        id, accountID, providerID, bucketStart, bucketEnd,
                        model, modelKey, inputTokens, outputTokens, requests, quality
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, accountID.uuidString, "openAI", day,
                    day.addingTimeInterval(86_400), "gpt-5.4", "value:gpt-5.4",
                    111, 222, 7, "exact",
                ]
            )
        }

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        let rows = try store.fetchUsageSnapshots(accountID: accountID)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inputTokens, 111)
        XCTAssertEqual(rows[0].outputTokens, 222)
        XCTAssertEqual(rows[0].requests, 7)
        XCTAssertEqual(rows[0].cacheCreationTokens, 0)
        XCTAssertEqual(rows[0].cacheReadTokens, 0)
    }

    func testRequestsSurvivesAsNil() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)
        let accountID = UUID()
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        try store.upsertUsageSnapshots([
            UsageSnapshot(
                id: UUID(),
                accountID: accountID,
                providerID: .claude,
                bucketStart: day,
                bucketEnd: day.addingTimeInterval(86_400),
                model: "claude-opus-4-8",
                inputTokens: 10,
                cacheCreationTokens: 20,
                cacheReadTokens: 30,
                outputTokens: 40,
                requests: nil,
                quality: .exact
            ),
        ])

        let rows = try store.fetchUsageSnapshots(accountID: accountID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].requests)
        XCTAssertEqual(rows[0].cacheCreationTokens, 20)
        XCTAssertEqual(rows[0].cacheReadTokens, 30)
    }

    func testWatermarkRoundTrips() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)
        let accountID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNil(try store.fetchWatermark(sourceKey: "/tmp/a.jsonl"))

        try store.saveWatermark(
            SyncWatermark(
                sourceKey: "/tmp/a.jsonl",
                accountID: accountID,
                fileSize: 4096,
                fileMTime: stamp,
                byteOffset: 2048,
                updatedAt: stamp
            )
        )

        let stored = try store.fetchWatermark(sourceKey: "/tmp/a.jsonl")
        XCTAssertEqual(stored?.byteOffset, 2048)
        XCTAssertEqual(stored?.fileSize, 4096)

        try store.saveWatermark(
            SyncWatermark(
                sourceKey: "/tmp/a.jsonl",
                accountID: accountID,
                fileSize: 8192,
                fileMTime: stamp,
                byteOffset: 8192,
                updatedAt: stamp
            )
        )

        XCTAssertEqual(try store.fetchWatermark(sourceKey: "/tmp/a.jsonl")?.byteOffset, 8192)
    }

    func testBackfillProgressRoundTrips() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)
        let accountID = UUID()
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNil(try store.fetchBackfillCompletedThrough(accountID: accountID))

        let account = Account(
            id: accountID,
            providerID: .claude,
            displayName: "Personal",
            credentialReference: "keychain://glyphline/\(accountID.uuidString)",
            createdAt: day,
            isEnabled: true
        )
        try store.saveAccount(account)

        // The accountSyncStates row that carries backfill progress is created by
        // a successful sync, so establish it the same way production does.
        let syncRunID = try store.startSyncRun(
            accountID: accountID,
            providerID: account.providerID,
            startedAt: day
        )
        try store.applySuccessfulSyncResult(
            ProviderSyncResult(
                providerID: account.providerID,
                accountID: accountID,
                capabilities: ProviderCapabilities(
                    supportsUsage: true,
                    supportsActualCost: false,
                    supportsResetDate: false,
                    supportsModelBreakdown: true,
                    dataQuality: .exact,
                    message: nil
                ),
                billingPeriod: nil,
                usageSnapshots: [],
                costSnapshots: [],
                estimateSnapshots: [],
                syncedAt: day
            ),
            syncRunID: syncRunID,
            finishedAt: day
        )

        XCTAssertNil(try store.fetchBackfillCompletedThrough(accountID: accountID))

        try store.saveBackfillCompletedThrough(day, accountID: accountID)

        XCTAssertEqual(try store.fetchBackfillCompletedThrough(accountID: accountID), day)
    }

    func testV6CreatesRateWindowSamplesAndPreservesExistingAccounts() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()

        try migrator.migrate(dbQueue, upTo: "v5_sync_watermarks")

        let accountID = UUID()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, providerID, displayName, credentialReference, createdAt, isEnabled)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID.uuidString, "claude", "Max #1",
                    "local-source://\(accountID.uuidString)",
                    Date(timeIntervalSince1970: 1_800_000_000), true,
                ]
            )
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists(LedgerTable.rateWindowSamples))

            let survivingName = try String.fetchOne(
                db,
                sql: "SELECT displayName FROM accounts WHERE id = ?",
                arguments: [accountID.uuidString]
            )
            XCTAssertEqual(survivingName, "Max #1")
        }
    }

    func testV6AddsQuotaCredentialReferenceAsNullable() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)

        let accountID = UUID()
        try dbQueue.write { db in
            // Inserting without the new column must succeed: existing accounts have no quota source.
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, providerID, displayName, credentialReference, createdAt, isEnabled)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID.uuidString, "claude", "Max #2",
                    "local-source://\(accountID.uuidString)",
                    Date(timeIntervalSince1970: 1_800_000_000), true,
                ]
            )
        }

        try dbQueue.read { db in
            let reference = try String.fetchOne(
                db,
                sql: "SELECT quotaCredentialReference FROM accounts WHERE id = ?",
                arguments: [accountID.uuidString]
            )
            XCTAssertNil(reference)
        }
    }

    func testV7AddsClaudeOrganizationIDAsNullable() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)

        let accountID = UUID()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, providerID, displayName, credentialReference, createdAt, isEnabled)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID.uuidString, "claude", "Max #1",
                    "local-source://\(accountID.uuidString)",
                    Date(timeIntervalSince1970: 1_800_000_000), true,
                ]
            )
        }

        try dbQueue.read { db in
            XCTAssertNil(try String.fetchOne(
                db,
                sql: "SELECT claudeOrganizationID FROM accounts WHERE id = ?",
                arguments: [accountID.uuidString]
            ))
        }
    }

    /// A database that stopped at v6 must reach v7 with its accounts intact —
    /// an upgrade that dropped signed-in accounts would cost the user every login.
    func testV7PreservesAccountsFromAV6Database() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()

        try migrator.migrate(dbQueue, upTo: "v6_rate_window_samples")

        let accountID = UUID()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, providerID, displayName, credentialReference, createdAt, isEnabled)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID.uuidString, "claude", "Max #3",
                    "local-source://\(accountID.uuidString)",
                    Date(timeIntervalSince1970: 1_800_000_000), true,
                ]
            )
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let survivingName = try String.fetchOne(
                db,
                sql: "SELECT displayName FROM accounts WHERE id = ?",
                arguments: [accountID.uuidString]
            )
            XCTAssertEqual(survivingName, "Max #3")
            XCTAssertNil(try String.fetchOne(
                db,
                sql: "SELECT claudeOrganizationID FROM accounts WHERE id = ?",
                arguments: [accountID.uuidString]
            ))
        }
    }
}
