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

    func testCostSnapshotsAreIdempotentByBucketAndCurrency() throws {
        let store = try makeStore()
        let account = makeAccount()
        try store.saveAccount(account)

        let bucketStart = Date(timeIntervalSince1970: 1_800_000_000)
        let bucketEnd = bucketStart.addingTimeInterval(86_400)
        let original = CostSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .openAI,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            amountMicros: 120_000,
            currency: "USD",
            quality: .estimated
        )
        let replacement = CostSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .openAI,
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            amountMicros: 180_000,
            currency: "USD",
            quality: .exact
        )

        try store.upsertCostSnapshots([original])
        try store.upsertCostSnapshots([replacement])

        let rows = try store.fetchCostSnapshots(accountID: account.id)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amountMicros, 180_000)
        XCTAssertEqual(rows[0].currency, "USD")
        XCTAssertEqual(rows[0].quality, .exact)
    }

    func testAccountsRoundTripInCreatedAtOrder() throws {
        let store = try makeStore()
        let first = makeAccount(
            providerID: .cursor,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = makeAccount(
            providerID: .claude,
            createdAt: Date(timeIntervalSince1970: 1_800_086_400)
        )

        try store.saveAccount(second)
        try store.saveAccount(first)

        XCTAssertEqual(try store.fetchAccounts(), [first, second])
    }

    /// The quota reference sits in the seventh position of four separate parts of
    /// `saveAccount`'s SQL — insert list, `VALUES` placeholders, `DO UPDATE SET` and
    /// `arguments`. A mismatch in any one of them would silently write the wrong
    /// column, so the round trip is pinned with a non-nil value rather than NULL.
    func testAQuotaCredentialReferenceSurvivesTheRoundTrip() throws {
        let store = try makeStore()
        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: "local-source://claude-code",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true,
            quotaCredentialReference: "keychain://glyphline/quota-token"
        )

        try store.saveAccount(account)

        let fetched = try XCTUnwrap(try store.fetchAccounts().first)
        XCTAssertEqual(fetched.quotaCredentialReference, "keychain://glyphline/quota-token")
        XCTAssertEqual(fetched.credentialReference, "local-source://claude-code")
        XCTAssertEqual(fetched, account)
    }

    /// The upsert path has its own `DO UPDATE SET` line for the column; re-saving
    /// must carry a changed reference through rather than leaving the first one.
    func testResavingAnAccountUpdatesTheQuotaCredentialReference() throws {
        let store = try makeStore()
        var account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: "local-source://claude-code",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true,
            quotaCredentialReference: nil
        )
        try store.saveAccount(account)

        account.quotaCredentialReference = "keychain://glyphline/quota-token"
        try store.saveAccount(account)

        let fetched = try XCTUnwrap(try store.fetchAccounts().first)
        XCTAssertEqual(fetched.quotaCredentialReference, "keychain://glyphline/quota-token")
        XCTAssertEqual(try store.fetchAccounts().count, 1)
    }

    func testEstimateSnapshotsFetchInBucketOrder() throws {
        let store = try makeStore()
        let account = makeAccount()
        try store.saveAccount(account)

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
        let first = EstimateSnapshot(
            id: UUID(),
            accountID: account.id,
            providerID: .claude,
            bucketStart: Date(timeIntervalSince1970: 1_800_000_000),
            bucketEnd: Date(timeIntervalSince1970: 1_800_086_400),
            estimatedAmountMicros: 110_000,
            currency: "USD",
            quality: .estimated
        )

        try store.upsertEstimateSnapshots([second, first])

        XCTAssertEqual(try store.fetchEstimateSnapshots(accountID: account.id), [first, second])
    }

    private func makeStore() throws -> LedgerStore {
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
            displayName: "Personal",
            credentialReference: "keychain://glyphline/\(UUID().uuidString)",
            createdAt: createdAt,
            isEnabled: true
        )
    }
}
