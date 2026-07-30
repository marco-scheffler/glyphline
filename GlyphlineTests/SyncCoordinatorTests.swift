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

    /// The default interval is half an hour. Sleeping first meant the app showed
    /// nothing but stale quota for thirty minutes after every launch.
    func testSchedulerCollectsRateWindowsBeforeTheFirstSleepCompletes() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        let collected = expectation(description: "rate windows collected")
        collected.assertForOverFulfill = false

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            // A sleep that never returns: anything the test observes must
            // therefore have happened before the first interval elapsed.
            sleepForSeconds: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { now },
            rateWindowSourceProvider: { _ in
                SignallingRateWindowSource(
                    window: RateWindow(kind: .rollingFiveHours, usedFraction: 0.25,
                                       resetAt: now.addingTimeInterval(1_800), observedAt: now),
                    onFetch: { collected.fulfill() }
                )
            }
        )

        coordinator.startScheduler(intervalSeconds: 1_800)
        defer { coordinator.stopScheduler() }

        // The fetch is signalled from inside the source, so reaching this line at
        // all means the collection ran while the first sleep was still pending.
        // What the tick then writes is covered by the collection tests below.
        await fulfillment(of: [collected], timeout: 10)
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

    /// The production path, end to end. No account resolves to a quota source, so
    /// every real account carries a message — and the menu rendered the message
    /// *or* the windows, never both, which made the cost-derived billing cycle
    /// invisible. It is the only genuine quota datum a real user gets today.
    func testTheBillingCycleIsRenderedBesideTheNoSourceMessage() async throws {
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

        // The real registry, not an injected source: this is exactly what ships.
        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            adapterProvider: { _ in FixtureProviderAdapter(providerID: .openAI) },
            now: { now }
        )

        await coordinator.syncAll()
        let summary = try XCTUnwrap(try ledger.fetchAccountSummaries().first)
        XCTAssertNotNil(summary.billingPeriod?.resetAt, "precondition: the cost sync stored a reset")

        await coordinator.collectRateWindows()

        let group = try XCTUnwrap(coordinator.quotaRows.first)
        XCTAssertEqual(group.message, RateWindowSourceError.notAvailable.message)
        XCTAssertEqual(group.rows.count, 1, "the derived billing cycle must reach the menu")
        XCTAssertTrue(
            try XCTUnwrap(group.rows.first).hasPrefix("Cycle"),
            "got \(group.rows)"
        )
    }

    /// The end-to-end shape of the change-detection defect.
    ///
    /// The provider keeps reporting the same figure at the same reset instant.
    /// The store drops the repeat — correctly, the value has not changed — so
    /// the stored `observedAt` stays put. With freshness measured from that
    /// column, a successful fetch seconds ago produced a grey icon and no "Next
    /// free" line, which inverts what the feature is for.
    func testAStableReadingStaysFreshWhileTheProviderKeepsConfirmingIt() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true
        )
        try ledger.saveAccount(account)

        let resetAt = now.addingTimeInterval(1_800)
        let firstSeen = now.addingTimeInterval(-1_200)

        // Twenty minutes ago the value was first seen. The 300s poll interval
        // puts the freshness bound at 600s, so `observedAt` alone is stale.
        try ledger.saveRateWindow(
            RateWindow(kind: .rollingFiveHours, usedFraction: 0.3,
                       resetAt: resetAt, observedAt: firstSeen),
            accountID: account.id
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            sleepForSeconds: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { now },
            rateWindowSourceProvider: { _ in
                // The same value, observed now: a confirmation, not a change.
                StableRateWindowSource(
                    window: RateWindow(kind: .rollingFiveHours, usedFraction: 0.3,
                                       resetAt: resetAt, observedAt: now)
                )
            }
        )

        coordinator.startScheduler(intervalSeconds: 300)
        defer { coordinator.stopScheduler() }

        await coordinator.collectRateWindows()

        // The append-only table must not have grown: this is the write rule
        // working, not a bug being papered over.
        XCTAssertEqual(
            try Self.rateWindowSampleCount(dbQueue), 1,
            "an unchanged observation must still be dropped"
        )
        let stored = try XCTUnwrap(try ledger.fetchLatestRateWindows(accountID: account.id).first)
        XCTAssertEqual(
            stored.observedAt.timeIntervalSince1970, firstSeen.timeIntervalSince1970, accuracy: 0.001,
            "observedAt keeps meaning 'when this value was first seen'"
        )

        // And the display believes the fetch that just happened.
        XCTAssertEqual(coordinator.quotaLight, .green)
        XCTAssertEqual(coordinator.nextFreeText, "Max #1 — now")
    }

    /// The billing cycle comes from the cost path and the short windows from the
    /// quota source; they succeed and fail independently. A single per-account
    /// timestamp would let a derived billing cycle vouch for a rate window that
    /// nobody managed to fetch.
    func testAFreshBillingCycleDoesNotVouchForAStaleRateWindow() async throws {
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

        // Headroom, but observed well beyond the 600s bound and never confirmed.
        try ledger.saveRateWindow(
            RateWindow(kind: .rollingFiveHours, usedFraction: 0.3,
                       resetAt: now.addingTimeInterval(1_800),
                       observedAt: now.addingTimeInterval(-1_200)),
            accountID: account.id
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            adapterProvider: { _ in FixtureProviderAdapter(providerID: .openAI) },
            sleepForSeconds: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { now },
            rateWindowSourceProvider: { _ in nil }
        )

        coordinator.startScheduler(intervalSeconds: 300)
        defer { coordinator.stopScheduler() }

        // Establishes a billing period, so the cost-derived cycle is written and
        // confirmed on this very tick.
        await coordinator.syncAll()
        await coordinator.collectRateWindows()

        let kinds = try ledger.fetchLatestRateWindows(accountID: account.id).map(\.kind)
        XCTAssertTrue(kinds.contains(.billingCycle), "precondition: the cycle was derived now")
        XCTAssertTrue(kinds.contains(.rollingFiveHours), "precondition: the stale window is still stored")

        XCTAssertEqual(
            coordinator.quotaLight, .grey,
            "a freshly derived billing cycle says nothing about a rate window nobody fetched"
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

    // MARK: - Notify once, on the transition

    private func makeExpiringCoordinator(
        source: any RateWindowSource,
        notifier: RecordingQuotaNotifier
    ) throws -> SyncCoordinator {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true,
            claudeOrganizationID: "org-1"
        )
        try ledger.saveAccount(account)

        return SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(watermarkStore: ledger),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            now: { now },
            rateWindowSourceProvider: { _ in source },
            quotaNotifier: notifier
        )
    }

    func testTheFirstFailureNotifiesAndTheNextOnesDoNot() async throws {
        let notifier = RecordingQuotaNotifier()
        let coordinator = try makeExpiringCoordinator(
            source: SwitchableQuotaSource(behaviour: .expired),
            notifier: notifier
        )

        await coordinator.collectRateWindows()
        await coordinator.collectRateWindows()
        await coordinator.collectRateWindows()

        // Three subscriptions on a half-hourly schedule would otherwise produce
        // 144 notifications a day.
        XCTAssertEqual(notifier.sentCount, 1)
        XCTAssertEqual(notifier.sentNames, ["Max #1"])
    }

    func testASuccessfulFetchRearmsTheNotification() async throws {
        let notifier = RecordingQuotaNotifier()
        let source = SwitchableQuotaSource(behaviour: .expired)
        let coordinator = try makeExpiringCoordinator(source: source, notifier: notifier)

        await coordinator.collectRateWindows()
        XCTAssertEqual(notifier.sentCount, 1)

        source.behaviour = .healthy
        await coordinator.collectRateWindows()
        XCTAssertEqual(notifier.sentCount, 1, "recovery does not notify")

        source.behaviour = .expired
        await coordinator.collectRateWindows()
        XCTAssertEqual(notifier.sentCount, 2, "a fresh failure after a recovery is news again")
    }

    /// A transport blip is not an expired session. Notifying on it would train the
    /// user to ignore the one notification that asks them to do something.
    func testAnOrdinaryFetchFailureDoesNotNotify() async throws {
        let notifier = RecordingQuotaNotifier()
        let coordinator = try makeExpiringCoordinator(
            source: SwitchableQuotaSource(behaviour: .transportFailure),
            notifier: notifier
        )

        await coordinator.collectRateWindows()

        XCTAssertEqual(notifier.sentCount, 0)
    }

    /// Nothing from a session, a cookie or a URL may reach a notification.
    func testTheNotificationCarriesOnlyTheAccountNameAndTheAppsOwnMessage() async throws {
        let notifier = RecordingQuotaNotifier()
        let coordinator = try makeExpiringCoordinator(
            source: SwitchableQuotaSource(behaviour: .expired),
            notifier: notifier
        )

        await coordinator.collectRateWindows()

        XCTAssertEqual(notifier.sentNames, ["Max #1"])
    }

    // MARK: - Forgetting a deleted account

    func testForgettingAnAccountClearsItsStateAndLeavesOthersAlone() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        func makeAccount(_ name: String) throws -> Account {
            let account = Account(
                id: UUID(),
                providerID: .openAI,
                displayName: name,
                credentialReference: "keychain://glyphline/\(name)",
                createdAt: now,
                isEnabled: true
            )
            try ledger.saveAccount(account)
            try credentials.save(secret: "secret", for: account.credentialReference)
            return account
        }

        let doomed = try makeAccount("Doomed")
        let survivor = try makeAccount("Survivor")

        let coordinator = try makeCoordinator(ledger: ledger, credentials: credentials)
        await coordinator.syncAll()
        await coordinator.collectRateWindows()

        // Guards the assertions below. Without these, a coordinator that never
        // recorded any state would pass the whole test vacuously.
        XCTAssertNotNil(coordinator.activities[doomed.id])
        XCTAssertNotNil(coordinator.rateWindowMessages[doomed.id])
        XCTAssertTrue(coordinator.quotaStates.contains { $0.accountID == doomed.id })
        XCTAssertNotNil(coordinator.activities[survivor.id])

        coordinator.forgetAccount(id: doomed.id)

        XCTAssertNil(coordinator.activities[doomed.id])
        XCTAssertNil(coordinator.rateWindowMessages[doomed.id])
        XCTAssertFalse(coordinator.quotaStates.contains { $0.accountID == doomed.id })

        XCTAssertNotNil(coordinator.activities[survivor.id])
        XCTAssertNotNil(coordinator.rateWindowMessages[survivor.id])
        XCTAssertTrue(coordinator.quotaStates.contains { $0.accountID == survivor.id })
    }

    /// The notify-once flag is private, so it is covered through behaviour: an
    /// account whose expiry has already been announced is forgotten, and the
    /// very next expired tick must announce again. If `forgetAccount` failed to
    /// clear the flag, the second announcement would never arrive.
    func testForgettingAnAccountRearmsItsExpiryNotification() async throws {
        let notifier = RecordingQuotaNotifier()
        let coordinator = try makeExpiringCoordinator(
            source: SwitchableQuotaSource(behaviour: .expired),
            notifier: notifier
        )

        await coordinator.collectRateWindows()
        XCTAssertEqual(notifier.sentCount, 1)

        await coordinator.collectRateWindows()
        XCTAssertEqual(notifier.sentCount, 1, "precondition: the flag suppresses the repeat")

        let accountID = try XCTUnwrap(coordinator.quotaStates.first?.accountID)
        coordinator.forgetAccount(id: accountID)

        await coordinator.collectRateWindows()
        XCTAssertEqual(
            notifier.sentCount, 2,
            "forgetting the account must clear the notify-once flag"
        )
    }

    /// `rateWindowConfirmations` is private, but its value surfaces on the
    /// published `quotaStates` as `QuotaWindowState.confirmedAt`, so the clearing
    /// can be pinned through public API without widening any access level.
    ///
    /// The second tick fails deliberately. The ledger still holds the window from
    /// the healthy tick, so the account keeps its row and its window — only the
    /// confirmation is gone. A `forgetAccount` that left the stale confirmation
    /// behind would still vouch for it, making an old reading look freshly checked.
    func testForgettingAnAccountDropsItsConfirmationDates() async throws {
        let source = SwitchableQuotaSource(behaviour: .healthy)
        let coordinator = try makeExpiringCoordinator(
            source: source,
            notifier: RecordingQuotaNotifier()
        )

        await coordinator.collectRateWindows()

        let confirmed = try XCTUnwrap(coordinator.quotaStates.first)
        XCTAssertNotNil(
            confirmed.windows.first?.confirmedAt,
            "precondition: the healthy tick must have recorded a confirmation"
        )

        coordinator.forgetAccount(id: confirmed.accountID)

        source.behaviour = .transportFailure
        await coordinator.collectRateWindows()

        let afterwards = try XCTUnwrap(coordinator.quotaStates.first)
        XCTAssertEqual(
            afterwards.windows.count, confirmed.windows.count,
            "precondition: the stored window survives, so confirmedAt is the only difference"
        )
        XCTAssertNil(afterwards.windows.first?.confirmedAt)
    }

    // MARK: - Deletion ordering

    /// The ordering the deletion depends on: the backfill is cancelled BEFORE the
    /// durable delete, never after.
    ///
    /// A slice that starts while the delete is in flight writes snapshots under an
    /// id the ledger is about to forget, and the schema has no foreign keys, so
    /// those rows survive invisibly. This lived in `AccountsView` and was the wrong
    /// way round there — delete first, cancel second — where no test could see it.
    ///
    /// Both events are recorded at the instant they happen: a cancellation handler
    /// runs synchronously inside `Task.cancel()`, and `removeSession` is the first
    /// thing `DeleteAccountFlow` does, ahead of every durable step.
    func testDeletingAnAccountCancelsItsBackfillBeforeTheDurableDelete() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let accountID = UUID()
        let account = Account(
            id: accountID,
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: AccountCredentialReference.make(
                accountID: accountID,
                source: .claudeWebSession
            ),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let log = DeletionOrderLog()
        let gate = ParkingAdapter.Gate()
        let coordinator = try makeCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            adapter: ParkingAdapter(gate: gate, log: log)
        )

        let running = Task { await coordinator.backfill(account: account) }

        // A slice has to be in flight before the delete starts. Cancelling a task
        // that has not begun would prove nothing about the order of the two steps.
        var spins = 0
        while !gate.isParked, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        guard gate.isParked else {
            running.cancel()
            gate.release()
            _ = await running.value
            return XCTFail("precondition: a backfill slice must be in flight")
        }

        let flow = DeleteAccountFlow(
            ledgerStore: ledger,
            credentialStore: InMemoryCredentialStore(),
            webSessions: OrderRecordingRemover(log: log)
        )
        let outcome = await coordinator.deleteAccount(account, using: flow)
        _ = await running.value

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(log.events, [.backfillCancelled, .sessionRemoved])
    }

    /// The other half of the guard in `deleteAccount`: `forgetAccount` runs only
    /// when the flow reports `.deleted`.
    ///
    /// A failed delete leaves the account in the ledger and on screen. Forgetting
    /// it anyway would blank the in-memory state of a row that is still there, so
    /// the surviving account would show no activity at all.
    func testAFailedDeletionKeepsTheAccountsState() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        let accountID = UUID()
        let account = Account(
            id: accountID,
            providerID: .claude,
            displayName: "Max #1",
            credentialReference: AccountCredentialReference.make(
                accountID: accountID,
                source: .claudeWebSession
            ),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)
        try credentials.save(secret: "secret", for: account.credentialReference)

        let coordinator = try makeCoordinator(ledger: ledger, credentials: credentials)
        await coordinator.syncNow(account: account)

        // Guards the assertion below. Without state to lose, a coordinator that
        // forgot the account unconditionally would still pass.
        XCTAssertNotNil(
            coordinator.activities[accountID],
            "precondition: the tick must have recorded an activity"
        )

        let flow = DeleteAccountFlow(
            ledgerStore: ledger,
            credentialStore: credentials,
            webSessions: FailingRemover()
        )
        let outcome = await coordinator.deleteAccount(account, using: flow)

        XCTAssertEqual(outcome, .failed(DeleteAccountFlow.webSessionCleanupFailedMessage))
        XCTAssertEqual(
            try ledger.fetchAccounts().map(\.id), [accountID],
            "precondition: the failed delete must leave the ledger row in place"
        )
        XCTAssertNotNil(
            coordinator.activities[accountID],
            "a failed delete must not forget the account"
        )
    }
}

