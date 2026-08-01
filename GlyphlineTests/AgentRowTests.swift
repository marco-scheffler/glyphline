import XCTest
@testable import Glyphline

final class AgentRowTests: XCTestCase {
    private func session(
        id: String = "S1",
        cwd: String = "/Users/x/coding/Acme-Suite",
        branch: String? = "main",
        activity: AgentActivity = .working,
        subagents: Int = 0,
        aiTitle: String? = nil,
        slug: String? = nil
    ) -> AgentSession {
        AgentSession(id: id, cwd: cwd, gitBranch: branch, activity: activity,
                     lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
                     subagentCount: subagents, aiTitle: aiTitle, slug: slug)
    }

    /// With neither a title nor a slug there is nothing left but the repository,
    /// and the last path component of it — a column 264 px wide cannot show
    /// "/Users/someone/coding/Acme-Suite".
    func testTheTitleFallsBackToTheProjectRatherThanThePath() {
        XCTAssertEqual(AgentRowModel(session: session(), workTokens: 0).title, "Acme-Suite")
    }

    /// The complaint this whole change answers: every session in one checkout
    /// read "Acme-Suite" and nothing said which was which.
    func testTwoSessionsInOneRepositoryGetDifferentLabels() {
        let first = AgentRowModel(
            session: session(id: "S1", aiTitle: "Loga-AD-Sync-Schnittstelle bewerten"),
            workTokens: 0)
        let second = AgentRowModel(
            session: session(id: "S2", aiTitle: "Issue 558 auf Umsetzbarkeit prüfen"),
            workTokens: 0)

        XCTAssertEqual(first.title, "Loga-AD-Sync-Schnittstelle bewerten")
        XCTAssertEqual(second.title, "Issue 558 auf Umsetzbarkeit prüfen")
        XCTAssertNotEqual(first.title, second.title)
    }

    /// The slug carries a session that has not been given a title yet, and it
    /// still differs per session, which is the whole point of the fallback.
    func testASessionWithoutATitleIsNamedByItsSlug() {
        XCTAssertEqual(
            AgentRowModel(session: session(slug: "tidy-toasting-pelican"), workTokens: 0).title,
            "tidy-toasting-pelican")
    }

    /// Titles run past 50 characters where a repository name runs to about 10.
    /// End-truncated, never middle-truncated: two sessions in one PR series
    /// differ in their last words far less often than in their first.
    func testALongTitleIsClippedAtTheEnd() {
        let long = String(repeating: "x", count: 80)
        let title = AgentRowModel(session: session(aiTitle: long), workTokens: 0).title

        XCTAssertEqual(title.count, SessionLabel.sidebarLimit)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertTrue(title.hasPrefix("xxxx"))
    }

    /// The repository has not vanished, it has moved down a line — with the
    /// branch, as the second line always had.
    func testTheSubtitleCarriesTheRepositoryTheBranchAndTheSubagents() {
        let row = AgentRowModel(
            session: session(branch: "feat/x", subagents: 2, aiTitle: "Do the thing"),
            workTokens: 0)

        XCTAssertEqual(row.subtitle, "Acme-Suite · feat/x · +2")
    }

    /// Without a title the first line is already the repository, and repeating
    /// it underneath would say the same word twice.
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

    /// A blank label is worse than a wrong one: the row becomes a diamond and a
    /// number with nothing to click on. Every combination that can reach the
    /// label has to produce something as long as there is a `cwd`.
    func testALabelIsNeverEmptyForASessionThatHasACwd() {
        let titles: [String?] = [nil, "", "   ", "Adminrechte einrichten"]
        let slugs: [String?] = [nil, "", "   ", "wise-questing-axolotl"]

        for title in titles {
            for slug in slugs {
                let row = AgentRowModel(session: session(aiTitle: title, slug: slug),
                                        workTokens: 0)
                XCTAssertFalse(row.title.isEmpty, "title=\(title ?? "nil") slug=\(slug ?? "nil")")
            }
        }
    }

    func testAParkedRowStillShowsItsProject() {
        let row = AgentRowModel(parked: parked(), workTokens: 2_600_000)

        XCTAssertEqual(row.title, "Acme-Suite")
        XCTAssertEqual(row.subtitle, "main")
    }
}
