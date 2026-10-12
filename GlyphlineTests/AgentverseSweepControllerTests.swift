import XCTest
@testable import Glyphline

/// The Agentverse used to be swept only by the dashboard and the map window, so
/// in the default menu bar mode a session could start and go quiet without ever
/// being seen, and never reach the pit lane. These tests pin the controller that
/// sweeps regardless: it sweeps at launch, it sweeps again on its interval, and
/// that interval is short enough that no session goes unseen.
///
/// No real sleeps: `Sleeper` returns from the first *n* sleeps immediately and
/// parks in a cancellable `Task.sleep` after that.
@MainActor
final class AgentverseSweepControllerTests: XCTestCase {
    /// The launch sweep is what gives the second sweep something to compare
    /// against. Without it the first session to go quiet after launch could not
    /// park until a full interval later.
    func testConstructingTheControllerSweepsAtOnce() async {
        let sleeper = Sleeper(immediateReturns: 0)
        let sweeps = SweepRecorder()
        let swept = expectation(description: "swept at launch")
        sweeps.onSweep = { if $0 == 1 { swept.fulfill() } }

        let controller = AgentverseSweepController(
            sweep: { sweeps.record() },
            sleepForSeconds: sleeper.sleep
        )

        await fulfillment(of: [swept], timeout: 2)
        withExtendedLifetime(controller) {
            XCTAssertEqual(sweeps.count, 1)
        }
    }

    func testItSweepsAgainAfterTheIntervalElapses() async {
        let sleeper = Sleeper(immediateReturns: 1)
        let sweeps = SweepRecorder()
        let sweptTwice = expectation(description: "swept twice")
        sweeps.onSweep = { if $0 == 2 { sweptTwice.fulfill() } }

        let controller = AgentverseSweepController(
            sweep: { sweeps.record() },
            sleepForSeconds: sleeper.sleep
        )

        await fulfillment(of: [sweptTwice], timeout: 2)
        withExtendedLifetime(controller) {
            XCTAssertEqual(sleeper.intervals.first, AgentverseSweepController.interval)
        }
    }

    /// The whole point of the cadence. A session is on track for
    /// `AgentSessionScanner.horizon` after its last write; an interval at or
    /// above that lets a session start and go quiet between two sweeps, and it
    /// would vanish instead of parking — the bug this controller exists for.
    func testTheIntervalIsShorterThanTheTimeASessionStaysOnTrack() {
        XCTAssertLessThan(AgentverseSweepController.interval, AgentSessionScanner.horizon)
    }
}

/// Counts sweeps and reports the count, whichever thread records them.
private final class SweepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _onSweep: ((Int) -> Void)?

    var onSweep: ((Int) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onSweep
        }
        set {
            lock.lock()
            _onSweep = newValue
            lock.unlock()
        }
    }

    func record() {
        lock.lock()
        _count += 1
        let count = _count
        let handler = _onSweep
        lock.unlock()
        handler?(count)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}

/// Records every requested sleep. The first `immediateReturns` return at once;
/// the rest park in a cancellable sleep, so the loop stops without the test
/// waiting.
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
    /// point.
    private func record(_ seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _intervals.append(seconds)
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
