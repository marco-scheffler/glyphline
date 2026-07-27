import XCTest
@testable import Glyphline

final class AppModeTests: XCTestCase {
    func testAppModeLabels() {
        XCTAssertEqual(AppMode.menuBarOnly.displayName, "Menu Bar")
        XCTAssertEqual(AppMode.windowOnly.displayName, "Window")
        XCTAssertEqual(AppMode.menuBarAndWindow.displayName, "Both")
    }
}
