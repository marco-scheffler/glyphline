import XCTest
import GRDB
@testable import Glyphline

final class SyncSchedulerTests: XCTestCase {
    func testSyncStoresFixtureUsageAndEstimateSnapshots() async throws {
        let ledger = try makeLedgerStore()
        let credentials = InMemoryCredentialStore()
        let account = makeAccount()

        try ledger.saveAccount(account)
        try credentials.save(secret: "fixture-secret", for: account.credentialReference)

        let scheduler = SyncScheduler(ledger: ledger, credentials: credentials)
        let adapter = FixtureProviderAdapter(providerID: .openAI)

        try await scheduler.sync(account: account, adapter: adapter)

        let usageSnapshots = try ledger.fetchUsageSnapshots(accountID: account.id)
        let estimateSnapshots = try ledger.fetchEstimateSnapshots(accountID: account.id)

        XCTAssertEqual(usageSnapshots.count, 1)
        XCTAssertEqual(usageSnapshots.first?.providerID, .openAI)
        XCTAssertEqual(usageSnapshots.first?.quality, .exact)
        XCTAssertEqual(estimateSnapshots.count, 1)
        XCTAssertEqual(estimateSnapshots.first?.providerID, .openAI)
        XCTAssertEqual(estimateSnapshots.first?.quality, .estimated)
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

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Fixture",
            credentialReference: "fixture",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
    }
}
