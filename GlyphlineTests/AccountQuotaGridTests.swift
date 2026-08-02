import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The quota grid, measured rather than eyeballed.
///
/// Two of these are pure — how many columns are worth trying, and how the
/// accounts split into rows. The rest host the real view off screen in an
/// `NSHostingView` and read its laid-out height back, which is the only part of
/// "the cards fill the row" a test can actually hold: a row of three that fits
/// in the pane is one card tall, and the same three in a narrow pane are three.
///
/// What this cannot see: the width of an individual card. SwiftUI does not
/// expose its cards as separate `NSView`s, so the even split within a row and
/// the equal heights inside it are inferred from the row's own height and from
/// the frames the cards are given, not measured per card.
@MainActor
final class AccountQuotaGridTests: XCTestCase {
    // MARK: Fixtures

    private func window(_ kind: RateWindowKind, used: Double) -> QuotaCardModel {
        QuotaCardModel(
            kind: kind,
            usedFraction: used,
            headroomFraction: 1 - used,
            usedPercent: Int(used * 100),
            headroomPercent: Int((1 - used) * 100),
            usageText: "\(Int(used * 100))% used",
            headroomText: "\(Int((1 - used) * 100))% left",
            pacePosition: 0.5,
            paceText: "on track",
            state: .ok
        )
    }

    private func account(_ name: String, windows: Int) -> AccountQuotaCardModel {
        let kinds: [RateWindowKind] = [.rollingFiveHours, .weekly]
        return AccountQuotaCardModel(
            id: UUID(),
            accountName: name,
            providerName: "Claude",
            cards: (0..<windows).map { window(kinds[$0], used: 0.4) },
            message: nil
        )
    }

    /// The laid-out height of a view given exactly `width` points.
    private func height(of view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Wide enough for three cards side by side, given the 300-point minimum
    /// plus each card's own 16-point padding on both sides.
    private let threeColumnWidth: CGFloat = 1_100
    /// Room for one card and no more.
    private let oneColumnWidth: CGFloat = 400

    // MARK: The pure parts

    /// Widest first, and never more columns than there are accounts — three
    /// accounts must not be offered a four-column layout to stretch into.
    func testTheColumnCandidatesAreWidestFirstAndCappedAtTheAccountCount() {
        XCTAssertEqual(AccountQuotaGrid.columnCandidates(accountCount: 3), [3, 2, 1])
        XCTAssertEqual(AccountQuotaGrid.columnCandidates(accountCount: 5), [5, 4, 3, 2, 1])
        XCTAssertEqual(AccountQuotaGrid.columnCandidates(accountCount: 1), [1])
        XCTAssertEqual(AccountQuotaGrid.columnCandidates(accountCount: 0), [1])
    }

    /// Five accounts in three columns are 3 + 2, not 3 + 3 with a card dropped
    /// and not one long column.
    func testTheAccountsSplitIntoRowsOfAtMostTheColumnCount() {
        let accounts = (1...5).map { account("Account \($0)", windows: 1) }

        let rows = AccountQuotaGrid.rows(of: accounts, columns: 3)
        XCTAssertEqual(rows.map(\.count), [3, 2])
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), accounts.map(\.id))

        XCTAssertEqual(AccountQuotaGrid.rows(of: accounts, columns: 1).map(\.count), [1, 1, 1, 1, 1])
        // A zero column count would divide by nothing and hang the stride.
        XCTAssertEqual(AccountQuotaGrid.rows(of: accounts, columns: 0).map(\.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(AccountQuotaGrid.rows(of: [], columns: 3).count, 0)
    }

    // MARK: The measured parts

    /// The user's three accounts, in a pane with room for them: one row, so the
    /// cards are beside each other and share the width rather than stacking in
    /// a 300-point column with the rest of the pane left empty.
    func testThreeAccountsSitInOneRowWhenThePaneIsWideEnough() {
        let accounts = (1...3).map { account("Account \($0)", windows: 1) }
        let one = height(of: AccountQuotaGrid(accounts: [accounts[0]]), width: threeColumnWidth)
        let three = height(of: AccountQuotaGrid(accounts: accounts), width: threeColumnWidth)

        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(three, one, accuracy: 1, "three cards in one row are one card tall")
    }

    /// The same three accounts in a narrow pane reflow to three rows instead of
    /// being squeezed below a legible width.
    func testThreeAccountsReflowToThreeRowsWhenTheWindowNarrows() {
        let accounts = (1...3).map { account("Account \($0)", windows: 1) }
        let one = height(of: AccountQuotaGrid(accounts: [accounts[0]]), width: oneColumnWidth)
        let three = height(of: AccountQuotaGrid(accounts: accounts), width: oneColumnWidth)

        XCTAssertEqual(
            three,
            one * 3 + AccountQuotaGrid.spacing * 2,
            accuracy: 1,
            "three stacked cards plus the two gaps between them"
        )
    }

    /// Adding accounts costs height only once the width is used up: five
    /// accounts in a three-column pane are two rows, not five.
    func testFiveAccountsCostTwoRowsRatherThanFive() {
        let accounts = (1...5).map { account("Account \($0)", windows: 1) }
        let one = height(of: AccountQuotaGrid(accounts: [accounts[0]]), width: threeColumnWidth)
        let five = height(of: AccountQuotaGrid(accounts: accounts), width: threeColumnWidth)

        XCTAssertEqual(five, one * 2 + AccountQuotaGrid.spacing, accuracy: 1)
    }

    /// A row is as tall as the account with the most to say, and the account
    /// with less does not shrink it — that is the height its neighbour's glass
    /// has to reach too.
    func testARowTakesTheHeightOfItsTallestCard() {
        let short = account("Short", windows: 1)
        let tall = account("Tall", windows: 2)
        let tallAlone = height(of: AccountQuotaGrid(accounts: [tall]), width: threeColumnWidth)
        let shortAlone = height(of: AccountQuotaGrid(accounts: [short]), width: threeColumnWidth)
        let row = height(of: AccountQuotaGrid(accounts: [short, tall]), width: threeColumnWidth)

        XCTAssertGreaterThan(tallAlone, shortAlone)
        XCTAssertEqual(row, tallAlone, accuracy: 1)
    }
}