/// A session remover that always fails, so `DeleteAccountFlow` returns `.failed`.
/// Nothing here may touch a real `WKWebsiteDataStore`.
private final class FailingRemover: WebSessionRemoving {
    struct Failure: Error {}

    func removeSession(for accountID: UUID) async throws {
        throw Failure()
    }
}

/// The two events whose order is the whole point of `deleteAccount`.
private final class DeletionOrderLog: @unchecked Sendable {
    enum Event {
        case backfillCancelled
        case sessionRemoved
    }

    private let lock = NSLock()
    private var storage: [Event] = []

    func record(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

extension DeletionOrderLog.Event: Equatable {}

/// A stand-in for WebKit, recording the first step of the delete. Nothing here
/// may touch a real `WKWebsiteDataStore`.
@MainActor
private final class OrderRecordingRemover: WebSessionRemoving {
    private let log: DeletionOrderLog

    init(log: DeletionOrderLog) {
        self.log = log
    }

    func removeSession(for accountID: UUID) async throws {
        log.record(.sessionRemoved)
    }
}

/// A backfill slice that parks until the run is cancelled, and records the
/// cancellation the moment it is delivered.
///
/// `withTaskCancellationHandler` runs its handler synchronously inside
/// `Task.cancel()`, so the recorded moment is the moment the coordinator
/// cancelled — not whenever the parked slice next got scheduled, which would make
/// the recorded order a race rather than an observation.
private struct ParkingAdapter: ProviderAdapter {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false
        private var isParkedStorage = false

        var isParked: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isParkedStorage
        }

        func park() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                isParkedStorage = true
                if isReleased {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            isReleased = true
            lock.unlock()
            waiting?.resume()
        }
    }

