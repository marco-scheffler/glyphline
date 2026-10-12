import Combine
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

    /// A second click on the same category must open again, not be swallowed
    /// because the value did not change.
    func testTheSameCategoryRoutesAgainAfterAConsume() {
        let router = NotificationRouter()
        router.route(category: "quota-runway")
        XCTAssertEqual(router.consume(), .dashboard)
        router.route(category: "quota-runway")
        XCTAssertEqual(router.consume(), .dashboard)
    }

    /// A root that mounts after the click still sees the destination.
    func testARouteBeforeAnySubscriberIsDeliveredOnSubscription() {
        let router = NotificationRouter()
        router.route(category: "agents-waiting")
        let delivered = expectation(description: "pending destination delivered")
        let subscription = router.$pending.compactMap { $0 }.sink { destination in
            XCTAssertEqual(destination, .agentverse)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 1)
        subscription.cancel()
    }
}
