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

    /// v9 adds the two account-free tables. The absence of an account column is
    /// the point, not an oversight: the transcripts cannot be attributed to a
    /// subscription, so a column — even a nullable one — would be read as an
    /// attribution that does not exist.
    func testV9CreatesAccountFreeLocalTables() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists(LedgerTable.localTokenUsage))
            XCTAssertTrue(try db.tableExists(LedgerTable.localScanWatermarks))

            let usageColumns = try db.columns(in: LedgerTable.localTokenUsage).map(\.name)
            XCTAssertFalse(
                usageColumns.contains(LedgerColumn.accountID),
                "these totals span every subscription and must carry no account"
            )
            XCTAssertEqual(
                Set(usageColumns),
                Set([
                    LedgerColumn.bucketStart, LedgerColumn.modelKey, LedgerColumn.model,
                    LedgerColumn.inputTokens, LedgerColumn.cacheCreationTokens,
                    LedgerColumn.cacheReadTokens, LedgerColumn.outputTokens,
                    LedgerColumn.requests,
                ])
            )

            let primaryKey = try db.primaryKey(LedgerTable.localTokenUsage)
            XCTAssertEqual(primaryKey.columns, [LedgerColumn.bucketStart, LedgerColumn.modelKey])

            let watermarkColumns = try db.columns(in: LedgerTable.localScanWatermarks).map(\.name)
            XCTAssertFalse(watermarkColumns.contains(LedgerColumn.accountID))
            XCTAssertEqual(
                Set(watermarkColumns),
                Set([
                    LedgerColumn.sourceKey, LedgerColumn.fileSize, LedgerColumn.fileMTime,
                    LedgerColumn.byteOffset, LedgerColumn.updatedAt,
                ])
            )
        }
    }

    /// v9 only adds. A database that stopped at v8 must arrive with its existing
    /// sync watermarks — which do carry an account — untouched.
    func testV9LeavesSyncWatermarksAloneAndPreservesTheirRows() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()

        try migrator.migrate(dbQueue, upTo: "v8_rate_window_reset_optional")

        let accountID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO syncWatermarks (sourceKey, accountID, fileSize, fileMTime, byteOffset, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["/tmp/existing.jsonl", accountID.uuidString, 4_096, stamp, 2_048, stamp]
            )
        }

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        let surviving = try XCTUnwrap(try store.fetchWatermark(sourceKey: "/tmp/existing.jsonl"))
        XCTAssertEqual(surviving.accountID, accountID)
        XCTAssertEqual(surviving.byteOffset, 2_048)

        try dbQueue.read { db in
            XCTAssertTrue(
                try db.columns(in: LedgerTable.syncWatermarks).map(\.name)
                    .contains(LedgerColumn.accountID),
                "syncWatermarks keeps its account; only the new table drops the concept"
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

    /// The table is new, so nothing is carried across — what matters is that a
    /// database already at v9 reaches v10 and can hold a row.
    func testV10AddsTheParkedAgentTableToAnExistingLedger() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v9_local_token_usage")

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        try store.saveParkedAgent(
            ParkedAgentSession(
                sessionID: "S1",
                cwd: "/repo",
                gitBranch: nil,
                subagentCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
                parkedAt: Date(timeIntervalSince1970: 1_800_003_600)
            )
        )

        XCTAssertEqual(try store.fetchParkedAgents().count, 1)
        XCTAssertNil(try store.fetchParkedAgents()[0].gitBranch)
    }

    func testV11AddsTheSessionTokenTableToAnExistingLedger() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v10_agentverse_parked")

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        try store.applyLocalScan(
            LocalScanResult(
                usage: [],
                sessionUsage: [LocalSessionTokenUsage(sessionID: "S1", model: nil,
                                                      inputTokens: 3)],
                watermarks: []
            )
        )

        XCTAssertEqual(try store.fetchSessionTokens(sessionIDs: ["S1"])["S1"], 3)
    }

    /// The table already exists and already holds rows, so this is the case a
    /// naive migration test misses: v12 has to add its two columns to a
    /// *populated* `agentverseParked` and leave every row where it was.
    func testV12AddsTheTitleColumnsWithoutDisturbingExistingParkedRows() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v11_local_session_tokens")

        let lastActivityAt = Date(timeIntervalSince1970: 1_800_000_000)
        let parkedAt = Date(timeIntervalSince1970: 1_800_003_600)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agentverseParked
                        (sessionID, cwd, gitBranch, subagentCount, lastActivityAt, parkedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["S1", "/Users/x/coding/Acme-Suite", "main", 2,
                            lastActivityAt, parkedAt]
            )
        }

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        let rows = try store.fetchParkedAgents()
        XCTAssertEqual(rows.count, 1, "the pre-migration row must survive")
        XCTAssertEqual(rows[0].sessionID, "S1")
        XCTAssertEqual(rows[0].cwd, "/Users/x/coding/Acme-Suite")
        XCTAssertEqual(rows[0].gitBranch, "main")
        XCTAssertEqual(rows[0].subagentCount, 2)
        XCTAssertEqual(rows[0].lastActivityAt, lastActivityAt)
        XCTAssertEqual(rows[0].parkedAt, parkedAt)
        XCTAssertNil(rows[0].aiTitle, "a row written before v12 has no title")
        XCTAssertNil(rows[0].slug)
    }

    /// A row that predates v12 has nothing to name itself with but its checkout,
    /// and an empty label would be worse than a repeated one.
    func testAPreMigrationParkedRowStillLabelsItselfWithItsRepository() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v11_local_session_tokens")

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agentverseParked
                        (sessionID, cwd, gitBranch, subagentCount, lastActivityAt, parkedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["S1", "/Users/x/coding/Acme-Suite", nil, 0,
                            Date(timeIntervalSince1970: 1_800_000_000),
                            Date(timeIntervalSince1970: 1_800_003_600)]
            )
        }

        try migrator.migrate(dbQueue)

        let row = try XCTUnwrap(LedgerStore(dbQueue: dbQueue).fetchParkedAgents().first)
        XCTAssertEqual(row.displayTitle, "Acme-Suite")
        XCTAssertEqual(AgentRowModel(parked: row, workTokens: 0).title, "Acme-Suite")
    }

    /// The case a naive migration test misses: `accounts` is populated long
    /// before v13, so the column has to be added to real rows. Those rows must
    /// keep their derived name and come back with no chosen one — a migration
    /// that backfilled `customName` would make every existing account look
    /// renamed and destroy the fallback it is supposed to have.
    func testV13AddsTheChosenNameWithoutDisturbingExistingAccounts() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v12_parked_session_title")

        let accountID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts
                        (id, providerID, displayName, credentialReference, createdAt, isEnabled)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID.uuidString, "claude", "Claude personal",
                    "local-source://\(accountID.uuidString)", createdAt, true,
                ]
            )
        }

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        let account = try XCTUnwrap(store.fetchAccounts().first)
        XCTAssertEqual(account.id, accountID, "the pre-migration account must survive")
        XCTAssertEqual(account.displayName, "Claude personal")
        XCTAssertEqual(account.createdAt, createdAt)
        XCTAssertNil(account.customName, "an account written before v13 was never renamed")
        XCTAssertEqual(account.resolvedName, "Claude personal")
    }

    /// v14 adds the table that stops an assistant message being counted once per
    /// transcript. The case a naive migration test misses is the one that matters
    /// here: `localTokenUsage` is populated long before v14, and those totals are
    /// the user's history. The migration must add the table and leave every
    /// counted token exactly where it was.
    func testV14AddsTheSeenMessageTableWithoutDisturbingTheCountedTokens() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v13_account_custom_name")

        let bucketStart = Date(timeIntervalSince1970: 1_800_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO localTokenUsage
                        (bucketStart, modelKey, model, inputTokens, cacheCreationTokens,
                         cacheReadTokens, outputTokens, requests)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [bucketStart, "sonnet", "sonnet", 10, 20, 30, 40, 1]
            )
        }

        try migrator.migrate(dbQueue)

        let store = LedgerStore(dbQueue: dbQueue)
        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1, "the pre-migration totals must survive")
        XCTAssertEqual(rows[0].bucketStart, bucketStart)
        XCTAssertEqual(rows[0].inputTokens, 10)
        XCTAssertEqual(rows[0].cacheCreationTokens, 20)
        XCTAssertEqual(rows[0].cacheReadTokens, 30)
        XCTAssertEqual(rows[0].outputTokens, 40)

        XCTAssertTrue(
            try store.fetchSeenMessageIDs().isEmpty,
            "a ledger migrated to v14 has counted nothing it can name yet"
        )
        try store.applyLocalScan(
            LocalScanResult(
                usage: [],
                watermarks: [],
                seenMessages: [LocalSeenMessage(messageID: "msg_1", seenAt: bucketStart)]
            )
        )
        XCTAssertEqual(try store.fetchSeenMessageIDs(), ["msg_1"])
    }
}