    let providerID: ProviderID = .claude
    let gate: Gate
    let log: DeletionOrderLog

    var requiresSecret: Bool { false }
    var scopedIsNoOp: Bool { false }

    func scoped(to interval: DateInterval) -> any ProviderAdapter { self }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        await withTaskCancellationHandler {
            await gate.park()
        } onCancel: {
            log.record(.backfillCancelled)
            gate.release()
        }

        // A slice cancelled mid-flight produces nothing. Returning a result here
        // would have the test writing snapshots for an account being deleted —
        // the very thing the cancel exists to prevent.
        throw CancellationError()
    }
}

/// Records what was sent, not merely how often, so a test can prove *which*
/// account was named as well as the transition rule.
@MainActor
final class RecordingQuotaNotifier: QuotaNotifier {
    private(set) var sentNames: [String] = []

    var sentCount: Int { sentNames.count }

    nonisolated func notifySessionExpired(accountDisplayName: String) async {
        await MainActor.run { sentNames.append(accountDisplayName) }
    }
}

/// A source whose behaviour a test can flip between ticks, so recovery and a
/// fresh failure can be exercised without any wall-clock time or real web view.
@MainActor
final class SwitchableQuotaSource: RateWindowSource {
    enum Behaviour {
        case expired
        case transportFailure
        case healthy
    }

