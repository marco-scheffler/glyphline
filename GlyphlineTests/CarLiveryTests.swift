import XCTest
@testable import Glyphline

final class CarLiveryTests: XCTestCase {
    /// A session must keep its car. A random livery would make the map
    /// unmemorable, which is most of what a livery is for.
    func testASessionAlwaysGetsTheSameLivery() {
        let first = CarLivery.forSession("019fa0ad-422e-79e0-b0d5-c4605371f1d2")
        let again = CarLivery.forSession("019fa0ad-422e-79e0-b0d5-c4605371f1d2")

        XCTAssertEqual(first.name, again.name)
    }

    func testDifferentSessionsSpreadAcrossTheLiveries() {
        let names = Set((0 ..< 200).map { CarLivery.forSession("session-\($0)").name })

        XCTAssertEqual(names.count, CarLivery.all.count,
                       "every livery should be reachable across a realistic number of sessions")
    }

    func testThereAreNineLiveriesAndTheyAreNamed() {
        XCTAssertEqual(CarLivery.all.count, 9)
        XCTAssertFalse(CarLivery.all.contains { $0.name.isEmpty })
    }
}
