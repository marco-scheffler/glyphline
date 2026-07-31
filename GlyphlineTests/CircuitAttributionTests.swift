import XCTest
@testable import Glyphline

/// The credit is asserted rather than trusted to a view. Over 95% of the bundled
/// circuit data is OpenStreetMap under ODbL, not the MIT geometry it is easy to
/// mistake it for, and a licence that goes unnamed because someone reworded a
/// view is the kind of omission nobody notices until it matters.
final class CircuitAttributionTests: XCTestCase {
    func testEverySourceOfTheBundledDataIsNamed() {
        let text = CircuitAttribution.lines.joined(separator: "\n")

        XCTAssertTrue(text.contains("OpenStreetMap"), "the ODbL source must be named")
        XCTAssertTrue(text.contains("ODbL"), "the licence must be named, not only the project")
        XCTAssertTrue(text.contains("Bacinger"), "the MIT geometry must be credited")
        XCTAssertTrue(text.contains("MIT"))
        XCTAssertTrue(text.contains("Mapzen"), "the elevation tiles must be credited")
    }

    func testThereIsSomethingToShow() {
        XCTAssertFalse(CircuitAttribution.lines.isEmpty)
    }
}
