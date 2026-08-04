import XCTest
@testable import Glyphline

/// The local scan used to run at most once per process, from a view that the
/// default mode never shows. It now lives in `LocalScanScheduleController`, and
/// these tests pin the four things that can break there quietly: it scans at
/// launch, it scans again on the interval, it follows the interval the user
/// changes rather than the value being replaced, and it keeps running when
/// network syncing is switched off.
///
/// No real sleeps: `Sleeper` returns from the first *n* sleeps immediately and
/// parks in a cancellable `Task.sleep` after that, so the loop stops exactly
/// where each test wants it.
@MainActor
final class LocalScanScheduleControllerTests: XCTestCase {
    private func makeSettings(intervalMinutes: Int) -> AppSettingsStore {
        let suiteName = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        settings.syncIntervalMinutes = intervalMinutes
        return settings
    }

    /// Constructing the controller subscribes, and the subscription's first
    /// emission starts the loop, which scans before it sleeps at all. A
    /// controller that only scanned after its first interval would leave the
    /// figures stale for half an hour after every launch.
    func testConstructingTheControllerScansAtOnce() async {
        let settings = makeSettings(intervalMinutes: 15)
        let sleeper = Sleeper(immediateReturns: 0)
        let scans = ScanRecorder()
        let scanned = expectation(description: "scanned at launch")
        scans.onScan = { if $0 == 1 { scanned.fulfill() } }

        let controller = LocalScanScheduleController(
            settings: settings,
            scan: { scans.record() },
            sleepForSeconds: sleeper.sleep
        )

        await fulfillment(of: [scanned], timeout: 2)
        withExtendedLifetime(controller) {
            XCTAssertEqual(
                scans.count, 1,
                "the loop must scan before its first sleep, or nothing is read for a whole interval after launch"
            )
            XCTAssertEqual(controller.currentIntervalSeconds, 900)
        }
    }

    /// The cadence itself, and the interval it waits: the sleep between the two
    /// scans has to be the user's 15 minutes in seconds. An off-by-sixty here is
    /// invisible outside production.
    func testItScansAgainAfterTheIntervalElapses() async {
        let settings = makeSettings(intervalMinutes: 15)
        let sleeper = Sleeper(immediateReturns: 1)
        let scans = ScanRecorder()
        let scannedTwice = expectation(description: "scanned twice")
        scans.onScan = { if $0 == 2 { scannedTwice.fulfill() } }

        let controller = LocalScanScheduleController(
            settings: settings,
            scan: { scans.record() },
            sleepForSeconds: sleeper.sleep
        )

        await fulfillment(of: [scannedTwice], timeout: 2)
        withExtendedLifetime(controller) {
            XCTAssertEqual(
                sleeper.intervals.first, 900,
                "the wait between two scans is the user's sync interval in seconds"
            )
        }
    }

    /// The regression `SyncScheduleControllerTests` exists for, in this file's
    /// terms. `@Published` publishes on `willSet`, so a sink that read
    /// `settings.syncIntervalMinutes` instead of the value Combine passed it
    /// would re-time the loop to the interval being replaced — 900 again — and
    /// every other test here would stay green.
    func testChangingTheIntervalRetimesTheCadenceUsingTheNewValue() async {
        let settings = makeSettings(intervalMinutes: 15)
        let sleeper = Sleeper(immediateReturns: 0)
        let scans = ScanRecorder()
        let scannedOnce = expectation(description: "scanned at launch")
        scans.onScan = { if $0 == 1 { scannedOnce.fulfill() } }

        let controller = LocalScanScheduleController(
            settings: settings,
            scan: { scans.record() },
            sleepForSeconds: sleeper.sleep
        )
        await fulfillment(of: [scannedOnce], timeout: 2)
        XCTAssertEqual(sleeper.intervals, [900])

        let scannedAgain = expectation(description: "scanned after re-timing")
        scans.onScan = { if $0 == 2 { scannedAgain.fulfill() } }
        settings.syncIntervalMinutes = 45
        await fulfillment(of: [scannedAgain], timeout: 2)

        withExtendedLifetime(controller) {
            XCTAssertEqual(controller.currentIntervalSeconds, 2_700)
            XCTAssertEqual(
                sleeper.intervals.last, 2_700,
                "the loop must wait the interval Combine handed the sink, not the one still in the store"
            )
        }
    }

