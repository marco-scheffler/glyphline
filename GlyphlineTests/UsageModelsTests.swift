import XCTest
@testable import Glyphline

final class UsageModelsTests: XCTestCase {
    func testProviderDisplayNames() {
        XCTAssertEqual(ProviderID.openAI.displayName, "OpenAI")
        XCTAssertEqual(ProviderID.cursor.displayName, "Cursor")
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
    }

    func testDataQualityOrdering() {
        XCTAssertTrue(DataQuality.exact.isBetterThan(.estimated))
        XCTAssertTrue(DataQuality.partial.isBetterThan(.unavailable))
    }
}
