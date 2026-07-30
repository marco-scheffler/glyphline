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

    /// The scan walks a directory that may not exist at all. That is a normal
    /// state — no Claude Code on this machine — and must not be a crash.
    func testAFailingScanIsReportedRatherThanThrown() async throws {
        let ledger = try makeLedger()
        let coordinator = AgentverseCoordinator(scanner: FailingScanner(), ledger: ledger)

        await coordinator.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertTrue(coordinator.onTrack.isEmpty)
        XCTAssertNotNil(coordinator.failureMessage)
    }

    private struct StubScanner: AgentSessionScanning {
        var sessions: [AgentSession]
        func scan(now: Date) throws -> [AgentSession] { sessions }
    }

    private struct FailingScanner: AgentSessionScanning {
        struct Boom: Error {}
        func scan(now: Date) throws -> [AgentSession] { throw Boom() }
    }
}
