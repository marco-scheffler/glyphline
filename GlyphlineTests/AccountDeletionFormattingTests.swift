import XCTest
@testable import Glyphline

final class AccountDeletionFormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(
        samples: Int = 0,
        earliest: Date? = nil
    ) -> AccountDeletionSummary {
        AccountDeletionSummary(
            rateWindowSampleCount: samples,
            earliestRateWindowObservedAt: earliest,
            costSnapshotCount: 0,
            usageSnapshotCount: 0
        )
    }

    func testTheTitleNamesTheAccount() {
        XCTAssertEqual(AccountDeletionFormatting.title(displayName: "Max #1"), #"Delete "Max #1"?"#)
    }

    func testTheSamplesAreCalledUnrecoverable() {
        let body = AccountDeletionFormatting.body(
            summary: summary(samples: 148, earliest: now),
            source: .claudeWebSession
        )
        // Both the number and the date are built with the same call the
        // formatter uses. A hardcoded "148" and "12 Feb 2026" would pass in
        // en_US and fail on this project's own machine, which runs de_DE:
        // `.number` groups with a period there, and the date reorders.
        XCTAssertTrue(body.contains("\(148.formatted(.number)) rate window samples"))
        XCTAssertTrue(body.contains(now.formatted(date: .numeric, time: .omitted)))
        // And not the abbreviated date it used to carry: that one spells the
        // month, so on a German system it printed "Okt." inside this English
        // sentence. Numerals follow the system; words follow the app.
        XCTAssertFalse(body.contains(now.formatted(date: .abbreviated, time: .omitted)))
        XCTAssertTrue(body.lowercased().contains("cannot be recovered"))
    }

    func testASingleSampleReadsAsOne() {
        let body = AccountDeletionFormatting.body(
            summary: summary(samples: 1, earliest: now),
            source: .claudeWebSession
        )
        XCTAssertTrue(body.contains("1 rate window sample "))
        XCTAssertFalse(body.contains("samples"))
    }

    /// Nothing to lose, so no warning about losing it. A dialog that cries about
    /// unrecoverable history when there is none teaches the user to skip reading it.
    func testNoSamplesMeansNoUnrecoverableWarning() {
        let body = AccountDeletionFormatting.body(
            summary: summary(samples: 0),
            source: .claudeWebSession
        )
        XCTAssertFalse(body.lowercased().contains("cannot be recovered"))
        XCTAssertFalse(body.contains("rate window"))
    }

    /// The snapshot tables are gone, so the dialog may not offer to rebuild
    /// anything: everything it names is unrecoverable.
    func testTheBodyNeverNamesSnapshotsOrOffersARebuild() {
        let body = AccountDeletionFormatting.body(
            summary: summary(samples: 12, earliest: now),
            source: .claudeWebSession
        )
        XCTAssertFalse(body.lowercased().contains("snapshot"))
        XCTAssertFalse(body.lowercased().contains("rebuilt"))
    }

    func testAWebSessionAccountIsToldItsSignInGoes() {
        let body = AccountDeletionFormatting.body(summary: summary(), source: .claudeWebSession)
        XCTAssertTrue(body.contains("claude.ai sign-in"))
    }

    func testOtherSourcesAreNotToldAboutASignIn() {
        for source in [AccountSource.credential, .localLogs] {
            let body = AccountDeletionFormatting.body(summary: summary(), source: source)
            XCTAssertFalse(body.contains("claude.ai sign-in"))
        }
    }

    func testAnEmptyAccountStillSaysSomething() {
        let body = AccountDeletionFormatting.body(summary: summary(), source: .localLogs)
        XCTAssertFalse(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
