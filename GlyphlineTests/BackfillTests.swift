import GRDB
import XCTest
@testable import Glyphline

/// Records the windows it was scoped to, so the test can assert on slicing.
struct RecordingAdapter: ProviderAdapter {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DateInterval] = []

        func append(_ interval: DateInterval) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(interval)
        }

        var intervals: [DateInterval] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    let providerID: ProviderID
    var log: Log
    var interval: DateInterval?

    var scopedIsNoOp: Bool { false }

    func scoped(to interval: DateInterval) -> any ProviderAdapter {
        var copy = self
        copy.interval = interval
        return copy
    }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        if let interval {
            log.append(interval)
        }

        return ProviderSyncResult(
            providerID: providerID,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: false,
                supportsResetDate: false,
                supportsModelBreakdown: false,
                dataQuality: .exact,
                message: nil
            ),
            billingPeriod: nil,
            usageSnapshots: [],
            costSnapshots: [],
            estimateSnapshots: [],
            syncedAt: interval?.end ?? Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

/// A source that cannot address a date range, like the local Claude Code log reader.
struct UnscopableAdapter: ProviderAdapter {
    let providerID: ProviderID

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        ProviderSyncResult(
            providerID: providerID,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: false,
                supportsResetDate: false,
                supportsModelBreakdown: false,
                dataQuality: .partial,
                message: nil
            ),
            billingPeriod: nil,
            usageSnapshots: [],
            costSnapshots: [],
            estimateSnapshots: [],
            syncedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

/// Cancels the running backfill from inside a slice, so cancellation is exercised
/// mid-flight rather than before the task has started.
struct CancellingAdapter: ProviderAdapter {
    final class Trigger: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DateInterval] = []
        var cancelAfterSlices = 1
        var onCancel: (@Sendable () async -> Void)?

        func record(_ interval: DateInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            storage.append(interval)
            return storage.count >= cancelAfterSlices
        }

        var intervals: [DateInterval] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    let providerID: ProviderID
    var trigger: Trigger
    var interval: DateInterval?

    var scopedIsNoOp: Bool { false }

    func scoped(to interval: DateInterval) -> any ProviderAdapter {
        var copy = self
        copy.interval = interval
        return copy
    }

    func sync(account: Account, secret: String) async throws -> ProviderSyncResult {
        // Awaited, so cancellation has definitely landed before this slice returns
        // and the loop re-checks `Task.isCancelled`. No sleeping, no wall clock.
        if let interval, trigger.record(interval) {
            await trigger.onCancel?()
        }

        return ProviderSyncResult(
            providerID: providerID,
            accountID: account.id,
            capabilities: ProviderCapabilities(
                supportsUsage: true,
                supportsActualCost: false,
                supportsResetDate: false,
                supportsModelBreakdown: false,
                dataQuality: .exact,
                message: nil
            ),
            billingPeriod: nil,
            usageSnapshots: [],
            costSnapshots: [],
            estimateSnapshots: [],
            syncedAt: interval?.end ?? Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

@MainActor
final class BackfillTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func makeFixture() throws -> (LedgerStore, InMemoryCredentialStore, Account) {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Backfill",
            credentialReference: "keychain://glyphline/backfill",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)
        try credentials.save(secret: "secret", for: account.credentialReference)

        return (ledger, credentials, account)
    }

    private func makeCoordinator(
        ledger: LedgerStore,
        credentials: InMemoryCredentialStore,
        now: Date,
        adapter: any ProviderAdapter
    ) -> SyncCoordinator {
        SyncCoordinator(
            ledger: ledger,
            credentials: credentials,
            registry: ProviderAdapterRegistry(),
            estimator: CostEstimator(catalog: PricingCatalog(entries: [])),
            adapterProvider: { _ in adapter },
            now: { now }
        )
    }

    func testBackfillWalksBackwardsInWeeklySlices() async throws {
        let (ledger, credentials, account) = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let log = RecordingAdapter.Log()
        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: RecordingAdapter(providerID: .openAI, log: log)
        )

        await coordinator.syncNow(account: account)
        await coordinator.backfill(account: account)

        let intervals = log.intervals
        XCTAssertFalse(intervals.isEmpty)

        // Slices go backwards and never overlap.
        for (earlier, later) in zip(intervals.dropFirst(), intervals) {
            XCTAssertLessThanOrEqual(earlier.end, later.start)
        }

        // Every slice is a week or less, inside both providers' window caps.
        for interval in intervals {
            XCTAssertLessThanOrEqual(interval.duration, 7 * 86_400 + 1)
        }

        let recorded = try XCTUnwrap(try ledger.fetchBackfillCompletedThrough(accountID: account.id))
        XCTAssertLessThan(recorded, now)
    }

