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

        // The accounts list renders this string verbatim, so it is pinned here.
        // It must not claim the sync never ran or that data was discarded: the
        // coordinator also reports .failed when cost estimation fails after
        // snapshots were already persisted.
        XCTAssertEqual(coordinator.activities[account.id], .failed("Credential missing in Keychain."))
    }

    func testProviderMismatchSurfacesItsOwnMessage() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Mismatched",
            credentialReference: "keychain://glyphline/mismatch",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "secret", for: account.credentialReference)

        let coordinator = try makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            adapter: FixtureProviderAdapter(providerID: .cursor)
        )
        await coordinator.syncNow(account: account)

        XCTAssertEqual(
            coordinator.activities[account.id],
            .failed("Account and adapter provider disagree.")
        )
    }

    func testUnrecognisedFailuresUseTheGenericMessage() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Adapter throws",
            credentialReference: "keychain://glyphline/throwing",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "secret", for: account.credentialReference)

        let coordinator = try makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            adapter: FailingProviderAdapter()
        )
        await coordinator.syncNow(account: account)

        // The raw error never reaches the UI: adapter errors can carry request detail.
        XCTAssertEqual(coordinator.activities[account.id], .failed("Sync failed."))
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

    // MARK: - Degraded path: no durable ledger

    func testSyncAllWithoutALedgerReportsRatherThanSilentlyDoingNothing() async {
        let coordinator = SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: []))
        )

        await coordinator.syncAll()

        XCTAssertEqual(coordinator.syncFailureMessage, "Ledger unavailable. Nothing was synced.")
    }

    func testSyncNowWithoutALedgerFailsTheAccountInsteadOfAppearingToSucceed() async {
        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "No ledger",
            credentialReference: "keychain://glyphline/no-ledger",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )

        let coordinator = SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: []))
        )

        await coordinator.syncNow(account: account)

        // Must not land on .idle, which the accounts list renders as "no problem".
        XCTAssertEqual(
            coordinator.activities[account.id],
            .failed("Ledger unavailable. Nothing was synced.")
        )
        XCTAssertEqual(coordinator.syncFailureMessage, "Ledger unavailable. Nothing was synced.")
    }

    func testTheLedgerUnavailableMessageCarriesNoCredentialDetail() {
        let message = SyncCoordinator.ledgerUnavailableMessage

        XCTAssertFalse(message.localizedCaseInsensitiveContains("keychain://"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("token"))
    }

    func testASuccessfulSyncAllClearsAStaleFailureMessage() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let coordinator = SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: []))
        )
        await coordinator.syncAll()
        XCTAssertNotNil(coordinator.syncFailureMessage)

        // A coordinator that does have a ledger must never carry the message.
        let healthy = try makeCoordinator(ledger: ledger, credentials: InMemoryCredentialStore())
        await healthy.syncAll()

        XCTAssertNil(healthy.syncFailureMessage)
    }
    func testSchedulerRepeatsUntilStopped() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        let account = Account(
            id: UUID(), providerID: .openAI, displayName: "Fixture",
            credentialReference: "keychain://glyphline/fixture",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), isEnabled: true
        )
        try ledger.saveAccount(account)
        try credentials.save(secret: "secret", for: account.credentialReference)

        let sleeps = Counter()
        // Fulfilled from inside the injected sleep, so the test waits on the loop
        // actually turning over rather than on wall-clock time passing.
        let looped = expectation(description: "scheduler sleeps more than once")
        looped.expectedFulfillmentCount = 2
        looped.assertForOverFulfill = false

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            adapterProvider: { _ in FixtureProviderAdapter(providerID: .openAI) },
            sleepForSeconds: { _ in
                await sleeps.increment()
                looped.fulfill()
            }
        )
        coordinator.startScheduler(intervalSeconds: 1)
        XCTAssertTrue(coordinator.isSchedulerRunning)

        await fulfillment(of: [looped], timeout: 10)
        coordinator.stopScheduler()

        XCTAssertFalse(coordinator.isSchedulerRunning)
        let count = await sleeps.value
        XCTAssertGreaterThan(count, 1, "the scheduler should have looped more than once")
    }

    func testStartingTwiceDoesNotRunTwoLoops() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let coordinator = SyncCoordinator(
            ledger: LedgerStore(dbQueue: dbQueue),
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            sleepForSeconds: { _ in try await Task.sleep(for: .milliseconds(10)) }
        )

        coordinator.startScheduler(intervalSeconds: 60)
        coordinator.startScheduler(intervalSeconds: 60)
        XCTAssertTrue(coordinator.isSchedulerRunning)

        coordinator.stopScheduler()
        XCTAssertFalse(coordinator.isSchedulerRunning)
    }

    func testReapplyingTheSameScheduleDoesNotResetThePhase() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)

        let intervals = IntervalRecorder()
        // Each loop start produces exactly one sleep call, because the injected
        // sleep never returns until the task is cancelled. The recorded intervals
        // are therefore the restart history of the scheduler.
        let firstStart = expectation(description: "scheduler started once")
        let secondStart = expectation(description: "scheduler restarted")
        secondStart.expectedFulfillmentCount = 2
        firstStart.assertForOverFulfill = false
        secondStart.assertForOverFulfill = false

        let coordinator = SyncCoordinator(
            ledger: LedgerStore(dbQueue: dbQueue),
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            sleepForSeconds: { seconds in
                await intervals.record(seconds)
                firstStart.fulfill()
                secondStart.fulfill()
                try await Task.sleep(for: .seconds(3_600))
            }
        )

        coordinator.applySchedule(enabled: true, intervalSeconds: 900)
        await fulfillment(of: [firstStart], timeout: 10)
        XCTAssertTrue(coordinator.isSchedulerRunning)
        XCTAssertEqual(coordinator.currentIntervalSeconds, 900)

        // Stands in for onAppear firing again when the dashboard scene is recreated.
        coordinator.applySchedule(enabled: true, intervalSeconds: 900)
        coordinator.applySchedule(enabled: true, intervalSeconds: 900)
        XCTAssertTrue(coordinator.isSchedulerRunning)
        XCTAssertEqual(
            coordinator.schedulerStartCount, 1,
            "re-applying an unchanged schedule must not restart the loop and push the next sync out"
        )

        // A genuine interval change must still restart the loop.
        coordinator.applySchedule(enabled: true, intervalSeconds: 1_800)
        await fulfillment(of: [secondStart], timeout: 10)
        XCTAssertEqual(coordinator.currentIntervalSeconds, 1_800)
        XCTAssertEqual(coordinator.schedulerStartCount, 2)

        // Had the unchanged re-applications restarted the loop, this would read
        // [900, 900] at this point instead of the new interval.
        let recorded = await intervals.values
        XCTAssertEqual(recorded, [900, 1_800])

        coordinator.applySchedule(enabled: false, intervalSeconds: 1_800)
        XCTAssertFalse(coordinator.isSchedulerRunning)
        XCTAssertNil(coordinator.currentIntervalSeconds)
    }

    /// Non-async so GRDB's synchronous `read` overload is the one selected;
    /// the tests below call it from an async context.
    private nonisolated static func rateWindowSampleCount(_ dbQueue: DatabaseQueue) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rateWindowSamples") ?? 0
        }
    }

    func testCollectingRateWindowsStoresThemAndAppliesRetention() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        // A sample far older than the retention window must not survive the tick.
        try ledger.saveRateWindow(
            RateWindow(kind: .weekly, usedFraction: 0.5,
                       resetAt: now.addingTimeInterval(-360 * 86_400),
                       observedAt: now.addingTimeInterval(-400 * 86_400)),
            accountID: account.id
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            now: { now },
            rateWindowSourceProvider: { _ in FixtureRateWindowSource(now: { now }) }
        )

        await coordinator.collectRateWindows()

        let stored = try ledger.fetchLatestRateWindows(accountID: account.id)
        XCTAssertEqual(Set(stored.map(\.kind)), [.rollingFiveHours, .weekly])

        let total = try Self.rateWindowSampleCount(dbQueue)
        XCTAssertEqual(total, 2, "the 400-day-old sample should have been deleted by retention")
    }

    /// Pins the actual guarantee: a failed quota fetch contributes no quota row.
    ///
    /// The account deliberately *does* have a billing period the cost sync already
    /// established, so the billing-cycle derivation fires. That row is real
    /// information from the cost path, not recorded ignorance, and it is the only
    /// row allowed to exist here. Asserting a bare `COUNT(*) == 0` would pass only
    /// by accident of the account having no billing period at all, and would say
    /// nothing about whether the failing fetch wrote a quota row.
    func testAFailingRateWindowFetchWritesNoQuotaRowAndRecordsAReason() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .openAI, displayName: "Max #1",
            credentialReference: "keychain://glyphline/x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "sk-test", for: "keychain://glyphline/x")

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            adapterProvider: { _ in FixtureProviderAdapter(providerID: .openAI) },
            now: { now },
            rateWindowSourceProvider: { _ in
                FixtureRateWindowSource(now: { now }, behaviour: .unavailable)
            }
        )

        // Establishes a billing period on the cost path, so the derivation branch fires.
        await coordinator.syncAll()
        let summary = try XCTUnwrap(try ledger.fetchAccountSummaries().first)
        XCTAssertNotNil(summary.billingPeriod?.resetAt, "precondition: the cost sync stored a reset")

        await coordinator.collectRateWindows()

        let total = try Self.rateWindowSampleCount(dbQueue)
        XCTAssertEqual(
            total, 1,
            "only the cost-derived billing cycle may exist; the failed fetch adds nothing"
        )

        let stored = try ledger.fetchLatestRateWindows(accountID: account.id)
        XCTAssertEqual(stored.map(\.kind), [.billingCycle])
        XCTAssertFalse(stored.contains { $0.kind == .rollingFiveHours })
        XCTAssertFalse(stored.contains { $0.kind == .weekly })
        XCTAssertNotNil(coordinator.rateWindowMessages[account.id])
    }

    func testAFailingRateWindowFetchLeavesTheCostSyncGreen() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .openAI, displayName: "OpenAI",
            credentialReference: "keychain://glyphline/x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        let credentials = InMemoryCredentialStore()
        try credentials.save(secret: "sk-test", for: "keychain://glyphline/x")

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            adapterProvider: { _ in FixtureProviderAdapter(providerID: .openAI) },
            now: { now },
            rateWindowSourceProvider: { _ in
                FixtureRateWindowSource(now: { now }, behaviour: .unavailable)
            }
        )

        await coordinator.syncAll()
        await coordinator.collectRateWindows()

        // The quota side must actually have failed, or the independence claim is
        // unexercised: a source that silently succeeded would leave this green.
        XCTAssertNotNil(coordinator.rateWindowMessages[account.id])

        // The quota side failed; the cost side must be untouched by that.
        XCTAssertNil(coordinator.syncFailureMessage)
        XCTAssertFalse(try ledger.fetchUsageSnapshots(accountID: account.id).isEmpty)
    }

    /// Every real account takes this path — the registry resolves no source for
    /// any of them — so this string is what every user reads. It must not imply
    /// there is a setup step available: the spike found none.
    func testAnAccountWithNoSourceIsToldQuotaIsUnavailableNotUnconfigured() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            now: { now }
        )

        await coordinator.collectRateWindows()

        XCTAssertEqual(
            coordinator.rateWindowMessages[account.id],
            RateWindowSourceError.notAvailable.message
        )
        XCTAssertNotEqual(
            coordinator.rateWindowMessages[account.id],
            RateWindowSourceError.notConfigured.message
        )
    }

    /// The menu-bar symbol and the "Next free" line must never disagree about
    /// which observations are still believable.
    ///
    /// The poll interval is deliberately *not* the 1800s default, so the derived
    /// freshness bound (2x the interval = 600s) sits on the other side of this
    /// 20-minute-old observation from the 3600s a call site might otherwise
    /// hardcode. With the bound hardcoded in the view this observation was fresh
    /// enough to print "Max #1 — now" beside a grey icon that had already
    /// discarded it.
    func testTheLightAndTheNextFreeStringShareOneFreshnessBound() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        // Headroom, so a believed observation would yield green and "— now".
        try ledger.saveRateWindow(
            RateWindow(kind: .rollingFiveHours, usedFraction: 0.3,
                       resetAt: now.addingTimeInterval(1_800),
                       observedAt: now.addingTimeInterval(-1_200)),
            accountID: account.id
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            sleepForSeconds: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { now },
            rateWindowSourceProvider: { _ in nil }
        )

        coordinator.startScheduler(intervalSeconds: 300)
        defer { coordinator.stopScheduler() }

        await coordinator.collectRateWindows()

        XCTAssertEqual(coordinator.quotaLight, .grey, "600s bound: a 20-minute-old observation is stale")
        XCTAssertNil(
            coordinator.nextFreeText,
            "the next-free string must not believe an observation the light has discarded"
        )
    }
}

/// Records the interval each scheduler start slept on, across concurrency domains.
actor IntervalRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        values.append(seconds)
    }
}

/// Small actor so the injected sleep can be counted across concurrency domains.
actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// Throws an error carrying detail that must never reach the UI.
private struct FailingProviderAdapter: ProviderAdapter {
    struct Failure: Error {
        let detail = "Authorization: Bearer super-secret"
    }

    let providerID: ProviderID = .openAI
    var requiresSecret: Bool { true }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        throw Failure()
    }
}
