import GRDB
import XCTest
@testable import Glyphline

@MainActor
final class SyncCoordinatorLocalUsageTests: XCTestCase {
    /// 2024-03-15T12:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_710_504_000)

    private func makeLedger() throws -> (DatabaseQueue, LedgerStore) {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.makeMigrator().migrate(dbQueue)
        return (dbQueue, LedgerStore(dbQueue: dbQueue))
    }

    private func makeEstimator() -> CostEstimator {
        CostEstimator(
            catalog: PricingCatalog(entries: [
                PricingEntry(
                    providerID: .claude,
                    model: "priced-model",
                    inputMicrosPerMillionTokens: 3_000_000,
                    outputMicrosPerMillionTokens: 15_000_000,
                    cacheCreationMicrosPerMillionTokens: nil,
                    cacheReadMicrosPerMillionTokens: nil,
                    currency: "USD",
                    effectiveDate: "2024-01-01",
                    source: "test"
                ),
            ])
        )
    }

    private func makeCoordinator(
        ledger: LedgerStore?,
        scan: (@Sendable () throws -> LocalScanResult)?
    ) -> SyncCoordinator {
        SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            localScan: scan,
            costEstimator: makeEstimator()
        )
    }

    private func day(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func scanResult(
        bucketStart: Date,
        model: String?,
        inputTokens: Int64,
        outputTokens: Int64 = 0,
        sourceKey: String = "/transcripts/a.jsonl",
        byteOffset: Int64 = 4_096
    ) -> LocalScanResult {
        LocalScanResult(
            usage: [
                LocalTokenUsage(
                    bucketStart: bucketStart,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                ),
            ],
            watermarks: [
                LocalScanWatermark(
                    sourceKey: sourceKey,
                    fileSize: byteOffset,
                    fileMTime: Self.now,
                    byteOffset: byteOffset,
                    updatedAt: Self.now
                ),
            ]
        )
    }

    // MARK: - The scan is written as one transaction

    /// The reader emits deltas. Tokens and the resume points that consume them
    /// must land together — `applyLocalScan`, never the two writers separately —
    /// or the bytes between the old and the new watermark are lost for good.
    func testAScanPersistsItsTokensAndItsWatermarksTogether() async throws {
        let (_, ledger) = try makeLedger()
        let result = scanResult(
            bucketStart: day("2024-03-15T00:00:00Z"),
            model: "priced-model",
            inputTokens: 1_000_000
        )
        let coordinator = makeCoordinator(ledger: ledger, scan: { result })

        await coordinator.scanLocalUsage()

        let rows = try ledger.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 1_000_000)

        let watermark = try ledger.fetchLocalScanWatermark(sourceKey: "/transcripts/a.jsonl")
        XCTAssertEqual(watermark?.byteOffset, 4_096)

        XCTAssertNil(coordinator.localScanFailureMessage)
        XCTAssertFalse(coordinator.isScanningLocalUsage)
        XCTAssertEqual(coordinator.localUsageRevision, 1)
    }

    /// A second scan carrying the same day again adds to the stored total rather
    /// than replacing it — the rows are deltas.
    func testASecondScanAccumulatesRatherThanReplacing() async throws {
        let (_, ledger) = try makeLedger()
        let result = scanResult(
            bucketStart: day("2024-03-15T00:00:00Z"),
            model: "priced-model",
            inputTokens: 500
        )
        let coordinator = makeCoordinator(ledger: ledger, scan: { result })

        await coordinator.scanLocalUsage()
        await coordinator.scanLocalUsage()

        let rows = try ledger.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 1_000)
        XCTAssertEqual(coordinator.localUsageRevision, 2)
    }

    func testAFailingScanReportsAndWritesNothing() async throws {
        struct Boom: Error {}
        let (_, ledger) = try makeLedger()
        let coordinator = makeCoordinator(ledger: ledger, scan: { throw Boom() })

        await coordinator.scanLocalUsage()

        XCTAssertEqual(coordinator.localScanFailureMessage, SyncCoordinator.localScanFailedMessage)
        XCTAssertTrue(try ledger.fetchLocalTokenUsage(since: nil).isEmpty)
        XCTAssertEqual(coordinator.localUsageRevision, 0)
        XCTAssertFalse(coordinator.isScanningLocalUsage)
    }

    func testAScanWithoutALedgerRefusesAndSaysSo() async {
        let coordinator = makeCoordinator(ledger: nil, scan: nil)

        await coordinator.scanLocalUsage()

        XCTAssertEqual(
            coordinator.localScanFailureMessage,
            SyncCoordinator.localScanUnavailableMessage
        )
    }

    // MARK: - A scan in flight refuses a second one

    /// The scan is now on a cadence as well as on the dashboard's appearance, so
    /// a tick can arrive while the one-time history rebuild still holds
    /// `LocalHistoryWriteGate`. `isScanningLocalUsage` is set *before* the gate
    /// is awaited, so that tick returns at once instead of parking a second
    /// waiter behind the rebuild. The second call is awaited through an
    /// expectation rather than directly, so losing that guard fails here in two
    /// seconds instead of hanging the suite.
    func testAScanThatArrivesWhileTheGateIsHeldReturnsInsteadOfWaiting() async throws {
        let (_, ledger) = try makeLedger()
        let counter = ScanCounter()
        let result = scanResult(
            bucketStart: day("2024-03-15T00:00:00Z"),
            model: "priced-model",
            inputTokens: 10
        )
        let gate = LocalHistoryWriteGate(rebuildIsOutstanding: true)
        let coordinator = SyncCoordinator(
            ledger: ledger,
            credentials: InMemoryCredentialStore(),
            registry: ProviderAdapterRegistry(),
            localScan: {
                counter.increment()
                return result
            },
            costEstimator: makeEstimator(),
            localHistoryGate: gate
        )

        // Parks on the gate: the rebuild is outstanding and never runs here.
        let held = Task { await coordinator.scanLocalUsage() }
        while !coordinator.isScanningLocalUsage {
            await Task.yield()
        }

        // Returns rather than joining the queue behind the rebuild.
        let returned = expectation(description: "the second scan returned without waiting")
        Task {
            await coordinator.scanLocalUsage()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(counter.value, 0, "neither call may reach the scan while the gate is held")

        // Let the held scan through, so nothing is left parked on the gate.
        _ = await gate.runRebuild { true }
        await held.value
        XCTAssertEqual(counter.value, 1, "exactly one scan was ever waiting to run")
    }

    // MARK: - Statistics

    func testStatisticsAreLimitedToThePeriod() async throws {
        let (_, ledger) = try makeLedger()
        try ledger.applyLocalScan(
            LocalScanResult(
                usage: [
                    LocalTokenUsage(
                        bucketStart: day("2024-03-15T00:00:00Z"),
                        model: "priced-model",
                        inputTokens: 100
                    ),
                    LocalTokenUsage(
                        bucketStart: day("2024-01-01T00:00:00Z"),
                        model: "priced-model",
                        inputTokens: 900
                    ),
                ],
                watermarks: []
            )
        )
        let coordinator = makeCoordinator(ledger: ledger, scan: nil)

        let recent = coordinator.localUsageStatistics(
            since: LocalUsagePeriod.last7Days.since(now: Self.now)
        )
        XCTAssertEqual(recent?.totalTokens, 100)

        let allTime = coordinator.localUsageStatistics(since: nil)
        XCTAssertEqual(allTime?.totalTokens, 1_000)
    }

    /// A model with no price yields tokens but no estimate. Nil, never zero:
    /// zero would read as "this was free".
    func testAnUnpricedModelHasTokensButNoEstimate() async throws {
        let (_, ledger) = try makeLedger()
        try ledger.applyLocalScan(
            LocalScanResult(
                usage: [
                    LocalTokenUsage(
                        bucketStart: day("2024-03-15T00:00:00Z"),
                        model: "model-with-no-price",
                        inputTokens: 100
                    ),
                ],
                watermarks: []
            )
        )
        let coordinator = makeCoordinator(ledger: ledger, scan: nil)

        let statistics = try XCTUnwrap(coordinator.localUsageStatistics(since: nil))
        XCTAssertEqual(statistics.models.count, 1)
        XCTAssertNil(statistics.models.first?.estimatedAmountMicros)
        XCTAssertTrue(statistics.hasUnpricedModels)
        XCTAssertEqual(statistics.totalTokens, 100)
    }

    func testStatisticsWithoutALedgerAreUnavailableRatherThanEmpty() {
        let coordinator = makeCoordinator(ledger: nil, scan: nil)
        XCTAssertNil(coordinator.localUsageStatistics(since: nil))
    }

    // MARK: - The screen's wording

    func testTheEstimateIsNeverPresentedAsAnAmountThatWasCharged() {
        XCTAssertTrue(
            LocalUsageStatistics.estimateDisclaimer.contains("never billed"),
            LocalUsageStatistics.estimateDisclaimer
        )
    }

    func testTheScopeNoteSaysTheFiguresCoverEverySubscriptionTogether() {
        let note = DashboardPresentation.subscriptionScopeNote
        XCTAssertTrue(note.contains("every Claude subscription together"), note)
        XCTAssertTrue(note.contains("cannot be attributed to one"), note)
    }

    func testAnUnpricedRowRendersAsUnpricedRatherThanAsZero() {
        let rendered = DashboardPresentation.amount(micros: nil, currency: nil)
        XCTAssertFalse(rendered.contains("0"), rendered)
        XCTAssertEqual(rendered, "No price on file")
    }
}

/// Counts scans from whichever thread the detached scan task runs on.
private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
