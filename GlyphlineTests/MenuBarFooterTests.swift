import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The menu bar panel's footer row.
///
/// In `.menuBarOnly` the app runs as an accessory with no app menu, so ⌘, has
/// nothing to hang off and this row is the only way into settings. That makes
/// two things worth holding: that the row is there, and that it still fits.
@MainActor
final class MenuBarFooterTests: XCTestCase {
    private func footer() -> some View {
        MenuBarFooter(openDashboard: {}, openAgentverse: {}, refresh: {})
    }

    /// A menu bar panel has a fixed width and clips whatever does not fit,
    /// silently and from the trailing edge — which is where Quit is. Adding a
    /// fourth control to the row is exactly the change that overflows it, and
    /// nothing else in the app would report it.
    func testTheFooterFitsInsideThePanel() {
        let host = NSHostingView(rootView: AnyView(footer()))
        host.layoutSubtreeIfNeeded()
        let available = MenuBarView.panelWidth - 2 * MenuBarView.panelPadding

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertLessThanOrEqual(
            host.fittingSize.width,
            available,
            "the footer row has to fit the panel's \(MenuBarView.panelWidth) points"
        )
    }

    /// The settings entry itself. `SettingsLink` renders as a control of its own,
    /// so a row without it is measurably narrower — which is the only handle a
    /// test has on "the way into settings is present", short of driving the menu.
    func testTheFooterCarriesTheSettingsEntry() {
        let withLink = NSHostingView(rootView: AnyView(footer()))
        withLink.layoutSubtreeIfNeeded()

        let withoutLink = NSHostingView(
            rootView: AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button("Dashboard") {}
                        Button("Agentverse") {}
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Button("Refresh") {}
                        Spacer(minLength: 0)
                        Button("Quit") {}
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            )
        )
        withoutLink.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            withLink.fittingSize.width,
            withoutLink.fittingSize.width,
            "the footer has one control more than the four it had before settings"
        )
    }
}
