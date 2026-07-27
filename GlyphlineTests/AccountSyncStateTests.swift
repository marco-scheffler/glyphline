import GRDB
import XCTest

@testable import Glyphline

final class AccountSyncStateTests: XCTestCase {
    func testSuccessfulSyncPersistsCapabilitiesBillingPeriodAndAccountSummary() throws {
        let store = try makeStore()
        let account = makeAccount()
        let syncRunID = try store.startSyncRun(
            accountID: account.id,
            providerID: account.providerID,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.saveAccount(account)

        let result = makeSyncResult(account: account)

        try store.applySuccessfulSyncResult(
            result,
            syncRunID: syncRunID,
            finishedAt: Date(timeIntervalSince1970: 1_800_000_030)
        )

        let summary = try XCTUnwrap(store.fetchAccountSummaries().first)

        XCTAssertEqual(summary.account, account)
        XCTAssertEqual(summary.capabilities?.supportsActualCost, true)
        XCTAssertEqual(summary.capabilities?.supportsResetDate, true)
        XCTAssertEqual(summary.capabilities?.dataQuality, .exact)
        XCTAssertEqual(summary.billingPeriod?.resetAt, Date(timeIntervalSince1970: 1_802_592_000))
        XCTAssertEqual(summary.requestCount, 4)
        XCTAssertEqual(summary.totalTokens, 300)
        XCTAssertEqual(summary.displayAmountMicros, 2_500)
        XCTAssertEqual(summary.displayCurrency, "USD")
        XCTAssertEqual(summary.dataQuality, .exact)
        XCTAssertEqual(summary.latestSyncRun?.status, .succeeded)
    }

    func testSuccessfulSyncRollsBackSnapshotsWhenLaterLedgerWriteFails() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)
        let account = makeAccount()
        let syncRunID = try store.startSyncRun(
            accountID: account.id,
            providerID: account.providerID,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.saveAccount(account)

        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_estimate_insert
                BEFORE INSERT ON estimateSnapshots
                BEGIN
                    SELECT RAISE(ABORT, 'forced estimate failure');
                END
                """)
        }

        XCTAssertThrowsError(
            try store.applySuccessfulSyncResult(
                makeSyncResult(account: account),
                syncRunID: syncRunID,
                finishedAt: Date(timeIntervalSince1970: 1_800_000_030)
            )
        )

        XCTAssertTrue(try store.fetchUsageSnapshots(accountID: account.id).isEmpty)
        XCTAssertTrue(try store.fetchCostSnapshots(accountID: account.id).isEmpty)
        XCTAssertTrue(try store.fetchEstimateSnapshots(accountID: account.id).isEmpty)
        XCTAssertTrue(try store.fetchAccountSummaries().allSatisfy { $0.capabilities == nil })
        XCTAssertEqual(try store.fetchSyncRuns(accountID: account.id).first?.status, .running)
    }

    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Personal",
            credentialReference: "keychain://glyphline/\(UUID().uuidString)",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
    }

    private func makeSyncResult(account: Account) -> ProviderSyncResult {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(86_400)

        return ProviderSyncResult(
            providerID: account.providerID,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: true,
                supportsResetDate: true,
                supportsModelBreakdown: true,
                dataQuality: .exact,
                message: nil
            ),
            billingPeriod: BillingPeriod(
                startsAt: start,
                endsAt: Date(timeIntervalSince1970: 1_802_592_000),
                resetAt: Date(timeIntervalSince1970: 1_802_592_000)
            ),
            usageSnapshots: [
                UsageSnapshot(
                    id: UUID(),
                    accountID: account.id,
                    providerID: account.providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    model: "fixture-model",
                    inputTokens: 100,
                    outputTokens: 200,
                    requests: 4,
                    quality: .exact
                )
            ],
            costSnapshots: [
                CostSnapshot(
                    id: UUID(),
                    accountID: account.id,
                    providerID: account.providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    amountMicros: 2_500,
                    currency: "USD",
                    quality: .exact
                )
            ],
            estimateSnapshots: [
                EstimateSnapshot(
                    id: UUID(),
                    accountID: account.id,
                    providerID: account.providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    estimatedAmountMicros: 2_750,
                    currency: "USD",
                    quality: .estimated
                )
            ],
            syncedAt: end
        )
    }
}
