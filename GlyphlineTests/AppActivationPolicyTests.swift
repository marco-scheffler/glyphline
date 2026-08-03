import AppKit
import XCTest

@testable import Glyphline

/// Which activation policy each mode asks for.
///
/// Tested as arithmetic rather than by driving `NSApp`: setting a real policy in
/// a test process is not a measurement, it is a side effect on the process the
/// suite is running in — `LocalizedLayoutTests` pins the policy to `.prohibited`
/// precisely so that nothing appears on screen during a run.
///
/// The guard that goes with this — only calling `setActivationPolicy` when the
/// policy actually differs — is deliberately not covered here for the same
/// reason. It reads `NSApp`, and a test that exercised it would be changing the
/// suite's own process. What is held here is the decision it is handed.
final class AppActivationPolicyTests: XCTestCase {
    /// The menu-bar-only mode is the only one that gives up the Dock icon.
    func testOnlyMenuBarOnlyAsksForAccessory() {
        XCTAssertEqual(
            AppActivationController.policy(for: .menuBarOnly, hasWindowNeedingRegularApp: false),
            .accessory
        )
        XCTAssertEqual(
            AppActivationController.policy(for: .menuBarAndWindow, hasWindowNeedingRegularApp: false),
            .regular
        )
        XCTAssertEqual(
            AppActivationController.policy(for: .windowOnly, hasWindowNeedingRegularApp: false),
            .regular
        )
    }

    /// A window that needs a regular app overrides the mode.
    ///
    /// The agentverse and settings windows open in every mode and never write
    /// `appMode`. Without this the mode's own policy would demote the app to
    /// `.accessory` under a window that is still on screen, taking away its Dock
    /// icon and every way back to it.
    func testAWindowOnScreenKeepsTheAppRegularEvenInMenuBarOnly() {
        XCTAssertEqual(
            AppActivationController.policy(for: .menuBarOnly, hasWindowNeedingRegularApp: true),
            .regular
        )
    }
}
