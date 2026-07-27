import GRDB
import XCTest

@testable import Glyphline

final class SyncSchedulerTests: XCTestCase {
    func testSyncStoresUsageCostEstimateAndSyncRun() async throws {
        let ledger = try makeLedgerStore()
        let credentials = InMemoryCredentialStore()
        let account = makeAccount()

        try ledger.saveAccount(account)
        try credentials.save(secret: "fixture-secret", for: account.credentialReference)

        let scheduler = SyncScheduler(ledger: ledger, credentials: credentials)

        try await scheduler.sync(account: account, adapter: CostSnapshotProviderAdapter(providerID: .openAI))

        let usageSnapshots = try ledger.fetchUsageSnapshots(accountID: account.id)
        let costSnapshots = try ledger.fetchCostSnapshots(accountID: account.id)
        let estimateSnapshots = try ledger.fetchEstimateSnapshots(accountID: account.id)
        let syncRuns = try ledger.fetchSyncRuns(accountID: account.id)

        XCTAssertEqual(usageSnapshots.count, 1)
        XCTAssertEqual(usageSnapshots.first?.providerID, .openAI)
        XCTAssertEqual(usageSnapshots.first?.quality, .exact)

        XCTAssertEqual(costSnapshots.count, 1)
        XCTAssertEqual(costSnapshots.first?.providerID, .openAI)
        XCTAssertEqual(costSnapshots.first?.quality, .exact)
        XCTAssertEqual(costSnapshots.first?.amountMicros, 1_250)

        XCTAssertEqual(estimateSnapshots.count, 1)
        XCTAssertEqual(estimateSnapshots.first?.providerID, .openAI)
        XCTAssertEqual(estimateSnapshots.first?.quality, .estimated)

        XCTAssertEqual(syncRuns.count, 1)
        XCTAssertEqual(syncRuns.first?.providerID, .openAI)
        XCTAssertEqual(syncRuns.first?.status, .succeeded)
        XCTAssertNotNil(syncRuns.first?.finishedAt)
        XCTAssertNil(syncRuns.first?.message)
    }

    func testSyncThrowsMissingCredentialError() async throws {
        let ledger = try makeLedgerStore()
        let credentials = InMemoryCredentialStore()
        let account = makeAccount()

        try ledger.saveAccount(account)

        let scheduler = SyncScheduler(ledger: ledger, credentials: credentials)

        do {
            try await scheduler.sync(account: account, adapter: FixtureProviderAdapter(providerID: .openAI))
            XCTFail("Expected missing credential error")
        } catch let error as SyncSchedulerError {
            XCTAssertEqual(error, .missingCredential(accountID: account.id))
        }
    }

    private func makeLedgerStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func makeAccount(
        providerID: ProviderID = .openAI,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> Account {
        Account(
            id: UUID(),
            providerID: providerID,
            displayName: "Fixture",
            credentialReference: "keychain://glyphline/\(UUID().uuidString)",
            createdAt: createdAt,
            isEnabled: true
        )
    }
}

private struct CostSnapshotProviderAdapter: ProviderAdapter {
    let providerID: ProviderID

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        _ = secret

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(86_400)

        return ProviderSyncResult(
            providerID: providerID,
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
                endsAt: nil,
                resetAt: end.addingTimeInterval(30 * 86_400)
            ),
            usageSnapshots: [
                UsageSnapshot(
                    id: UUID(),
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    model: "fixture-model",
                    inputTokens: 1_000,
                    outputTokens: 500,
                    requests: 12,
                    quality: .exact
                )
            ],
            costSnapshots: [
                CostSnapshot(
                    id: UUID(),
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    amountMicros: 1_250,
                    currency: "USD",
                    quality: .exact
                )
            ],
            estimateSnapshots: [
                EstimateSnapshot(
                    id: UUID(),
                    accountID: account.id,
                    providerID: providerID,
                    bucketStart: start,
                    bucketEnd: end,
                    estimatedAmountMicros: 2_500,
                    currency: "USD",
                    quality: .estimated
                )
            ],
            syncedAt: start.addingTimeInterval(12)
        )
    }
}
