import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The account sections of the menu bar panel.
///
/// With three accounts stacked, the panel was one unbroken column of headings
/// and bars: which bar belonged to which account was carried by a gap the same
/// size as the gap *inside* a section. A separator is the thing that makes the
/// grouping visible, and whether one is actually drawn is not something the type
/// system or a snapshot of the model can answer — it only exists once something
/// has laid the stack out.
@MainActor
final class MenuBarQuotaListTests: XCTestCase {
    // MARK: Fixtures

    private func row(_ id: String, _ label: String, remaining: Double) -> QuotaBarRow {
        QuotaBarRow(
            id: id,
            label: label,
            remainingFraction: remaining,
            detail: "\(Int(remaining * 100))% left",
            asOf: nil,
            severity: .normal
        )
    }

    /// Two windows, which is what every real account here reports.
    private func group(_ name: String) -> QuotaBarGroup {
        QuotaBarGroup(
            id: UUID(),
            displayName: name,
            rows: [
                row("5h", "5h", remaining: 0.98),
                row("week", "Week", remaining: 0.66),
            ]
        )
    }

    /// The laid-out height at the panel's real content width — the separator's
    /// cost only means anything against a stack that is being laid out the way
    /// the panel lays it out.
    private func height(_ groups: [QuotaBarGroup]) -> CGFloat {
        let width = MenuBarView.panelWidth - 2 * MenuBarView.panelPadding
        let host = NSHostingView(
            rootView: AnyView(MenuBarQuotaList(groups: groups).frame(width: width))
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: The separator

    /// Two accounts cost more than two sections and one gap.
    ///
    /// That difference is the separator. Stated as an inequality against the
    /// stack's own spacing rather than as "a divider is 1 point tall": the height
    /// of a `Divider` belongs to AppKit and is not this project's to assert, but
    /// *something* being there is.
    ///
    /// Would catch: dropping the separator, which puts the distance between two
    /// accounts back to exactly one `sectionSpacing`.
    func testAccountsAreSeparatedByMoreThanAGap() {
        let one = height([group("A")])
        let two = height([group("A"), group("B")])

        XCTAssertGreaterThan(one, 0, "a single section laid out to nothing")
        XCTAssertGreaterThan(
            two - one,
            one + MenuBarQuotaList.sectionSpacing,
            "nothing but spacing sits between two accounts: two measured \(two), one \(one)"
        )
    }

    /// And every account after the first costs the same, so the third is
    /// separated the way the second is rather than the rule applying once.
    func testEveryFurtherAccountIsSeparatedTheSameWay() {
        let one = height([group("A")])
        let two = height([group("A"), group("B")])
        let three = height([group("A"), group("B"), group("C")])

        XCTAssertEqual(
            three - two,
            two - one,
            accuracy: 0.5,
            "the third account is spaced differently from the second"
        )
    }

    /// A single account gets no separator — one above the first section would
    /// read as a rule under the panel's title.
    func testASingleAccountCarriesNoSeparator() {
        let one = height([group("A")])
        let bare = NSHostingView(
            rootView: AnyView(
                VStack(alignment: .leading, spacing: MenuBarQuotaList.sectionSpacing) {
                    MenuBarQuotaList(groups: [group("A")])
                }
                .frame(width: MenuBarView.panelWidth - 2 * MenuBarView.panelPadding)
            )
        )
        bare.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            bare.fittingSize.height,
            one,
            accuracy: 0.5,
            "a lone account is taller than its own section, so something was drawn around it"
        )
    }
}
