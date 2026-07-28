import XCTest
@testable import Glyphline

final class GlyphlineSmokeTests: XCTestCase {
    func testAppModeDisplayNameIsStable() {
        XCTAssertEqual(AppMode.menuBarAndWindow.displayName, "Both")
    }
}
