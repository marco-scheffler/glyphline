import XCTest
@testable import Glyphline

final class AccountDeletionFormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(
        samples: Int = 0,
        earliest: Date? = nil,
        costs: Int = 0,
        usage: Int = 0
    ) -> AccountDeletionSummary {
        AccountDeletionSummary(
            rateWindowSampleCount: samples,
            earliestRateWindowObservedAt: earliest,
            costSnapshotCount: costs,
            usageSnapshotCount: usage
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
            summary: summary(samples: 0, costs: 12),
            source: .claudeWebSession
        )
        XCTAssertFalse(body.lowercased().contains("cannot be recovered"))
        XCTAssertFalse(body.contains("rate window"))
    }

    func testTheCostHistoryIsCalledRebuildable() {
        let body = AccountDeletionFormatting.body(
            summary: summary(costs: 3_412, usage: 3_400),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(3_412.formatted(.number)) cost snapshots"))
        XCTAssertTrue(body.lowercased().contains("rebuilt"))
    }

    /// "1 cost snapshots" in the app's only irreversible dialog. The number comes
    /// from `.formatted(.number)` here as everywhere else in this file: a literal
    /// "1" happens to be locale-proof, a literal "3.412" is not, and the two must
    /// not be written differently.
    func testASingleCostSnapshotReadsAsOne() {
        let body = AccountDeletionFormatting.body(
            summary: summary(costs: 1),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(1.formatted(.number)) cost snapshot."))
        XCTAssertFalse(body.contains("cost snapshots"))
        // The pronoun agrees with it, or the fix only moves the mistake along.
        XCTAssertTrue(body.contains("This can be rebuilt"))
        XCTAssertFalse(body.contains("These can be rebuilt"))
    }

    func testASingleUsageSnapshotReadsAsOne() {
        let body = AccountDeletionFormatting.body(
            summary: summary(usage: 1),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(1.formatted(.number)) usage snapshot."))
        XCTAssertFalse(body.contains("usage snapshots"))
        XCTAssertTrue(body.contains("This can be rebuilt"))
    }

    /// Two counts of one each are still two things, so the pronoun is plural even
    /// though neither noun is.
    func testOneOfEachIsStillPlural() {
        let body = AccountDeletionFormatting.body(
            summary: summary(costs: 1, usage: 1),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(1.formatted(.number)) cost snapshot and \(1.formatted(.number)) usage snapshot."))
        XCTAssertTrue(body.contains("These can be rebuilt"))
    }

    func testSeveralSnapshotsStayPlural() {
        let body = AccountDeletionFormatting.body(
            summary: summary(costs: 0, usage: 2),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(2.formatted(.number)) usage snapshots"))
        XCTAssertTrue(body.contains("These can be rebuilt"))
    }

    func testAZeroUsageCountIsNotNamed() {
        let body = AccountDeletionFormatting.body(
            summary: summary(costs: 12, usage: 0),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(12.formatted(.number)) cost snapshots"))
        XCTAssertFalse(body.contains("usage snapshots"))
    }

    func testAZeroCostCountIsNotNamed() {
        let body = AccountDeletionFormatting.body(
            summary: summary(costs: 0, usage: 9),
            source: .localLogs
        )
        XCTAssertTrue(body.contains("\(9.formatted(.number)) usage snapshots"))
        XCTAssertFalse(body.contains("cost snapshots"))
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
