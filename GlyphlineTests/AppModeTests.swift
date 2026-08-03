import XCTest
@testable import Glyphline

final class AppModeTests: XCTestCase {
    func testThereAreExactlyTwoModes() {
        XCTAssertEqual(AppMode.allCases, [.menuBarOnly, .windowOnly])
    }

    func testAppModeLabels() {
        XCTAssertEqual(AppMode.menuBarOnly.displayName, "Menu Bar")
        XCTAssertEqual(AppMode.windowOnly.displayName, "Window")
    }

    /// The menu bar extra is the only thing the mode still decides about
    /// presence. The dashboard is openable in both.
    func testOnlyMenuBarOnlyCarriesTheMenuBarExtra() {
        XCTAssertTrue(AppMode.menuBarOnly.showsMenuBarExtra)
        XCTAssertFalse(AppMode.windowOnly.showsMenuBarExtra)
    }

    /// What is left of the removed `menuBarAndWindow` case: whether the window
    /// comes up on its own. `windowOnly` has no menu bar extra, so without this
    /// it would launch with no surface at all.
    func testOnlyWindowOnlyOpensTheDashboardAtLaunch() {
        XCTAssertTrue(AppMode.windowOnly.opensDashboardAtLaunch)
        XCTAssertFalse(AppMode.menuBarOnly.opensDashboardAtLaunch)
    }
}
