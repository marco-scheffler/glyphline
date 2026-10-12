import GRDB
import XCTest
@testable import Glyphline

@MainActor
final class AgentverseCoordinatorTests: XCTestCase {
    private func makeLedger() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func session(_ id: String, at date: Date) -> AgentSession {
        AgentSession(id: id, cwd: "/repo/\(id)", gitBranch: "main",
                     activity: .working, lastActivityAt: date)
    }

    /// Sweeping twice with the session gone quiet in between must leave exactly
    /// one pit-lane row, and it must survive being read back from the ledger.
    func testGoingQuietWritesOneParkedRowThatSurvivesAReload() async throws {
        let ledger = try makeLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scanner = StubScanner(sessions: [session("S1", at: now)])
        let coordinator = AgentverseCoordinator(scanner: scanner, ledger: ledger)

        await coordinator.refresh(now: now)
        XCTAssertEqual(coordinator.onTrack.map(\.id), ["S1"])

        await coordinator.refresh(now: now.addingTimeInterval(70 * 60))

        XCTAssertTrue(coordinator.onTrack.isEmpty)
        XCTAssertEqual(coordinator.parked.map(\.sessionID), ["S1"])
        XCTAssertEqual(try ledger.fetchParkedAgents().map(\.sessionID), ["S1"])

        let reloaded = AgentverseCoordinator(scanner: scanner, ledger: ledger)
        await reloaded.refresh(now: now.addingTimeInterval(80 * 60))
        XCTAssertEqual(reloaded.parked.map(\.sessionID), ["S1"])
    }

    func testDismissingRemovesTheRowAndTheCard() async throws {
        let ledger = try makeLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ledger.saveParkedAgent(
            ParkedAgentSession(sessionID: "S1", cwd: "/repo", gitBranch: nil,
                               subagentCount: 0, lastActivityAt: now, parkedAt: now)
        )
        let coordinator = AgentverseCoordinator(scanner: StubScanner(sessions: []), ledger: ledger)
        await coordinator.refresh(now: now.addingTimeInterval(60))

        coordinator.dismiss(sessionID: "S1")

        XCTAssertTrue(coordinator.parked.isEmpty)
        XCTAssertTrue(try ledger.fetchParkedAgents().isEmpty)
    }

    /// The expiry that actually runs. The rules name the ids past the deadline
    /// and the coordinator deletes them; nothing sweeps the table by date, so
    /// this is the only place the 96 hours can be shown to bite.
    func testAParkedRowPastTheExpiryLeavesTheLedger() async throws {
        let ledger = try makeLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ledger.saveParkedAgent(park("OLD", parkedAgo: 97 * 3600, now: now))
        try ledger.saveParkedAgent(park("FRESH", parkedAgo: 95 * 3600, now: now))
        let coordinator = AgentverseCoordinator(scanner: StubScanner(sessions: []), ledger: ledger)

        await coordinator.refresh(now: now)

        XCTAssertEqual(coordinator.parked.map(\.sessionID), ["FRESH"])
        XCTAssertEqual(try ledger.fetchParkedAgents().map(\.sessionID), ["FRESH"])
    }

    private func park(_ id: String, parkedAgo: TimeInterval, now: Date) -> ParkedAgentSession {
        ParkedAgentSession(
            sessionID: id,
            cwd: "/repo/\(id)",
            gitBranch: nil,
            subagentCount: 0,
            lastActivityAt: now.addingTimeInterval(-parkedAgo - 3600),
            parkedAt: now.addingTimeInterval(-parkedAgo)
        )
    }

    /// The scan walks a directory that may not exist at all. That is a normal
    /// state — no Claude Code on this machine — and must not be a crash.
    func testAFailingScanIsReportedRatherThanThrown() async throws {
        let ledger = try makeLedger()
        let coordinator = AgentverseCoordinator(scanner: FailingScanner(), ledger: ledger)

        await coordinator.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertTrue(coordinator.onTrack.isEmpty)
        XCTAssertNotNil(coordinator.failureMessage)
    }

