import GRDB
import XCTest
@testable import Glyphline

final class AccountDeletionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two accounts, both populated. The second one exists for one reason: an
    /// assertion checks that deleting the first left the second untouched, so a
    /// `DELETE` that lost its `WHERE` cannot pass.
    private func makeStore() throws -> (LedgerStore, DatabaseQueue, UUID, UUID) {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)

        let doomed = UUID()
        let survivor = UUID()

        for id in [doomed, survivor] {
            try store.saveAccount(
                Account(
                    id: id,
                    providerID: .claude,
                    displayName: "Max #\(id.uuidString.prefix(4))",
                    credentialReference: "local-source://\(id.uuidString)",
                    createdAt: now,
                    isEnabled: true
                )
            )
            try populate(store, dbQueue, accountID: id)
        }

        return (store, dbQueue, doomed, survivor)
    }

    /// Writes exactly one row into every table that carries an accountID.
    private func populate(_ store: LedgerStore, _ dbQueue: DatabaseQueue, accountID: UUID) throws {
        let bucketStart = now
        let bucketEnd = now.addingTimeInterval(86_400)

        try store.upsertUsageSnapshots([
            UsageSnapshot(
                id: UUID(),
                accountID: accountID,
                providerID: .claude,
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                model: "claude-opus-4",
                inputTokens: 10,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                outputTokens: 5,
                requests: 1,
                quality: .exact
            )
        ])
        try store.upsertCostSnapshots([
            CostSnapshot(
                id: UUID(),
                accountID: accountID,
                providerID: .claude,
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                amountMicros: 1_000,
                currency: "USD",
                quality: .exact
            )
        ])
        try store.upsertEstimateSnapshots([
            EstimateSnapshot(
                id: UUID(),
                accountID: accountID,
                providerID: .claude,
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                estimatedAmountMicros: 900,
                currency: "USD",
                quality: .estimated
            )
        ])

        let runID = try store.startSyncRun(accountID: accountID, providerID: .claude, startedAt: now)
        try store.finishSyncRun(id: runID, status: .succeeded, message: nil, finishedAt: now)

        try store.saveWatermark(
            SyncWatermark(
                sourceKey: "\(accountID.uuidString)/file.jsonl",
                accountID: accountID,
                fileSize: 10,
                fileMTime: now,
                byteOffset: 10,
                updatedAt: now
            )
        )

        try store.saveBackfillCompletedThrough(now, accountID: accountID)

        // resetAt must be in the future relative to observedAt, or
        // `RateWindow.isPlausible` rejects the sample and nothing is written.
        _ = try store.saveRateWindow(
            RateWindow(
                kind: .rollingFiveHours,
                usedFraction: 0.4,
                resetAt: now.addingTimeInterval(3_600),
                observedAt: now
            ),
            accountID: accountID
        )
    }

    private func count(_ dbQueue: DatabaseQueue, _ table: String, _ column: String, _ id: UUID) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
                arguments: [id.uuidString]
            ) ?? 0
        }
    }

    /// Row counts per table for one account. `accounts` is keyed by `id`, every
    /// other owning table by `accountID`.
    private func rowCounts(_ dbQueue: DatabaseQueue, _ id: UUID) throws -> [(String, Int)] {
        var counts: [(String, Int)] = []
        counts.append((LedgerTable.accounts, try count(dbQueue, LedgerTable.accounts, LedgerColumn.id, id)))
        for table in [
            LedgerTable.usageSnapshots,
            LedgerTable.costSnapshots,
            LedgerTable.estimateSnapshots,
            LedgerTable.syncRuns,
            LedgerTable.accountSyncStates,
            LedgerTable.syncWatermarks,
            LedgerTable.rateWindowSamples
        ] {
            counts.append((table, try count(dbQueue, table, LedgerColumn.accountID, id)))
        }
        return counts
    }

    func testTheFixtureWritesARowIntoEveryOwningTable() throws {
        let (_, dbQueue, doomed, _) = try makeStore()
        // Guards the two tests below: if the fixture silently wrote nothing, the
        // deletion test would pass against an already-empty table.
        for (table, count) in try rowCounts(dbQueue, doomed) {
            XCTAssertEqual(count, 1, "fixture wrote no row into \(table)")
        }
    }

    func testDeletingRemovesRowsFromEveryOwningTable() throws {
        let (store, dbQueue, doomed, _) = try makeStore()
        try store.deleteAccount(id: doomed)
        for (table, count) in try rowCounts(dbQueue, doomed) {
            XCTAssertEqual(count, 0, "\(table) still holds rows for the deleted account")
        }
    }

    func testDeletingLeavesOtherAccountsUntouched() throws {
        let (store, dbQueue, doomed, survivor) = try makeStore()
        try store.deleteAccount(id: doomed)
        for (table, count) in try rowCounts(dbQueue, survivor) {
            XCTAssertEqual(count, 1, "\(table) lost the surviving account's row")
        }
    }

    func testDeletingAnAccountThatDoesNotExistIsNotAnError() throws {
        let (store, _, _, _) = try makeStore()
        XCTAssertNoThrow(try store.deleteAccount(id: UUID()))
    }

    func testTheSummaryCountsWhatTheDialogShows() throws {
        let (store, _, doomed, _) = try makeStore()
        let summary = try store.deletionSummary(accountID: doomed)
        XCTAssertEqual(summary.rateWindowSampleCount, 1)
        XCTAssertEqual(summary.costSnapshotCount, 1)
        XCTAssertEqual(summary.usageSnapshotCount, 1)
        XCTAssertEqual(summary.earliestRateWindowObservedAt, now)
    }

    func testTheSummaryReportsNothingForAnAccountWithNoHistory() throws {
        let (store, _, _, _) = try makeStore()
        let summary = try store.deletionSummary(accountID: UUID())
        XCTAssertEqual(summary.rateWindowSampleCount, 0)
        XCTAssertEqual(summary.costSnapshotCount, 0)
        XCTAssertEqual(summary.usageSnapshotCount, 0)
        XCTAssertNil(summary.earliestRateWindowObservedAt)
    }

    func testTheSummaryReportsTheOldestObservation() throws {
        let (store, _, doomed, _) = try makeStore()
        let older = now.addingTimeInterval(-86_400)
        _ = try store.saveRateWindow(
            RateWindow(
                kind: .rollingFiveHours,
                usedFraction: 0.1,
                resetAt: older.addingTimeInterval(3_600),
                observedAt: older
            ),
            accountID: doomed
        )
        let summary = try store.deletionSummary(accountID: doomed)
        XCTAssertEqual(summary.rateWindowSampleCount, 2)
        XCTAssertEqual(summary.earliestRateWindowObservedAt, older)
    }
}
