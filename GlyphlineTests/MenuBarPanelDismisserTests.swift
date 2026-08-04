import AppKit
import XCTest

@testable import Glyphline

/// Which window the menu bar panel's window buttons are allowed to close.
///
/// Tested as arithmetic rather than against real windows, for the same reason
/// `AppActivationPolicyTests` is: closing an `NSWindow` in a test process is not
/// a measurement but a side effect on the process the suite runs in, and the
/// suite pins itself to `.prohibited` so that a run puts nothing on screen.
/// What is held here is the decision `close(_:)` is handed.
///
/// The stakes are asymmetric, and that is what this covers. Failing to close the
/// panel leaves it hanging open — the reported bug. Closing the wrong window
/// destroys the dashboard, the map or settings out from under the user, which is
/// worse. So every one of the app's own windows is named here explicitly.
final class MenuBarPanelDismisserTests: XCTestCase {
    /// The panel itself: no identifier at all, and not the settings window. This
    /// is the case the fix exists for — if it ever answers false, the bug is back.
    func testAnUnidentifiedKeyWindowMayBeClosed() {
        XCTAssertTrue(
            MenuBarPanelDismisser.mayClose(identifier: nil, isClaimedSettingsWindow: false)
        )
    }

    /// The dashboard. SwiftUI appends its own counter to the scene id, so the
    /// real identifier is a prefix match rather than an equal one.
    func testTheDashboardWindowIsNeverClosed() {
        XCTAssertFalse(
            MenuBarPanelDismisser.mayClose(
                identifier: AppMode.dashboardWindowID,
                isClaimedSettingsWindow: false
            )
        )
        XCTAssertFalse(
            MenuBarPanelDismisser.mayClose(
                identifier: "\(AppMode.dashboardWindowID)-AppWindow-1",
                isClaimedSettingsWindow: false
            )
        )
    }

    /// The map, which the Agentverse button opens — the same button row, so it
    /// is the window most likely to be key when the second button is pressed.
    func testTheAgentverseWindowIsNeverClosed() {
        XCTAssertFalse(
            MenuBarPanelDismisser.mayClose(
                identifier: "\(AppMode.agentverseWindowID)-AppWindow-1",
                isClaimedSettingsWindow: false
            )
        )
    }

    /// Settings, by the identifier SwiftUI gives its own window.
    func testTheSettingsWindowIsNeverClosedByIdentifier() {
        XCTAssertFalse(
            MenuBarPanelDismisser.mayClose(
                identifier: AppActivationController.settingsWindowID,
                isClaimedSettingsWindow: false
            )
        )
    }

    /// And settings again by its claim, which is the half that survives Apple
    /// renaming that internal identifier string.
    func testAClaimedSettingsWindowIsNeverClosedEvenWithoutItsIdentifier() {
        XCTAssertFalse(
            MenuBarPanelDismisser.mayClose(identifier: nil, isClaimedSettingsWindow: true)
        )
    }
}
