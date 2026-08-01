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

    func testAParkedRowStillShowsItsProject() {
        let row = AgentRowModel(parked: parked(), workTokens: 2_600_000)

        XCTAssertEqual(row.title, "Acme-Suite")
        XCTAssertEqual(row.subtitle, "main")
    }
}
