import GRDB
import XCTest
@testable import Glyphline

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        ledger: LedgerStore,
        credentials: InMemoryCredentialStore,
        adapter: any ProviderAdapter = FixtureProviderAdapter(providerID: .openAI)
    ) throws -> SyncCoordinator {
        SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(
                catalog: PricingCatalog(entries: [
                    PricingEntry(
                        providerID: .openAI,
                        model: "fixture-model",
                        inputMicrosPerMillionTokens: 1_000_000,
                        outputMicrosPerMillionTokens: 2_000_000,
                        cacheCreationMicrosPerMillionTokens: nil,
                        cacheReadMicrosPerMillionTokens: nil,
                        currency: "USD",
                        effectiveDate: "2026-07-27",
                        source: "test"
                    ),
                ])
            ),
            adapterProvider: { _ in adapter }
        )
    }

    func testSyncNowStoresSnapshotsAndReturnsToIdle() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Fixture",
            credentialReference: "keychain://glyphline/fixture",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)
        try credentials.save(secret: "secret", for: account.credentialReference)

        let coordinator = try makeCoordinator(ledger: ledger, credentials: credentials)
        await coordinator.syncNow(account: account)

        XCTAssertEqual(coordinator.activities[account.id], .idle)
        XCTAssertFalse(try ledger.fetchUsageSnapshots(accountID: account.id).isEmpty)
    }

    func testMissingCredentialSurfacesAsFailedActivity() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "No secret",
            credentialReference: "keychain://glyphline/missing",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let coordinator = try makeCoordinator(ledger: ledger, credentials: InMemoryCredentialStore())
        await coordinator.syncNow(account: account)

        guard case .failed = coordinator.activities[account.id] else {
            return XCTFail("expected a failed activity, got \(String(describing: coordinator.activities[account.id]))")
        }
    }

    func testSyncAllSkipsDisabledAccounts() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        let enabled = Account(
            id: UUID(), providerID: .openAI, displayName: "On",
            credentialReference: "keychain://glyphline/on",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), isEnabled: true
        )
        let disabled = Account(
            id: UUID(), providerID: .openAI, displayName: "Off",
            credentialReference: "keychain://glyphline/off",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), isEnabled: false
        )
        try ledger.saveAccount(enabled)
        try ledger.saveAccount(disabled)
        try credentials.save(secret: "secret", for: enabled.credentialReference)
        try credentials.save(secret: "secret", for: disabled.credentialReference)

        let coordinator = try makeCoordinator(ledger: ledger, credentials: credentials)
        await coordinator.syncAll()

        XCTAssertNotNil(coordinator.activities[enabled.id])
        XCTAssertNil(coordinator.activities[disabled.id])
    }
}
