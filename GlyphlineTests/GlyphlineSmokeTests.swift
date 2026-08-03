import XCTest
@testable import Glyphline

final class GlyphlineSmokeTests: XCTestCase {
    func testAppModeDisplayNameIsStable() {
        XCTAssertEqual(AppMode.menuBarOnly.displayName, "Menu Bar")
    }
}
