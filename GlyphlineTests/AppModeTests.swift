import XCTest
@testable import Glyphline

final class AppModeTests: XCTestCase {
    func testAppModeLabels() {
        XCTAssertEqual(AppMode.menuBarOnly.displayName, "Menu Bar")
        XCTAssertEqual(AppMode.windowOnly.displayName, "Window")
        XCTAssertEqual(AppMode.menuBarAndWindow.displayName, "Both")
    }

    func testAppModePresentationCapabilities() {
        XCTAssertTrue(AppMode.menuBarOnly.showsMenuBarExtra)
        XCTAssertFalse(AppMode.menuBarOnly.showsDashboardWindow)

        XCTAssertFalse(AppMode.windowOnly.showsMenuBarExtra)
        XCTAssertTrue(AppMode.windowOnly.showsDashboardWindow)

        XCTAssertTrue(AppMode.menuBarAndWindow.showsMenuBarExtra)
        XCTAssertTrue(AppMode.menuBarAndWindow.showsDashboardWindow)
    }

    func testWindowModeTransitionRequiresDashboardReopenWhenLeavingMenuBarOnly() {
        XCTAssertTrue(AppMode.windowOnly.requiresDashboardOpen(afterTransitioningFrom: .menuBarOnly))
        XCTAssertTrue(AppMode.menuBarAndWindow.requiresDashboardOpen(afterTransitioningFrom: .menuBarOnly))
        XCTAssertFalse(AppMode.menuBarOnly.requiresDashboardOpen(afterTransitioningFrom: .menuBarAndWindow))
        XCTAssertFalse(AppMode.menuBarAndWindow.requiresDashboardOpen(afterTransitioningFrom: .windowOnly))
    }
}
