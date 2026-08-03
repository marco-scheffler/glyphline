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
    /// The mode alone no longer decides. `windowOnly` is a regular app whether
    /// or not a window happens to be open — its Dock icon is the only way back
    /// to it, since it carries no menu bar extra.
    func testWindowOnlyIsAlwaysRegular() {
        XCTAssertEqual(
            AppActivationController.policy(for: .windowOnly, hasWindowNeedingRegularApp: false),
            .regular
        )
        XCTAssertEqual(
            AppActivationController.policy(for: .windowOnly, hasWindowNeedingRegularApp: true),
            .regular
        )
    }

    /// The default mode gives up the Dock icon exactly when nothing is on screen.
    func testMenuBarOnlyIsAccessoryOnlyWithNoWindowOpen() {
        XCTAssertEqual(
            AppActivationController.policy(for: .menuBarOnly, hasWindowNeedingRegularApp: false),
            .accessory
        )
        XCTAssertEqual(
            AppActivationController.policy(for: .menuBarOnly, hasWindowNeedingRegularApp: true),
            .regular
        )
    }
}