    func testBackfillResumesFromRecordedProgress() async throws {
        let (ledger, credentials, account) = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: RecordingAdapter(providerID: .openAI, log: RecordingAdapter.Log())
        )
        await first.syncNow(account: account)

        // Pretend a previous run already reached two weeks back.
        let alreadyDone = now.addingTimeInterval(-14 * 86_400)
        try ledger.saveBackfillCompletedThrough(alreadyDone, accountID: account.id)

        // A second coordinator over the same ledger stands in for a later app launch.
        let log = RecordingAdapter.Log()
        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: RecordingAdapter(providerID: .openAI, log: log)
        )
        await coordinator.backfill(account: account)

        for interval in log.intervals {
            XCTAssertLessThanOrEqual(interval.end, alreadyDone, "resumed run must not redo finished weeks")
        }
    }

    /// Renamed from `testCancelStopsTheBackfillAndKeepsProgress`, which claimed a
    /// guarantee it did not check: `backfill` is `@MainActor`, so the task body
    /// cannot begin before the synchronous `cancelBackfill` on the same actor runs,
    /// and at that point there is no registered task to cancel. Nothing was ever
    /// cancelled here. What it does establish is that the no-op cancel neither
    /// wedges the coordinator nor truncates the walk that follows — worth keeping,
    /// under a name that says so. Mid-flight cancellation is covered by
    /// `testCancelMidFlightStopsFurtherSlicesAndKeepsProgress`.
    func testCancellingWhenNoBackfillIsRunningIsANoOp() async throws {
        let (ledger, credentials, account) = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let log = RecordingAdapter.Log()
        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: RecordingAdapter(providerID: .openAI, log: log)
        )

        await coordinator.syncNow(account: account)

        let task = Task { await coordinator.backfill(account: account) }
        coordinator.cancelBackfill(account: account)
        await task.value

        XCTAssertEqual(coordinator.activities[account.id], .idle)

        let today = utc.startOfDay(for: now)
        let horizon = try XCTUnwrap(
            utc.date(byAdding: .day, value: -SyncCoordinator.backfillHorizonDays, to: today)
        )
        XCTAssertEqual(
            log.intervals.count,
            Int(ceil(Double(SyncCoordinator.backfillHorizonDays) / Double(SyncCoordinator.backfillSliceDays))),
            "the walk that follows a no-op cancel must still cover the whole horizon"
        )
        XCTAssertEqual(log.intervals.last?.start, horizon)
        XCTAssertEqual(
            try ledger.fetchBackfillCompletedThrough(accountID: account.id),
            horizon,
            "progress must be recorded all the way back"
        )
    }

    /// The counterpart to the slicing path: an account missing from the ledger makes
    /// `saveBackfillCompletedThrough` throw `LedgerStoreError.unknownAccount`, and
    /// this branch used to swallow it with `try?` — re-silencing exactly the error a
    /// Task 3 fix was written to surface.
    func testAnUnscopableSourceSurfacesALedgerWriteFailure() async throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)
        let credentials = InMemoryCredentialStore()

        // Deliberately never saved to the ledger.
        let account = Account(
            id: UUID(),
            providerID: .openAI,
            displayName: "Unknown",
            credentialReference: "keychain://glyphline/unknown",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )

        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            adapter: UnscopableAdapter(providerID: .openAI)
        )

        await coordinator.backfill(account: account)

        guard case .failed = coordinator.activities[account.id] else {
            return XCTFail(
                "a ledger write that failed must be surfaced, not reported as completed backfill; got "
                    + String(describing: coordinator.activities[account.id])
            )
        }
        XCTAssertNil(try ledger.fetchBackfillCompletedThrough(accountID: account.id))
    }

    // MARK: - Bucket-integrity and cancellation guarantees

    /// Every slice boundary must be a UTC midnight. Adapters label buckets as whole
    /// UTC days and the ledger upsert replaces a bucket rather than accumulating, so
    /// a mid-day boundary would emit a fragment as a full day and shrink a total a
    /// routine sync had already written correctly.
    func testSliceBoundariesAreUTCMidnightsAndNeverCutABucket() async throws {
        let (ledger, credentials, account) = try makeFixture()

        // Deliberately not a midnight: 1_800_000_000 is 08:00 UTC.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotEqual(utc.startOfDay(for: now), now, "fixture must exercise a mid-day clock")

        let log = RecordingAdapter.Log()
        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: RecordingAdapter(providerID: .openAI, log: log)
        )
        await coordinator.backfill(account: account)

        let intervals = log.intervals
        XCTAssertFalse(intervals.isEmpty)

        for interval in intervals {
            XCTAssertEqual(utc.startOfDay(for: interval.start), interval.start)
            XCTAssertEqual(utc.startOfDay(for: interval.end), interval.end)
            XCTAssertEqual(interval.duration.truncatingRemainder(dividingBy: 86_400), 0)
        }

        // Backfill never reaches into today, the one bucket still open and growing,
        // so it cannot overwrite a fresher routine-sync value for it.
        let today = utc.startOfDay(for: now)
        for interval in intervals {
            XCTAssertLessThanOrEqual(interval.end, today)
        }
        XCTAssertEqual(intervals.first?.end, today)

        // The slices tile the horizon exactly: no gap, no overlap, nothing cut.
        for (earlier, later) in zip(intervals.dropFirst(), intervals) {
            XCTAssertEqual(earlier.end, later.start)
        }

        let horizon = try XCTUnwrap(utc.date(byAdding: .day, value: -365, to: today))
        XCTAssertEqual(intervals.last?.start, horizon)
        XCTAssertEqual(try ledger.fetchBackfillCompletedThrough(accountID: account.id), horizon)
    }

    /// The local log reader path: nothing to slice, so completion is recorded at once.
    func testUnscopableSourceRecordsCompletionWithoutSlicing() async throws {
        let (ledger, credentials, account) = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: UnscopableAdapter(providerID: .openAI)
        )

        await coordinator.backfill(account: account)

        let today = utc.startOfDay(for: now)
        let horizon = try XCTUnwrap(utc.date(byAdding: .day, value: -365, to: today))
        XCTAssertEqual(try ledger.fetchBackfillCompletedThrough(accountID: account.id), horizon)
    }

    /// Cancelling from inside a slice must stop further slices and keep the progress
    /// already recorded, so a later run resumes instead of restarting.
    func testCancelMidFlightStopsFurtherSlicesAndKeepsProgress() async throws {
        let (ledger, credentials, account) = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let trigger = CancellingAdapter.Trigger()
        trigger.cancelAfterSlices = 3

        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: CancellingAdapter(providerID: .openAI, trigger: trigger)
        )
        trigger.onCancel = { [weak coordinator] in
            await MainActor.run { coordinator?.cancelBackfill(account: account) }
        }

        await coordinator.backfill(account: account)

        XCTAssertEqual(trigger.intervals.count, 3, "cancellation must stop the walk")
        XCTAssertEqual(coordinator.activities[account.id], .idle)

        let today = utc.startOfDay(for: now)
        let expected = try XCTUnwrap(utc.date(byAdding: .day, value: -21, to: today))
        XCTAssertEqual(try ledger.fetchBackfillCompletedThrough(accountID: account.id), expected)
    }

    // MARK: - Ledger watermark durability

    /// Regression: `saveBackfillCompletedThrough` used to be a bare `UPDATE`, so for
    /// an account with no `accountSyncStates` row it matched nothing and silently
    /// no-opped — the watermark vanished and backfill restarted from scratch forever.
    func testWatermarkPersistsForAnAccountThatHasNeverSynced() throws {
        let (ledger, _, account) = try makeFixture()

        XCTAssertNil(try ledger.fetchBackfillCompletedThrough(accountID: account.id))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try ledger.saveBackfillCompletedThrough(day, accountID: account.id)

        XCTAssertEqual(try ledger.fetchBackfillCompletedThrough(accountID: account.id), day)
    }

    /// The synthesised row must not claim a data quality it does not have.
    func testWatermarkRowForANeverSyncedAccountClaimsNoCapabilities() throws {
        let (ledger, _, account) = try makeFixture()
        try ledger.saveBackfillCompletedThrough(
            Date(timeIntervalSince1970: 1_700_000_000),
            accountID: account.id
        )

        let summary = try XCTUnwrap(
            try ledger.fetchAccountSummaries().first { $0.account.id == account.id }
        )
        XCTAssertEqual(summary.dataQuality, .unavailable)
    }

    func testWatermarkForAnUnknownAccountIsRejectedRatherThanLost() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        XCTAssertThrowsError(
            try ledger.saveBackfillCompletedThrough(Date(timeIntervalSince1970: 1), accountID: UUID())
        )
    }

    // MARK: - Real adapters honour the scoped window

    /// The Claude Admin adapter must query the slice it was scoped to, and must not
    /// report that historic slice as the account's billing period.
    func testScopedClaudeAdapterQueriesTheWindowAndReportsNoBillingPeriod() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }

        func fixture(_ name: String) throws -> Data {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }

        StubURLProtocol.enqueue(
            path: "/v1/organizations/usage_report/messages",
            body: try fixture("claude-usage-report")
        )
        StubURLProtocol.enqueue(
            path: "/v1/organizations/usage_report/messages",
            body: try fixture("claude-usage-report-page2")
        )
        StubURLProtocol.enqueue(
            path: "/v1/organizations/cost_report",
            body: try fixture("claude-cost-report")
        )

        let base = ClaudeUsageAdapter(
            mode: .adminAPI,
            session: StubURLProtocol.makeSession(),
            now: { Date(timeIntervalSince1970: 1_783_000_000) }
        )
        XCTAssertFalse(base.scopedIsNoOp)

        let start = utc.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let end = try XCTUnwrap(utc.date(byAdding: .day, value: 7, to: start))
        let scoped = base.scoped(to: DateInterval(start: start, end: end))

        let account = Account(
            id: UUID(),
            providerID: .claude,
            displayName: "Org",
            credentialReference: "keychain://glyphline/org",
            createdAt: start,
            isEnabled: true
        )
        let result = try await scoped.sync(account: account, secret: "sk-ant-admin-test")

        XCTAssertNil(result.billingPeriod, "a historic slice is not a billing period")

        let queries = StubURLProtocol.requestedURLs.compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        }
        XCTAssertFalse(queries.isEmpty)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let expectedStart = formatter.string(from: start)
        let expectedEnd = formatter.string(from: end)

        for items in queries {
            // Paged follow-up requests carry a cursor instead of a fresh range.
            guard let starting = items.first(where: { $0.name == "starting_at" })?.value else {
                continue
            }
            XCTAssertEqual(starting, expectedStart)
            XCTAssertEqual(items.first(where: { $0.name == "ending_at" })?.value, expectedEnd)
        }
    }

    /// The local-log mode cannot address a date range, so scoping must be inert.
    func testClaudeLocalLogModeRefusesScoping() {
        let adapter = ClaudeUsageAdapter(mode: .localLogs)
        XCTAssertTrue(adapter.scopedIsNoOp)

        let scoped = adapter.scoped(
            to: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 86_400))
        )
        XCTAssertNil((scoped as? ClaudeUsageAdapter)?.window, "local logs must ignore a window")
    }

    func testCursorLocalStatusModeRefusesScoping() {
        let adapter = CursorUsageAdapter(mode: .localStatusOnly)
        XCTAssertTrue(adapter.scopedIsNoOp)

        let scoped = adapter.scoped(
            to: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 86_400))
        )
        XCTAssertNil((scoped as? CursorUsageAdapter)?.window)
    }

    func testCursorTeamModeAcceptsScoping() {
        let adapter = CursorUsageAdapter(mode: .teamAPI)
        XCTAssertFalse(adapter.scopedIsNoOp)

        let window = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400)
        )
        XCTAssertEqual((adapter.scoped(to: window) as? CursorUsageAdapter)?.window, window)
    }

    // MARK: - Backfill must not erase what routine sync wrote

    /// Regression: a scoped adapter returns `billingPeriod: nil` on purpose, but
    /// `upsertAccountSyncState` used to assign the billing columns unconditionally,
    /// so nil meant NULL rather than "leave alone". Phase one wrote the true period
    /// and each of the ~53 backfill slices immediately erased it, making the reset
    /// date vanish from the UI until the next routine sync.
    ///
    /// Asserted through the ledger, not at the adapter boundary: an adapter-level
    /// `XCTAssertNil(result.billingPeriod)` is exactly what let this through.
    func testScopedSliceDoesNotEraseTheBillingPeriodRoutineSyncWrote() throws {
        let (ledger, _, account) = try makeFixture()

        func result(billingPeriod: BillingPeriod?) -> ProviderSyncResult {
            ProviderSyncResult(
                providerID: .openAI,
                accountID: account.id,
                capabilities: ProviderCapabilities(
                    supportsUsage: true,
                    supportsActualCost: true,
                    supportsResetDate: billingPeriod != nil,
                    supportsModelBreakdown: false,
                    dataQuality: .exact,
                    message: nil
                ),
                billingPeriod: billingPeriod,
                usageSnapshots: [],
                costSnapshots: [],
                estimateSnapshots: [],
                syncedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }

        func persist(_ result: ProviderSyncResult, at finishedAt: Date) throws {
            let runID = try ledger.startSyncRun(accountID: account.id, providerID: .openAI, startedAt: finishedAt)
            try ledger.applySuccessfulSyncResult(result, syncRunID: runID, finishedAt: finishedAt)
        }

        // Phase one records the account's real billing period.
        let period = BillingPeriod(
            startsAt: Date(timeIntervalSince1970: 1_798_761_600),
            endsAt: nil,
            resetAt: Date(timeIntervalSince1970: 1_801_440_000)
        )
        try persist(result(billingPeriod: period), at: Date(timeIntervalSince1970: 1_800_000_000))

        let afterPhaseOne = try XCTUnwrap(
            try ledger.fetchAccountSummaries().first { $0.account.id == account.id }
        )
        XCTAssertEqual(afterPhaseOne.billingPeriod, period)

        // A backfill slice lands: correct usage, deliberately no billing period.
        try persist(result(billingPeriod: nil), at: Date(timeIntervalSince1970: 1_800_000_060))

        let afterSlice = try XCTUnwrap(
            try ledger.fetchAccountSummaries().first { $0.account.id == account.id }
        )
        XCTAssertEqual(
            afterSlice.billingPeriod,
            period,
            "a scoped slice must not erase the period routine sync wrote"
        )
    }

    /// The counterpart: a later routine sync that *does* report a period still
    /// replaces the stored one, so COALESCE cannot freeze a stale value in place.
    func testARoutineSyncStillReplacesTheStoredBillingPeriod() throws {
        let (ledger, _, account) = try makeFixture()

        func result(billingPeriod: BillingPeriod?) -> ProviderSyncResult {
            ProviderSyncResult(
                providerID: .openAI,
                accountID: account.id,
                capabilities: ProviderCapabilities(
                    supportsUsage: true,
                    supportsActualCost: true,
                    supportsResetDate: billingPeriod != nil,
                    supportsModelBreakdown: false,
                    dataQuality: .exact,
                    message: nil
                ),
                billingPeriod: billingPeriod,
                usageSnapshots: [],
                costSnapshots: [],
                estimateSnapshots: [],
                syncedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }

        func persist(_ result: ProviderSyncResult, at finishedAt: Date) throws {
            let runID = try ledger.startSyncRun(accountID: account.id, providerID: .openAI, startedAt: finishedAt)
            try ledger.applySuccessfulSyncResult(result, syncRunID: runID, finishedAt: finishedAt)
        }

        let old = BillingPeriod(
            startsAt: Date(timeIntervalSince1970: 1_798_761_600),
            endsAt: nil,
            resetAt: Date(timeIntervalSince1970: 1_801_440_000)
        )
        let new = BillingPeriod(
            startsAt: Date(timeIntervalSince1970: 1_801_440_000),
            endsAt: nil,
            resetAt: Date(timeIntervalSince1970: 1_804_118_400)
        )

        try persist(result(billingPeriod: old), at: Date(timeIntervalSince1970: 1_800_000_000))
        try persist(result(billingPeriod: new), at: Date(timeIntervalSince1970: 1_801_500_000))

        let summary = try XCTUnwrap(
            try ledger.fetchAccountSummaries().first { $0.account.id == account.id }
        )
        XCTAssertEqual(summary.billingPeriod, new, "a fresh period must still win")
    }

    /// Renamed from `testBackfilledAndRoutineBucketsAgreeInEitherOrder`, which named
    /// a guarantee it did not check: it writes the same snapshot twice through the
    /// same call and asserts on the value it constructed, so no producer is involved
    /// and no order is exercised. What it does establish — that the usage upsert
    /// replaces a whole-day bucket rather than duplicating it under a second row —
    /// is the property everything else depends on, so it stays under an honest name.
    /// The producers agreeing on the boundary is covered by
    /// `testSliceBoundariesAreUTCMidnightsAndNeverCutABucket`.
    func testUpsertingTheSameWholeDayBucketTwiceIsIdempotent() throws {
        let (ledger, _, account) = try makeFixture()
        let day = utc.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let nextDay = try XCTUnwrap(utc.date(byAdding: .day, value: 1, to: day))

        func snapshot(inputTokens: Int64) -> UsageSnapshot {
            UsageSnapshot(
                id: SnapshotIdentity.make(
                    accountID: account.id,
                    providerID: .openAI,
                    bucketStart: day,
                    bucketEnd: nextDay,
                    discriminator: "gpt-4o"
                ),
                accountID: account.id,
                providerID: .openAI,
                bucketStart: day,
                bucketEnd: nextDay,
                model: "gpt-4o",
                inputTokens: inputTokens,
                outputTokens: 0,
                requests: 1,
                quality: .exact
            )
        }

        // Routine sync writes the completed day, then backfill revisits it.
        try ledger.upsertUsageSnapshots([snapshot(inputTokens: 900)])
        try ledger.upsertUsageSnapshots([snapshot(inputTokens: 900)])

        let stored = try ledger.fetchUsageSnapshots(accountID: account.id)
        XCTAssertEqual(stored.count, 1, "same bucket key must not duplicate")
        XCTAssertEqual(stored.first?.inputTokens, 900, "a whole-day total must survive a revisit")
    }
}
