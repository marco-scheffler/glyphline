import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The gap between the accounts header and the first card, measured rather than
/// eyeballed.
///
/// The distinction this holds is not "is there a gap" — there was one before,
/// bought with `.padding(.vertical, 16)` on the stack *inside* the `ScrollView`.
/// Padding inside a scroll view is part of the scrolled document and moves out
/// of sight as soon as the list is scrolled, leaving the first visible card
/// flush against the header. So what is measured here is where the gap lives:
/// how far below the header row the scroll view's own frame begins. That
/// distance is fixed by the layout and cannot scroll away.
@MainActor
final class AccountsListSpacingTests: XCTestCase {
    private func account(_ name: String) -> AccountUsageSummary {
        AccountUsageSummary(
            account: Account(
                id: UUID(),
                providerID: .claude,
                displayName: name,
                credentialReference: "keychain://glyphline/\(name)",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                isEnabled: true
            ),
            capabilities: nil,
            billingPeriod: nil,
            latestSyncRun: nil,
            inputTokens: 0,
            outputTokens: 0,
            requestCount: nil,
            actualAmountMicros: nil,
            estimatedAmountMicros: nil,
            displayCurrency: nil,
            dataQuality: .exact
        )
    }

    private func coordinator() -> SyncCoordinator {
        SyncCoordinator(ledger: nil, credentials: KeychainStore(), registry: ProviderAdapterRegistry())
    }

    private let paneWidth: CGFloat = 640
    private let paneHeight: CGFloat = 520

    /// The scroll view has to start at least a header gap below the header row,
    /// so that the gap belongs to the layout and not to the scrolled content.
    func testTheScrollViewStartsAGapBelowTheHeaderRow() throws {
        let view = AccountsView(accounts: [account("Work"), account("Personal")], ledgerStore: nil)
        let host = NSHostingView(
            rootView: AnyView(
                view
                    .environmentObject(coordinator())
                    .frame(width: paneWidth, height: paneHeight)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: paneHeight)
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            Self.firstScrollView(in: host),
            "the populated accounts list is a ScrollView; without one there is nothing to measure"
        )
        let scrollTop = Self.distanceFromTop(of: scrollView, in: host)

        // The header row on its own, at the same width — its own top padding
        // included, its gap below it deliberately not.
        let headerHost = NSHostingView(rootView: AnyView(view.header.frame(width: paneWidth)))
        headerHost.layoutSubtreeIfNeeded()
        let headerHeight = headerHost.fittingSize.height
        XCTAssertGreaterThan(headerHeight, AccountsView.headerTopPadding)

        XCTAssertGreaterThanOrEqual(
            scrollTop - headerHeight,
            AccountsView.headerBottomPadding,
            "the gap above the first card has to sit outside the scroll view, or it scrolls away"
        )
    }

    /// And the gap is not paid for twice: a header gap plus the old content
    /// padding would push the first card 32 points down while the list is at the
    /// top. The scroll view's document is exactly its cards and the spacing
    /// between them, with nothing added above.
    func testTheGapIsNotAlsoPaidForInsideTheScrollView() {
        let one = AccountsView(accounts: [account("Work")], ledgerStore: nil)
        let two = AccountsView(accounts: [account("Work"), account("Personal")], ledgerStore: nil)

        let oneHeight = height(of: one)
        let twoHeight = height(of: two)
        let card = twoHeight - oneHeight - Self.cardSpacing

        XCTAssertGreaterThan(card, 0)
        // One card, its spacing-free top, and the bottom padding the list keeps.
        XCTAssertEqual(
            oneHeight,
            headerBlockHeight(of: one) + card + Self.listBottomPadding,
            accuracy: 1,
            "nothing but the header's own gap sits above the first card"
        )
    }

    /// The spacing between two cards, as the list declares it.
    private static let cardSpacing: CGFloat = 16
    /// What the list keeps below the last card.
    private static let listBottomPadding: CGFloat = 16

    private func headerBlockHeight(of view: AccountsView) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.header.frame(width: paneWidth)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height + AccountsView.headerBottomPadding
    }

    private func height(of view: AccountsView) -> CGFloat {
        let host = NSHostingView(
            rootView: AnyView(
                view
                    .environmentObject(coordinator())
                    .frame(width: paneWidth)
            )
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// AppKit views are not flipped by default, so "how far from the top" is not
    /// simply the frame's origin.
    private static func distanceFromTop(of view: NSView, in host: NSView) -> CGFloat {
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
