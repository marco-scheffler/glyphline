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
    /// In `.menuBarOnly` the app is an accessory, and an accessory app's window
    /// never becomes key. The app-mode picker lives *in* settings, so without
    /// this the window the user is standing in while switching to Menu Bar would
    /// be the one window the app was no longer regular for.
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
        // The dashboard now keeps the app regular too — there is no window
        // sweep left for it to be exempt from, only the activation policy.
        XCTAssertTrue(
            AppActivationController.isWindowNeedingRegularApp(identifier: "dashboard-AppWindow-1")
        )
    }

    /// The identifier above is SwiftUI's internal name for its settings window,
    /// not API, and a major release is where such a name changes — silently, with
    /// no test that would notice. So the window also claims itself, and that
    /// claim has to be enough on its own.
    ///
    /// The window here carries a deliberately foreign identifier: it stands in
    /// for the release where Apple renamed theirs.
    func testAClaimedWindowKeepsTheAppRegularWhateverItIsCalled() {
        let renamed = NSWindow()
        renamed.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_SomethingElse")

        XCTAssertFalse(
            AppActivationController.isWindowNeedingRegularApp(renamed),
            "an unclaimed window with an unknown identifier does not keep the app regular"
        )

        AppActivationController.claimSettingsWindow(renamed)
        XCTAssertTrue(AppActivationController.isWindowNeedingRegularApp(renamed))

        // The claim is about one window, not about a shape of window: a second
        // one does not inherit it, even carrying the same foreign identifier —
        // which names none of the app's scenes, so the claim is the only thing
        // that could answer for either of them.
        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_SomethingElse")
        XCTAssertFalse(AppActivationController.isWindowNeedingRegularApp(other))
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