    var behaviour: Behaviour

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    nonisolated func fetchWindows(account: Account, secret: String?) async throws -> RateWindowResult {
        await MainActor.run {
            switch behaviour {
            case .expired:
                return RateWindowResult(
                    windows: [], dataQuality: .unavailable,
                    message: RateWindowSourceError.sessionExpired.message
                )
            case .transportFailure:
                return RateWindowResult(
                    windows: [], dataQuality: .unavailable,
                    message: RateWindowSourceError.transportFailure.message
                )
            case .healthy:
                return RateWindowResult(
                    windows: [
                        RateWindow(
                            kind: .rollingFiveHours, usedFraction: 0.4,
                            resetAt: Date(timeIntervalSince1970: 1_800_003_600),
                            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
                        ),
                    ],
                    dataQuality: .exact, message: nil
                )
            }
        }
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

/// Returns one fixed window every time, so a tick can re-confirm a value the
/// ledger already holds without changing it.
private struct StableRateWindowSource: RateWindowSource {
    let window: RateWindow

    func fetchWindows(account: Account, secret: String?) async throws -> RateWindowResult {
        RateWindowResult(windows: [window], dataQuality: .partial, message: nil)
    }
}

/// Reports one fixed window and signals each fetch, so a test can observe that a
/// collection happened without waiting on wall-clock time.
private struct SignallingRateWindowSource: RateWindowSource {
    let window: RateWindow
    let onFetch: @Sendable () -> Void

    func fetchWindows(account: Account, secret: String?) async throws -> RateWindowResult {
        onFetch()
        return RateWindowResult(windows: [window], dataQuality: .exact, message: nil)
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
