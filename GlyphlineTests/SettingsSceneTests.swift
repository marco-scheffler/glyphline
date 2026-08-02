import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// Accounts moved out of the dashboard's sidebar and into a tab of the settings
/// window. Two things about that move can break without anything looking wrong,
/// and both are checked here.
@MainActor
final class SettingsSceneTests: XCTestCase {
    /// The settings window has to count as a window the app stays regular for.
    ///
    /// Two failures ride on this one predicate. In `.menuBarOnly` the app is an
    /// accessory, and an accessory app's window never becomes key. And the
    /// app-mode picker lives *in* settings — the dashboard's window sweep closes
    /// every visible window this predicate does not exempt, so without the
    /// exemption switching to Menu Bar closes the window the user is standing in.
    func testTheSettingsWindowKeepsTheAppRegular() {
        XCTAssertTrue(
            AppActivationController.isWindowNeedingRegularApp(
                identifier: AppActivationController.settingsWindowID
            )
        )
        // Prefix, not equality, for the same reason the agentverse window is
        // matched by prefix: AppKit is free to append a counter.
        XCTAssertTrue(
            AppActivationController.isWindowNeedingRegularApp(
                identifier: AppActivationController.settingsWindowID + "-1"
            )
        )
        // The dashboard is still swept, and still demotes the app.
        XCTAssertFalse(
            AppActivationController.isWindowNeedingRegularApp(identifier: "dashboard-AppWindow-1")
        )
    }

    /// The add button used to be a toolbar item. A tab in the settings window has
    /// no toolbar, so a toolbar item there renders nowhere at all — and the one
    /// place it is indispensable is the empty state, where adding an account is
    /// the only thing to do. Hosted off screen and measured, because "the button
    /// is on screen" has no other surface a test can hold.
    func testTheEmptyAccountsListStillCarriesTheAddButton() {
        let bare = height(of: emptyStatePlaceholder)
        let view = height(
            of: AccountsView(accounts: [], ledgerStore: nil)
                .environmentObject(
                    SyncCoordinator(
                        ledger: nil,
                        credentials: KeychainStore(),
                        registry: ProviderAdapterRegistry()
                    )
                )
        )

        XCTAssertGreaterThan(bare, 0)
        // Against the height of the button itself, not merely against zero: the
        // header's padding alone would clear a bare "taller than the list", and
        // a button that renders nowhere would still pass that.
        let button = height(of: addButton)
        XCTAssertGreaterThan(button, 0)
        XCTAssertGreaterThanOrEqual(
            view - bare - AccountsView.headerTopPadding,
            button,
            "the header row with the add button has to be laid out above the empty state"
        )
    }

    private var addButton: some View {
        Button {} label: {
            Label("Add account", systemImage: "person.badge.plus")
        }
    }

    /// The same placeholder `AccountsView` shows, on its own — so the comparison
    /// above is against the list without its header, not against a constant.
    private var emptyStatePlaceholder: some View {
        ContentUnavailableView(
            "No Accounts Yet",
            systemImage: "person.badge.plus",
            description: Text("Add an account to store credentials securely and start tracking usage.")
        )
    }

    private func height(of view: some View, width: CGFloat = 640) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
