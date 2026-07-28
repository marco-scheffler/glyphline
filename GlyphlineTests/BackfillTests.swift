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

    func testCancelStopsTheBackfillAndKeepsProgress() async throws {
        let (ledger, credentials, account) = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = makeCoordinator(
            ledger: ledger,
            credentials: credentials,
            now: now,
            adapter: RecordingAdapter(providerID: .openAI, log: RecordingAdapter.Log())
        )

        await coordinator.syncNow(account: account)

        let task = Task { await coordinator.backfill(account: account) }
        coordinator.cancelBackfill(account: account)
        await task.value

        XCTAssertEqual(coordinator.activities[account.id], .idle)
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

    /// A backfilled bucket and a routine-synced bucket must not overwrite each other
    /// with partial data, in either order: both write the same absolute day total.
    func testBackfilledAndRoutineBucketsAgreeInEitherOrder() throws {
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