    /// A product decision, kept honest by a test that goes red if someone
    /// "tidies" the scan into the sync toggle later: `automaticSyncEnabled` is
    /// about network calls against a provider. A local file read has no quota and
    /// no credential consequences, and nothing else refreshes these figures — so
    /// switching network syncing off must not freeze the local usage screen.
    func testTurningAutomaticSyncOffDoesNotStopTheLocalScan() async {
        let settings = makeSettings(intervalMinutes: 15)
        settings.automaticSyncEnabled = true
        let sleeper = Sleeper(immediateReturns: 0)
        let scans = ScanRecorder()
        let scannedOnce = expectation(description: "scanned at launch")
        scans.onScan = { if $0 == 1 { scannedOnce.fulfill() } }

        let controller = LocalScanScheduleController(
            settings: settings,
            scan: { scans.record() },
            sleepForSeconds: sleeper.sleep
        )
        await fulfillment(of: [scannedOnce], timeout: 2)

        settings.automaticSyncEnabled = false

        // Still live afterwards: a further interval change re-times it and scans
        // again, which a controller gated on the toggle could not do.
        let scannedAgain = expectation(description: "scanned after the toggle went off")
        scans.onScan = { if $0 == 2 { scannedAgain.fulfill() } }
        settings.syncIntervalMinutes = 45
        await fulfillment(of: [scannedAgain], timeout: 2)

        withExtendedLifetime(controller) {
            XCTAssertEqual(
                controller.currentIntervalSeconds, 2_700,
                "the local scan must keep its cadence when network syncing is switched off"
            )
        }
    }

    /// The loop awaits the scan before sleeping again, so a scan still in flight
    /// cannot be joined by a second one. That is what keeps a tick during the
    /// one-time history rebuild from parking a second waiter on
    /// `LocalHistoryWriteGate` — a controller that fired each tick off into its
    /// own detached task would queue them up behind the rebuild instead.
    func testATickDuringAScanDoesNotStartASecondScan() async {
        let settings = makeSettings(intervalMinutes: 15)
        // Every sleep returns at once: if the loop were not awaiting the scan,
        // it would spin and scan repeatedly.
        let sleeper = Sleeper(immediateReturns: Int.max)
        let scans = ScanRecorder()
        let started = expectation(description: "first scan started")
        scans.onScan = { if $0 == 1 { started.fulfill() } }

        let controller = LocalScanScheduleController(
            settings: settings,
            scan: {
                scans.record()
                // Never returns on its own; cancelled with the loop when the
                // controller goes away at the end of the test.
                try? await Task.sleep(for: .seconds(3_600))
            },
            sleepForSeconds: sleeper.sleep
        )
        await fulfillment(of: [started], timeout: 2)

        for _ in 0..<200 {
            await Task.yield()
        }

        withExtendedLifetime(controller) {
            XCTAssertEqual(
                scans.count, 1,
                "the loop must await the scan in flight rather than start another one on the next tick"
            )
        }
    }
}

/// Counts scans and reports each count, from whichever thread runs them.
private final class ScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _onScan: ((Int) -> Void)?

    var onScan: ((Int) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onScan
        }
        set {
            lock.lock()
            _onScan = newValue
            lock.unlock()
        }
    }

    func record() {
        lock.lock()
        _count += 1
        let count = _count
        let handler = _onScan
        lock.unlock()
        handler?(count)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}

/// Records every requested sleep. The first `immediateReturns` of them return at
/// once; the rest park in a cancellable sleep, so the loop stops without the test
/// waiting on real time.
private final class Sleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _intervals: [TimeInterval] = []
    private var remaining: Int

    init(immediateReturns: Int) {
        remaining = immediateReturns
    }

    var intervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _intervals
    }

    @Sendable
    func sleep(_ seconds: TimeInterval) async throws {
        guard !record(seconds) else { return }
        try await Task.sleep(for: .seconds(3_600))
    }

    /// Synchronous on purpose: `NSLock` may not be taken across a suspension
    /// point, so the bookkeeping happens here and the awaiting happens above.
    private func record(_ seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _intervals.append(seconds)
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
