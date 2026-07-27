import XCTest
@testable import Glyphline

final class LedgerStoreTests: XCTestCase {
    func testUsageSnapshotsAreIdempotentByBucketAndModel() throws {
        let store = try makeStore()
        let account = makeAccount()
        try store.saveAccount(account)

        let bucketStart = Date(timeIntervalSince1970: 1_800_000_000)
        let bucketEnd = bucketStart.addingTimeInterval(86_400)
        let original = UsageSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .openAI,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            model: "gpt-5.4",
            inputTokens: 10,
            outputTokens: 20,
            requests: 1,
            quality: .exact
        )
        let replacement = UsageSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .openAI,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            model: "gpt-5.4",
            inputTokens: 30,
            outputTokens: 40,
            requests: 2,
            quality: .exact
        )
        let nilModel = UsageSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .openAI,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            model: nil,
            inputTokens: 7,
            outputTokens: 8,
            requests: 1,
            quality: .estimated
        )
        let nilModelReplacement = UsageSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .openAI,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            model: nil,
            inputTokens: 70,
            outputTokens: 80,
            requests: 3,
            quality: .exact
        )

        try store.upsertUsageSnapshots([original, nilModel])
        try store.upsertUsageSnapshots([replacement, nilModelReplacement])

        let rows = try store.fetchUsageSnapshots(accountID: account.id)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, nil)
        XCTAssertEqual(rows[0].inputTokens, 70)
        XCTAssertEqual(rows[0].outputTokens, 80)
        XCTAssertEqual(rows[0].requests, 3)
        XCTAssertEqual(rows[0].quality, .exact)
        XCTAssertEqual(rows[1].model, "gpt-5.4")
        XCTAssertEqual(rows[1].inputTokens, 30)
        XCTAssertEqual(rows[1].outputTokens, 40)
        XCTAssertEqual(rows[1].requests, 2)
        XCTAssertEqual(rows[1].quality, .exact)
    }

    func testSaveAccountRoundTripsStoredMetadata() throws {
        let store = try makeStore()
        let account = makeAccount()

        try store.saveAccount(account)

        XCTAssertEqual(try store.fetchAccounts(), [account])
    }

    func testEstimateSnapshotsRoundTripForAccount() throws {
        let store = try makeStore()
        let account = makeAccount(providerID: .claude)
        try store.saveAccount(account)

        let first = EstimateSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .claude,
            bucketStart: Date(timeIntervalSince1970: 1_800_100_000),
            bucketEnd: Date(timeIntervalSince1970: 1_800_186_400),
            estimatedAmountMicros: 125_000,
            currency: "USD",
            quality: .estimated
        )
        let second = EstimateSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .claude,
            bucketStart: Date(timeIntervalSince1970: 1_800_186_400),
            bucketEnd: Date(timeIntervalSince1970: 1_800_272_800),
            estimatedAmountMicros: 220_000,
            currency: "USD",
            quality: .exact
        )

        try store.upsertEstimateSnapshots([second, first])

        XCTAssertEqual(try store.fetchEstimateSnapshots(accountID: account.id), [first, second])
    }

    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func makeAccount(providerID: ProviderID = .openAI) -> Account {
        Account(
            id: UUID(),
            providerID: providerID,
            displayName: "Personal",
            credentialReference: "keychain://glyphline/\(UUID().uuidString)",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
    }
}
