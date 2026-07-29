import GRDB
import XCTest
@testable import Glyphline

final class RateWindowStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // `LedgerStore.dbQueue` is private, so the test keeps its own reference to the
    // queue it created and counts rows through that.
    private func makeStore() throws -> (LedgerStore, DatabaseQueue, UUID) {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)

        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: "local-source://x",
            createdAt: now,
            isEnabled: true
        )
        try store.saveAccount(account)
        return (store, dbQueue, account.id)
    }

    private func sampleCount(_ dbQueue: DatabaseQueue) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rateWindowSamples") ?? 0
        }
    }

    func testAnUnchangedObservationIsNotWrittenTwice() throws {
        let (store, dbQueue, accountID) = try makeStore()
        let window = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.62,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now
        )

        try store.saveRateWindow(window, accountID: accountID)

        var repeated = window
        repeated.observedAt = now.addingTimeInterval(1_800)
        try store.saveRateWindow(repeated, accountID: accountID)

        XCTAssertEqual(try sampleCount(dbQueue), 1)
    }

    func testAChangedObservationIsAppended() throws {
        let (store, dbQueue, accountID) = try makeStore()
        let first = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.62,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
        try store.saveRateWindow(first, accountID: accountID)

        var second = first
        second.usedFraction = 0.71
        second.observedAt = now.addingTimeInterval(1_800)
        try store.saveRateWindow(second, accountID: accountID)

        XCTAssertEqual(try sampleCount(dbQueue), 2)

        let latest = try store.fetchLatestRateWindows(accountID: accountID)
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest.first?.usedFraction, 0.71)
    }

    func testASubMillisecondResetDifferenceIsNotTreatedAsAChange() throws {
        let (store, dbQueue, accountID) = try makeStore()

        // Microsecond precision, as claude.ai's resets_at carries.
        let reset = Date(timeIntervalSince1970: 1_800_003_600.695306)
        let window = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.04,
            resetAt: reset,
            observedAt: now
        )

        XCTAssertTrue(try store.saveRateWindow(window, accountID: accountID))

        // The same reading, re-observed. GRDB stored the reset truncated to
        // milliseconds, so an exact comparison sees a difference that is not one.
        var again = window
        again.observedAt = now.addingTimeInterval(1_800)
        _ = try store.saveRateWindow(again, accountID: accountID)

        XCTAssertEqual(try sampleCount(dbQueue), 1, "a sub-millisecond difference is storage noise, not a change")
    }

    func testAResetMovingByMoreThanTheToleranceIsStillAChange() throws {
        let (store, dbQueue, accountID) = try makeStore()
        let window = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.04,
            resetAt: Date(timeIntervalSince1970: 1_800_003_600),
            observedAt: now
        )
        XCTAssertTrue(try store.saveRateWindow(window, accountID: accountID))

        var moved = window
        moved.resetAt = window.resetAt.addingTimeInterval(60)
        moved.observedAt = now.addingTimeInterval(1_800)
        XCTAssertTrue(try store.saveRateWindow(moved, accountID: accountID))

        XCTAssertEqual(try sampleCount(dbQueue), 2)
    }

    func testImplausibleObservationsAreDiscarded() throws {
        let (store, dbQueue, accountID) = try makeStore()

        let overOne = RateWindow(
            kind: .weekly,
            usedFraction: 1.5,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
        let resetInThePast = RateWindow(
            kind: .weekly,
            usedFraction: 0.4,
            resetAt: now.addingTimeInterval(-60),
            observedAt: now
        )

        try store.saveRateWindow(overOne, accountID: accountID)
        try store.saveRateWindow(resetInThePast, accountID: accountID)

        XCTAssertEqual(try sampleCount(dbQueue), 0)
    }

    /// The store is the single authority on whether an observation is believable,
    /// and it reports that separately from whether a row was written. A dropped
    /// repeat is still a confirmation — that distinction is what the freshness
    /// tracking on the coordinator hangs on, and reproducing the plausibility
    /// rule at the call site would be the second copy this feature keeps growing.
    func testSavingReportsWhetherTheObservationWasBelievable() throws {
        let (store, _, accountID) = try makeStore()
        let window = RateWindow(
            kind: .rollingFiveHours,
            usedFraction: 0.62,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now
        )

        XCTAssertTrue(try store.saveRateWindow(window, accountID: accountID), "a fresh insert")

        var repeated = window
        repeated.observedAt = now.addingTimeInterval(1_800)
        XCTAssertTrue(
            try store.saveRateWindow(repeated, accountID: accountID),
            "a dropped repeat is still a confirmation of the value"
        )

        var implausible = window
        implausible.usedFraction = 1.5
        XCTAssertFalse(
            try store.saveRateWindow(implausible, accountID: accountID),
            "a rejected reading must not be reported as confirmed"
        )
    }

    func testLatestWindowsAreReturnedPerKind() throws {
        let (store, _, accountID) = try makeStore()

        try store.saveRateWindow(
            RateWindow(kind: .rollingFiveHours, usedFraction: 0.1,
                       resetAt: now.addingTimeInterval(3_600), observedAt: now),
            accountID: accountID
        )
        try store.saveRateWindow(
            RateWindow(kind: .weekly, usedFraction: 0.2,
                       resetAt: now.addingTimeInterval(86_400), observedAt: now),
            accountID: accountID
        )

        let latest = try store.fetchLatestRateWindows(accountID: accountID)
        XCTAssertEqual(Set(latest.map(\.kind)), [.rollingFiveHours, .weekly])
    }

    func testRetentionDeletesSamplesOlderThanTheCutoff() throws {
        let (store, dbQueue, accountID) = try makeStore()
        let old = now.addingTimeInterval(-400 * 86_400)

        try store.saveRateWindow(
            RateWindow(kind: .weekly, usedFraction: 0.3,
                       resetAt: old.addingTimeInterval(86_400), observedAt: old),
            accountID: accountID
        )
        try store.saveRateWindow(
            RateWindow(kind: .weekly, usedFraction: 0.9,
                       resetAt: now.addingTimeInterval(86_400), observedAt: now),
            accountID: accountID
        )
        XCTAssertEqual(try sampleCount(dbQueue), 2)

        try store.deleteRateWindowSamples(olderThan: now.addingTimeInterval(-365 * 86_400))

        XCTAssertEqual(try sampleCount(dbQueue), 1)
        XCTAssertEqual(try store.fetchLatestRateWindows(accountID: accountID).first?.usedFraction, 0.9)
    }
}
