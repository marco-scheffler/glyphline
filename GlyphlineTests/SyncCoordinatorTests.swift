import GRDB
import XCTest
@testable import Glyphline

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLedger() throws -> (DatabaseQueue, LedgerStore) {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        return (dbQueue, LedgerStore(dbQueue: dbQueue))
    }

    @discardableResult
    private func saveAccount(
        _ name: String,
        in ledger: LedgerStore,
        isEnabled: Bool = true
    ) throws -> Account {
        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: name,
            credentialReference: "local-source://\(name)",
            createdAt: Self.now,
            isEnabled: isEnabled
        )
        try ledger.saveAccount(account)
        return account
    }

    // MARK: - Degraded path: no durable ledger

    func testCollectingWithoutALedgerReportsRatherThanSilentlyDoingNothing() async {
        let coordinator = SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry()
        )

        await coordinator.collectRateWindows()

        XCTAssertEqual(coordinator.syncFailureMessage, "Ledger unavailable. Nothing was synced.")
    }

    func testTheLedgerUnavailableMessageCarriesNoCredentialDetail() {
        let message = SyncCoordinator.ledgerUnavailableMessage

        XCTAssertFalse(message.localizedCaseInsensitiveContains("keychain://"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("token"))
    }

    func testASuccessfulCollectionClearsAStaleFailureMessage() async throws {
        let (_, ledger) = try makeLedger()

        let degraded = SyncCoordinator(
            ledger: nil,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry()
        )
        await degraded.collectRateWindows()
        XCTAssertNotNil(degraded.syncFailureMessage)

        // A coordinator that does have a ledger must never carry the message.
        let healthy = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry()
        )
        await healthy.collectRateWindows()

        XCTAssertNil(healthy.syncFailureMessage)
    }

    // MARK: - The scheduler

    func testSchedulerRepeatsUntilStopped() async throws {
        let (_, ledger) = try makeLedger()
        try saveAccount("Max #1", in: ledger)

        let sleeps = Counter()
        // Fulfilled from inside the injected sleep, so the test waits on the loop
        // actually turning over rather than on wall-clock time passing.
        let looped = expectation(description: "scheduler sleeps more than once")
        looped.expectedFulfillmentCount = 2
        looped.assertForOverFulfill = false

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
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
        let (_, ledger) = try makeLedger()
        try saveAccount("Max #1", in: ledger)

        let now = Self.now
        let collected = expectation(description: "rate windows collected")
        collected.assertForOverFulfill = false

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
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
        await fulfillment(of: [collected], timeout: 10)
    }

    func testStartingTwiceDoesNotRunTwoLoops() async throws {
        let (_, ledger) = try makeLedger()
        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            sleepForSeconds: { _ in try await Task.sleep(for: .milliseconds(10)) }
        )

        coordinator.startScheduler(intervalSeconds: 60)
        coordinator.startScheduler(intervalSeconds: 60)
        XCTAssertTrue(coordinator.isSchedulerRunning)

        coordinator.stopScheduler()
        XCTAssertFalse(coordinator.isSchedulerRunning)
    }

    func testReapplyingTheSameScheduleDoesNotResetThePhase() async throws {
        let (_, ledger) = try makeLedger()

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
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
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
            "re-applying an unchanged schedule must not restart the loop and push the next collection out"
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

    // MARK: - Collecting quota

    /// Non-async so GRDB's synchronous `read` overload is the one selected;
    /// the tests below call it from an async context.
    private nonisolated static func rateWindowSampleCount(_ dbQueue: DatabaseQueue) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rateWindowSamples") ?? 0
        }
    }

    func testCollectingRateWindowsStoresThemAndAppliesRetention() async throws {
        let (dbQueue, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

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
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in FixtureRateWindowSource(now: { now }) }
        )

        await coordinator.collectRateWindows()

        let stored = try ledger.fetchLatestRateWindows(accountID: account.id)
        XCTAssertEqual(Set(stored.map(\.kind)), [.rollingFiveHours, .weekly])

        let total = try Self.rateWindowSampleCount(dbQueue)
        XCTAssertEqual(total, 2, "the 400-day-old sample should have been deleted by retention")
    }

    func testDisabledAccountsAreNotCollectedFor() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let enabled = try saveAccount("On", in: ledger)
        let disabled = try saveAccount("Off", in: ledger, isEnabled: false)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in FixtureRateWindowSource(now: { now }) }
        )

        await coordinator.collectRateWindows()

        XCTAssertEqual(coordinator.quotaStates.map(\.accountID), [enabled.id])
        XCTAssertTrue(try ledger.fetchLatestRateWindows(accountID: disabled.id).isEmpty)
    }

    /// Pins the actual guarantee: a failed quota fetch contributes no quota row.
    func testAFailingRateWindowFetchWritesNoQuotaRowAndRecordsAReason() async throws {
        let (dbQueue, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in
                FixtureRateWindowSource(now: { now }, behaviour: .unavailable)
            }
        )

        await coordinator.collectRateWindows()

        XCTAssertEqual(try Self.rateWindowSampleCount(dbQueue), 0)
        XCTAssertTrue(try ledger.fetchLatestRateWindows(accountID: account.id).isEmpty)
        XCTAssertNotNil(coordinator.rateWindowMessages[account.id])
    }

    /// A per-account failure belongs to that account. `syncFailureMessage` is the
    /// whole-app line in the menu bar panel, and a single silent subscription must
    /// not raise it.
    func testAFailingRateWindowFetchLeavesTheWholeAppFailureLineClear() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in
                FixtureRateWindowSource(now: { now }, behaviour: .unavailable)
            }
        )

        await coordinator.collectRateWindows()

        // The quota side must actually have failed, or the claim is unexercised.
        XCTAssertNotNil(coordinator.rateWindowMessages[account.id])
        XCTAssertNil(coordinator.syncFailureMessage)
    }

    /// Every account with no route takes this path, so this string is what a user
    /// reads. It must not imply there is a setup step available: the spike found
    /// none.
    func testAnAccountWithNoSourceIsToldQuotaIsUnavailableNotUnconfigured() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in nil }
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

    // MARK: - Freshness

    /// The end-to-end shape of the change-detection defect.
    ///
    /// The provider keeps reporting the same figure at the same reset instant.
    /// The store drops the repeat — correctly, the value has not changed — so
    /// the stored `observedAt` stays put. With freshness measured from that
    /// column, a successful fetch seconds ago produced a grey icon, which
    /// inverts what the feature is for.
    func testAStableReadingStaysFreshWhileTheProviderKeepsConfirmingIt() async throws {
        let (dbQueue, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

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
            registry: ProviderAdapterRegistry(),
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
    }

    /// Window kinds are confirmed independently. A single per-account timestamp
    /// would let a window that was just fetched vouch for one that nobody
    /// managed to fetch on this tick.
    func testAFreshlyConfirmedWindowDoesNotVouchForAStaleOneOfAnotherKind() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

        // Headroom, but observed well beyond the 600s bound and never confirmed.
        try ledger.saveRateWindow(
            RateWindow(kind: .rollingFiveHours, usedFraction: 0.3,
                       resetAt: now.addingTimeInterval(1_800),
                       observedAt: now.addingTimeInterval(-1_200)),
            accountID: account.id
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            sleepForSeconds: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { now },
            rateWindowSourceProvider: { _ in
                // A different kind, fetched and confirmed on this very tick, and
                // carrying no fraction — so it decides nothing by itself.
                StableRateWindowSource(
                    window: RateWindow(kind: .weekly, usedFraction: nil,
                                       resetAt: now.addingTimeInterval(86_400), observedAt: now)
                )
            }
        )

        coordinator.startScheduler(intervalSeconds: 300)
        defer { coordinator.stopScheduler() }

        await coordinator.collectRateWindows()

        let kinds = try ledger.fetchLatestRateWindows(accountID: account.id).map(\.kind)
        XCTAssertTrue(kinds.contains(.weekly), "precondition: the weekly window was fetched now")
        XCTAssertTrue(kinds.contains(.rollingFiveHours), "precondition: the stale window is still stored")

        XCTAssertEqual(
            coordinator.quotaLight, .grey,
            "a freshly confirmed weekly window says nothing about a 5h window nobody fetched"
        )
    }

    /// The light reads the bound the scheduler's own interval derives — twice the
    /// poll interval — and not one a call site picked. The interval here is
    /// deliberately not the 1800s default, so a hardcoded bound would believe this
    /// 20-minute-old observation and turn the icon green.
    func testTheLightUsesTheBoundDerivedFromThePollInterval() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let account = try saveAccount("Max #1", in: ledger)

        // Headroom, so a believed observation would yield green.
        try ledger.saveRateWindow(
            RateWindow(kind: .rollingFiveHours, usedFraction: 0.3,
                       resetAt: now.addingTimeInterval(1_800),
                       observedAt: now.addingTimeInterval(-1_200)),
            accountID: account.id
        )

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            sleepForSeconds: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { now },
            rateWindowSourceProvider: { _ in nil }
        )

        coordinator.startScheduler(intervalSeconds: 300)
        defer { coordinator.stopScheduler() }

        await coordinator.collectRateWindows()

        XCTAssertEqual(coordinator.quotaLight, .grey, "600s bound: a 20-minute-old observation is stale")
    }

    // MARK: - Notify once, on the transition

    private func makeExpiringCoordinator(
        source: any RateWindowSource,
        notifier: RecordingQuotaNotifier
    ) throws -> SyncCoordinator {
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let account = Account(
            id: UUID(), providerID: .claude, displayName: "Max #1",
            credentialReference: "local-source://x", createdAt: now, isEnabled: true,
            claudeOrganizationID: "org-1"
        )
        try ledger.saveAccount(account)

        return SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
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
        let (_, ledger) = try makeLedger()
        let now = Self.now
        let doomed = try saveAccount("Doomed", in: ledger)
        let survivor = try saveAccount("Survivor", in: ledger)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in nil }
        )
        await coordinator.collectRateWindows()

        // Guards the assertions below. Without these, a coordinator that never
        // recorded any state would pass the whole test vacuously.
        XCTAssertNotNil(coordinator.rateWindowMessages[doomed.id])
        XCTAssertTrue(coordinator.quotaStates.contains { $0.accountID == doomed.id })

        coordinator.forgetAccount(id: doomed.id)

        XCTAssertNil(coordinator.rateWindowMessages[doomed.id])
        XCTAssertFalse(coordinator.quotaStates.contains { $0.accountID == doomed.id })

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

    // MARK: - Deletion

    /// `forgetAccount` runs only when the flow reports `.deleted`.
    ///
    /// A failed delete leaves the account in the ledger and on screen. Forgetting
    /// it anyway would blank the in-memory state of a row that is still there, so
    /// the surviving account would show nothing at all.
    func testAFailedDeletionKeepsTheAccountsState() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
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
            createdAt: now,
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in nil }
        )
        await coordinator.collectRateWindows()

        // Guards the assertion below. Without state to lose, a coordinator that
        // forgot the account unconditionally would still pass.
        XCTAssertNotNil(
            coordinator.rateWindowMessages[accountID],
            "precondition: the tick must have recorded a reason"
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
            coordinator.rateWindowMessages[accountID],
            "a failed delete must not forget the account"
        )
    }

    /// The successful half: the coordinator drops what it holds for an account the
    /// flow actually deleted, so no stale row survives the deletion on screen.
    func testASuccessfulDeletionForgetsTheAccount() async throws {
        let (_, ledger) = try makeLedger()
        let now = Self.now
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
            createdAt: now,
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(),
            now: { now },
            rateWindowSourceProvider: { _ in nil }
        )
        await coordinator.collectRateWindows()
        XCTAssertNotNil(coordinator.rateWindowMessages[accountID])

        let flow = DeleteAccountFlow(
            ledgerStore: ledger,
            credentialStore: credentials,
            webSessions: SucceedingRemover()
        )
        let outcome = await coordinator.deleteAccount(account, using: flow)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertNil(coordinator.rateWindowMessages[accountID])
        XCTAssertTrue(coordinator.quotaStates.isEmpty)
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

/// A stand-in for WebKit on the successful path. Nothing here may touch a real
/// `WKWebsiteDataStore`.
private final class SucceedingRemover: WebSessionRemoving {
    func removeSession(for accountID: UUID) async throws {}
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
