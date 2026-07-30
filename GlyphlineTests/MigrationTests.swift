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

    /// The user's live ledger holds samples written under v6's `NOT NULL`, and
    /// this migration recreates the table to lift that constraint. Recreate-and-
    /// copy is exactly the step where rows go missing, so the surviving row is
    /// checked value by value — not merely counted.
    func testV8KeepsEveryExistingSampleWhileMakingTheResetInstantNullable() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()

        try migrator.migrate(dbQueue, upTo: "v7_claude_organization_id")

        let accountID = UUID()
        let sampleID = UUID().uuidString
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = Date(timeIntervalSince1970: 1_800_003_600)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO rateWindowSamples (id, accountID, kind, observedAt, usedFraction, resetAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    sampleID, accountID.uuidString, RateWindowKind.rollingFiveHours.rawValue,
                    observedAt, 0.62, resetAt,
                ]
            )
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rateWindowSamples"),
                1,
                "the recreate-and-copy must not lose a row"
            )

            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT * FROM rateWindowSamples WHERE id = ?",
                arguments: [sampleID]
            ))
            XCTAssertEqual(row["accountID"], accountID.uuidString)
            XCTAssertEqual(row["kind"], RateWindowKind.rollingFiveHours.rawValue)
            XCTAssertEqual((row["observedAt"] as Date).timeIntervalSince1970,
                           observedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(row["usedFraction"] as Double?), 0.62, accuracy: 1e-9)
            XCTAssertEqual(
                try XCTUnwrap(row["resetAt"] as Date?).timeIntervalSince1970,
                resetAt.timeIntervalSince1970,
                accuracy: 0.001,
                "an existing reset instant must come through unchanged, not blanked"
            )
        }

        // And the point of the whole migration: the column now accepts NULL.
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO rateWindowSamples (id, accountID, kind, observedAt, usedFraction, resetAt)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    UUID().uuidString, accountID.uuidString, RateWindowKind.weekly.rawValue,
                    observedAt, 0.0,
                ]
            )
        }

        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rateWindowSamples"), 2)
        }
    }

    /// Dropping the old table takes its index with it, and a rename does not
    /// bring one along. Without this the "newest sample per account and kind"
    /// read — which runs on every menu open — silently degrades to a scan.
    func testV8LeavesTheSampleIndexInPlace() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)

        try dbQueue.read { db in
            let indexes = try db.indexes(on: LedgerTable.rateWindowSamples)
            let sampleIndex = try XCTUnwrap(
                indexes.first { $0.name == "index_rateWindowSamples_on_account_kind_observedAt" },
                "index names: \(indexes.map(\.name))"
            )
            XCTAssertEqual(
                sampleIndex.columns,
                [LedgerColumn.accountID, LedgerColumn.kind, LedgerColumn.observedAt]
            )
        }
    }

    /// A v6 database — one that never saw v7 either — must arrive at the current
    /// schema with its samples intact. The upgrade path a real install takes is
    /// the whole chain, not the last step alone.
    func testASampleWrittenUnderV6SurvivesTheWholeChain() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()

        try migrator.migrate(dbQueue, upTo: "v6_rate_window_samples")

        let accountID = UUID()
        let observedAt = Date(timeIntervalSince1970: 1_799_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO rateWindowSamples (id, accountID, kind, observedAt, usedFraction, resetAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, accountID.uuidString, RateWindowKind.weekly.rawValue,
                    observedAt, 0.31, observedAt.addingTimeInterval(86_400),
                ]
            )
        }

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        let windows = try store.fetchLatestRateWindows(accountID: accountID)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(try XCTUnwrap(windows.first?.usedFraction), 0.31, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(windows.first?.resetAt).timeIntervalSince1970,
            observedAt.addingTimeInterval(86_400).timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
