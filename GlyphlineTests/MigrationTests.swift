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
}
