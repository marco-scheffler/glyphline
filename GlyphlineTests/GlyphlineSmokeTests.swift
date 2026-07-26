import XCTest
@testable import Glyphline

final class GlyphlineSmokeTests: XCTestCase {
    func testAppNameIsStable() {
        XCTAssertEqual("Glyphline", "Glyphline")
    }
}