    /// The odometers come from the coordinator, not from the view: it already
    /// holds the ledger, so the laps and the places on the circuit are read from
    /// one connection and can never disagree.
    func testASweepPublishesTheWorkTokensForTheSessionsItPutOnTrack() async throws {
        let ledger = try makeLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ledger.applyLocalScan(
            LocalScanResult(
                usage: [],
                sessionUsage: [
                    LocalSessionTokenUsage(sessionID: "S1", model: "sonnet",
                                           inputTokens: 600_000,
                                           cacheCreationTokens: 1_000_000,
                                           // Cache reads are not work tokens, so
                                           // this must not reach the odometer.
                                           cacheReadTokens: 9_000_000,
                                           outputTokens: 1_000_000),
                ],
                watermarks: []
            )
        )
        let coordinator = AgentverseCoordinator(
            scanner: StubScanner(sessions: [session("S1", at: now)]),
            ledger: ledger
        )

        await coordinator.refresh(now: now)

        XCTAssertEqual(coordinator.workTokens["S1"], 2_600_000)
    }

    /// What the repeating sweep is for: the odometer a later sweep publishes is
    /// the one on disk at that moment, not the one the opening sweep saw. Without
    /// this the cars are pinned to whatever the window found when it appeared.
    func testASecondSweepPublishesTokensWrittenSinceTheFirst() async throws {
        let ledger = try makeLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = AgentverseCoordinator(
            scanner: StubScanner(sessions: [session("S1", at: now)]),
            ledger: ledger
        )
        try ledger.applyLocalScan(scan(sessionID: "S1", outputTokens: 500_000))

        await coordinator.refresh(now: now)
        XCTAssertEqual(coordinator.workTokens["S1"], 500_000)

        // The store accumulates per session and model, so this is the million
        // tokens the session produced between the two sweeps.
        try ledger.applyLocalScan(scan(sessionID: "S1", outputTokens: 1_000_000))
        await coordinator.refresh(now: now.addingTimeInterval(AgentverseRefreshSchedule.interval))

        XCTAssertEqual(coordinator.workTokens["S1"], 1_500_000)
    }

    /// Three things sweep — the background controller, the dashboard and the map
    /// window — and a sweep suspends while it scans. One arriving in that gap
    /// must not run alongside the first: both would reconcile against the same
    /// previous sweep and write the same rows.
    func testASweepArrivingWhileOneIsInFlightDoesNotScanAgain() async throws {
        let ledger = try makeLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entered = expectation(description: "the first sweep is scanning")
        let scanner = GatedScanner(sessions: [session("S1", at: now)]) { entered.fulfill() }
        let coordinator = AgentverseCoordinator(scanner: scanner, ledger: ledger)

        let first = Task { await coordinator.refresh(now: now) }
        await fulfillment(of: [entered], timeout: 2)
        await coordinator.refresh(now: now)
        scanner.release()
        await first.value

        XCTAssertEqual(scanner.scanCount, 1, "the overlapping sweep must return without scanning")
        XCTAssertEqual(coordinator.onTrack.map(\.id), ["S1"])
    }

    private func scan(sessionID: String, outputTokens: Int64) -> LocalScanResult {
        LocalScanResult(
            usage: [],
            sessionUsage: [
                LocalSessionTokenUsage(sessionID: sessionID, model: "sonnet",
                                       inputTokens: 0, cacheCreationTokens: 0,
                                       cacheReadTokens: 0, outputTokens: outputTokens),
            ],
            watermarks: []
        )
    }

    private struct StubScanner: AgentSessionScanning {
        var sessions: [AgentSession]
        func scan(now: Date) throws -> [AgentSession] { sessions }
    }

    private struct FailingScanner: AgentSessionScanning {
        struct Boom: Error {}
        func scan(now: Date) throws -> [AgentSession] { throw Boom() }
    }

    /// Holds every scan until released, so a test can act while a sweep is in
    /// flight. The wait is bounded: a second scan that should never have started
    /// fails the count rather than hanging the suite.
    private final class GatedScanner: AgentSessionScanning, @unchecked Sendable {
        private let sessions: [AgentSession]
        private let onEnter: @Sendable () -> Void
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _scanCount = 0

        init(sessions: [AgentSession], onEnter: @escaping @Sendable () -> Void) {
            self.sessions = sessions
            self.onEnter = onEnter
        }

        var scanCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _scanCount
        }

        func release() {
            gate.signal()
        }

        func scan(now: Date) throws -> [AgentSession] {
            lock.lock()
            _scanCount += 1
            let isFirst = _scanCount == 1
            lock.unlock()
            if isFirst { onEnter() }
            _ = gate.wait(timeout: .now() + 2)
            return sessions
        }
    }
}
