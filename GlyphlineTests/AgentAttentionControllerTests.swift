import XCTest
@testable import Glyphline

@MainActor
final class AgentAttentionControllerTests: XCTestCase {
    private final class FakeObserver: TranscriptChangeObserving {
        private(set) var isStarted = false
        private var onChange: (@MainActor ([URL]) -> Void)?
        func start(onChange: @escaping @MainActor ([URL]) -> Void) { isStarted = true; self.onChange = onChange }
        func stop() { isStarted = false; onChange = nil }
        func emit(_ urls: [URL]) { onChange?(urls) }
    }

    private struct FixedReader: TranscriptTailReading {
        let tails: [String: TranscriptTail]
        func readTail(at url: URL) throws -> TranscriptTail? { tails[url.path] }
    }

    /// A clock the test moves, read by the controller on every tick.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ now: Date) { _now = now }
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        func advance(_ seconds: TimeInterval) { lock.lock(); _now += seconds; lock.unlock() }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let path = "/p/a/s1.jsonl"

    private func makeSettings() -> AppSettingsStore {
        let suite = "GlyphlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettingsStore(defaults: defaults)
    }

    private func waitingTail(at date: Date) -> TranscriptTail {
        TranscriptTail(sessionID: "S1", isSidechain: false, cwd: "/code/glyphline", gitBranch: nil,
                       timestamp: date, activity: .waitingForYou, aiTitle: "Fix the sweep", slug: nil)
    }

    /// Ticks driven by hand: every call to the injected sleep suspends until
    /// `tick()` resumes it.
    ///
    /// `tick()` waits for the loop to be asleep, wakes it, and returns only once
    /// the loop has gone back to sleep — that is, once the whole tick, notifier
    /// call included, has run. No yield counting.
    private final class ManualTicker: @unchecked Sendable {
        private let lock = NSLock()
        private var sleepers: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []

        @Sendable func sleep(_ seconds: TimeInterval) async throws {
            await withCheckedContinuation { c in
                let waiting = lock.withLock {
                    sleepers.append(c)
                    defer { arrivals = [] }
                    return arrivals
                }
                waiting.forEach { $0.resume() }
            }
            try Task.checkCancellation()
        }

        private func nextSleeper() async {
            await withCheckedContinuation { c in
                let ready = lock.withLock {
                    if sleepers.isEmpty { arrivals.append(c); return false }
                    return true
                }
                if ready { c.resume() }
            }
        }

        private func wake() {
            let w = lock.withLock { defer { sleepers = [] }; return sleepers }
            w.forEach { $0.resume() }
        }

        /// One full tick of a running loop.
        func tick() async {
            await nextSleeper()
            wake()
            await nextSleeper()
        }

        /// Wakes whatever is asleep without waiting for it to sleep again — for
        /// a loop that has been cancelled and will not.
        func wakeWithoutWaiting() { wake() }
    }

    func testAWaitingSessionIsReportedAfterTheDelay() async throws {
        let settings = makeSettings()
        let clock = Clock(t0)
        let ticker = ManualTicker()
        let observer = FakeObserver()
        let notifier = RecordingNotifier()
        let controller = AgentAttentionController(
            settings: settings, observer: observer,
            reader: FixedReader(tails: [path: waitingTail(at: t0)]),
            notifier: notifier, now: { clock.now }, sleepForSeconds: ticker.sleep
        )
        defer { controller.stop() }

        observer.emit([URL(fileURLWithPath: path)])
        await controller.waitForPendingReads()
        clock.advance(2 * 60); await ticker.tick()
        XCTAssertTrue(notifier.waitingBatches.isEmpty, "two minutes is inside the three-minute delay")

        clock.advance(60); await ticker.tick()
        XCTAssertEqual(notifier.waitingBatches.map { $0.map(\.sessionID) }, [["S1"]])
    }

    func testTurningTheSettingOffStopsReports() async throws {
        let settings = makeSettings()
        let clock = Clock(t0)
        let ticker = ManualTicker()
        let observer = FakeObserver()
        let notifier = RecordingNotifier()
        let controller = AgentAttentionController(
            settings: settings, observer: observer,
            reader: FixedReader(tails: [path: waitingTail(at: t0)]),
            notifier: notifier, now: { clock.now }, sleepForSeconds: ticker.sleep
        )
        defer { controller.stop() }

        observer.emit([URL(fileURLWithPath: path)])
        await controller.waitForPendingReads()
        settings.agentWaitingNotificationsEnabled = false
        XCTAssertFalse(observer.isStarted)

        clock.advance(10 * 60); ticker.wakeWithoutWaiting()
        await controller.waitForPendingReads()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(notifier.waitingBatches.isEmpty)
    }

    func testTheDelayFollowsTheSetting() async throws {
        let settings = makeSettings()
        settings.agentWaitingDelayMinutes = 1
        let clock = Clock(t0)
        let ticker = ManualTicker()
        let observer = FakeObserver()
        let notifier = RecordingNotifier()
        let controller = AgentAttentionController(
            settings: settings, observer: observer,
            reader: FixedReader(tails: [path: waitingTail(at: t0)]),
            notifier: notifier, now: { clock.now }, sleepForSeconds: ticker.sleep
        )
        defer { controller.stop() }

        observer.emit([URL(fileURLWithPath: path)])
        await controller.waitForPendingReads()
        clock.advance(60); await ticker.tick()
        XCTAssertEqual(notifier.waitingBatches.count, 1)
    }
}
