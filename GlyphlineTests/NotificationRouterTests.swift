import XCTest
@testable import Glyphline

@MainActor
final class NotificationRouterTests: XCTestCase {
    func testEachCategoryOpensItsSurface() {
        XCTAssertEqual(NotificationRouter.destination(forCategory: "agents-waiting"), .agentverse)
        XCTAssertEqual(NotificationRouter.destination(forCategory: "quota-runway"), .dashboard)
        XCTAssertEqual(NotificationRouter.destination(forCategory: "session-expired"), .dashboard)
        XCTAssertNil(NotificationRouter.destination(forCategory: "something-else"))
    }

    /// Consumed once: two listeners (menu bar label and an open window) must not
    /// open the same window twice.
    func testADestinationIsConsumedOnce() {
        let router = NotificationRouter()
        router.route(category: "agents-waiting")
        XCTAssertEqual(router.consume(), .agentverse)
        XCTAssertNil(router.consume())
    }
}
