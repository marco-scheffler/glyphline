import GRDB
import XCTest
@testable import Glyphline

final class AgentverseParkedStoreTests: XCTestCase {
    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func parked(
        _ id: String,
        parkedAt: Date,
        lastActivityAt: Date? = nil
    ) -> ParkedAgentSession {
        ParkedAgentSession(
            sessionID: id,
            cwd: "/repo/\(id)",
            gitBranch: "main",
            subagentCount: 2,
            lastActivityAt: lastActivityAt ?? parkedAt.addingTimeInterval(-3600),
            parkedAt: parkedAt
        )
    }

    func testParkedSessionsRoundTrip() throws {
        let store = try makeStore()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveParkedAgent(parked("S1", parkedAt: at))

        let rows = try store.fetchParkedAgents()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sessionID, "S1")
        XCTAssertEqual(rows[0].cwd, "/repo/S1")
        XCTAssertEqual(rows[0].gitBranch, "main")
        XCTAssertEqual(rows[0].subagentCount, 2)
        XCTAssertEqual(rows[0].parkedAt, at)
    }

    /// Parking the same session twice must not produce two rows — a session that
    /// wakes, parks, wakes and parks again is one card.
    func testParkingTheSameSessionTwiceReplacesTheRow() throws {
        let store = try makeStore()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveParkedAgent(parked("S1", parkedAt: first))
        try store.saveParkedAgent(parked("S1", parkedAt: first.addingTimeInterval(7200)))

        let rows = try store.fetchParkedAgents()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].parkedAt, first.addingTimeInterval(7200))
    }

    /// Dismissal is this delete. Nothing else records it, because a row that is
    /// gone cannot come back on the next launch.
    func testDeletingRemovesTheSession() throws {
        let store = try makeStore()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveParkedAgent(parked("S1", parkedAt: at))
        try store.saveParkedAgent(parked("S2", parkedAt: at))

        try store.deleteParkedAgent(sessionID: "S1")

        XCTAssertEqual(try store.fetchParkedAgents().map(\.sessionID), ["S2"])
    }

    func testNewestParkFirst() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveParkedAgent(parked("OLD", parkedAt: now.addingTimeInterval(-7200)))
        try store.saveParkedAgent(parked("NEW", parkedAt: now))

        XCTAssertEqual(try store.fetchParkedAgents().map(\.sessionID), ["NEW", "OLD"])
    }

    /// The title is the whole point of the v12 columns: it has to reach the
    /// database and come back, not merely exist on the struct.
    func testAParkedSessionCarriesItsTitleThroughTheDatabase() throws {
        let store = try makeStore()
        var row = parked("S1", parkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        row.aiTitle = "Issue 558 auf Umsetzbarkeit prüfen"
        row.slug = "tidy-toasting-pelican"
        try store.saveParkedAgent(row)

        let stored = try XCTUnwrap(try store.fetchParkedAgents().first)

        XCTAssertEqual(stored.aiTitle, "Issue 558 auf Umsetzbarkeit prüfen")
        XCTAssertEqual(stored.slug, "tidy-toasting-pelican")
        XCTAssertEqual(stored.displayTitle, "Issue 558 auf Umsetzbarkeit prüfen")
    }

    /// The bug this task exists for: one checkout, two parked sessions, and
    /// before v12 both read "repo".
    func testTwoParkedSessionsFromOneRepositoryReadDifferently() throws {
        let store = try makeStore()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var first = parked("S1", parkedAt: at)
        first.cwd = "/Users/x/coding/Acme-Suite"
        first.aiTitle = "Issue 558 auf Umsetzbarkeit prüfen"
        var second = parked("S2", parkedAt: at)
        second.cwd = "/Users/x/coding/Acme-Suite"
        second.aiTitle = "Release 2.4 vorbereiten"
        try store.saveParkedAgent(first)
        try store.saveParkedAgent(second)

        let labels = try store.fetchParkedAgents().map(\.displayTitle)

        XCTAssertEqual(Set(labels),
                       ["Issue 558 auf Umsetzbarkeit prüfen", "Release 2.4 vorbereiten"])
        XCTAssertEqual(Set(labels).count, 2, "same checkout, two different labels")
    }
}
