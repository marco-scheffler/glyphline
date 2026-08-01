import XCTest
@testable import Glyphline

final class AgentRowTests: XCTestCase {
    private func session(
        cwd: String = "/Users/x/coding/Acme-Suite",
        branch: String? = "main",
        activity: AgentActivity = .working,
        subagents: Int = 0
    ) -> AgentSession {
        AgentSession(id: "S1", cwd: cwd, gitBranch: branch, activity: activity,
                     lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
                     subagentCount: subagents)
    }

    /// The last path component, not the whole path. A column 264 px wide cannot
    /// show "/Users/someone/coding/Private/glyphline" and the leading part is
    /// the same for every row anyway.
    func testTheTitleIsTheProjectRatherThanThePath() {
        XCTAssertEqual(AgentRowModel(session: session(), workTokens: 0).title, "Acme-Suite")
    }

    func testTheSubtitleCarriesTheBranchAndTheSubagents() {
        let row = AgentRowModel(session: session(branch: "feat/x", subagents: 2), workTokens: 0)

        XCTAssertEqual(row.subtitle, "feat/x · +2")
    }

    func testASessionWithoutABranchSaysNothingAboutOne() {
        XCTAssertEqual(AgentRowModel(session: session(branch: nil), workTokens: 0).subtitle, "")
    }

    func testTheStateSaysWhichOfTheTwoItIs() {
        XCTAssertEqual(AgentRowModel(session: session(activity: .working), workTokens: 0).stateText,
                       "working")
        XCTAssertEqual(AgentRowModel(session: session(activity: .waitingForYou), workTokens: 0).stateText,
                       "waiting")
    }

    private func parked(cwd: String = "/Users/x/coding/Acme-Suite",
                        branch: String? = "main") -> ParkedAgentSession {
        ParkedAgentSession(sessionID: "S2", cwd: cwd, gitBranch: branch, subagentCount: 0,
                           lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
                           parkedAt: Date(timeIntervalSince1970: 1_800_003_600))
    }

    /// A session in the pit lane needs a row of its own, or the only way to
    /// dismiss one is to wait out the 96 hours.
    func testAParkedSessionReadsAsParkedRatherThanIdle() {
        XCTAssertEqual(AgentRowModel(parked: parked(), workTokens: 0).stateText, "parked")
        XCTAssertEqual(AgentRowModel(parked: parked(), workTokens: 0).state, .parked)
    }

    /// The token figure was taken as an argument and thrown away for a whole
    /// task. Catches it being ignored again, and catches the number being
    /// localised — a decimal comma in a monospaced column beside a decimal
    /// point is a bug that only appears on a German machine.
    func testTheRowShowsTheWorkItHasDone() {
        XCTAssertEqual(AgentRowModel(session: session(), workTokens: 36_140_000).tokenText,
                       "36.1M")
        XCTAssertEqual(AgentRowModel(session: session(), workTokens: 0).tokenText, "0.0M")
        XCTAssertEqual(AgentRowModel.millions(1_500_000), "1.5M")
    }

    /// The swatch is what ties a row to a figure in the room. It has to be the
    /// same colour every launch, which is why it is FNV-1a and not `hashValue`.
    func testTheSwatchIsStableForOneSessionAndComesFromThePalette() {
        let first = AgentRowModel(session: session(), workTokens: 0)
        let again = AgentRowModel(session: session(branch: "feat/other"), workTokens: 99)

        XCTAssertEqual(first.swatch, again.swatch)
        XCTAssertEqual(first.swatch, SessionPalette.forSession("S1").color)
    }

    func testAParkedRowStillShowsItsProject() {
        let row = AgentRowModel(parked: parked(), workTokens: 2_600_000)

        XCTAssertEqual(row.title, "Acme-Suite")
        XCTAssertEqual(row.subtitle, "main")
    }
}
