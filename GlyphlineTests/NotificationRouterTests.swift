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

    /// The signal comes after the value is stored: a listener consuming inside
    /// it gets the destination, and the router is empty afterwards.
    func testADeliveryFindsItsDestinationStored() {
        let router = NotificationRouter()
        var consumed: [NotificationDestination?] = []
        let subscription = router.deliveries.sink { consumed.append(router.consume()) }
        router.route(category: "agents-waiting")
        XCTAssertEqual(consumed, [.agentverse])
        XCTAssertNil(router.pending)
        subscription.cancel()
    }

    /// Two live listeners: exactly one opens.
    func testTwoListenersOpenOnce() {
        let router = NotificationRouter()
        var consumed: [NotificationDestination?] = []
        let first = router.deliveries.sink { consumed.append(router.consume()) }
        let second = router.deliveries.sink { consumed.append(router.consume()) }
        router.route(category: "quota-runway")
        XCTAssertEqual(consumed.compactMap { $0 }, [.dashboard])
        XCTAssertEqual(consumed.count, 2)
        first.cancel()
        second.cancel()
    }

    /// A second click on the same category opens again.
    func testTheSameCategoryDeliversTwice() {
        let router = NotificationRouter()
        var consumed: [NotificationDestination?] = []
        let subscription = router.deliveries.sink { consumed.append(router.consume()) }
        router.route(category: "quota-runway")
        router.route(category: "quota-runway")
        XCTAssertEqual(consumed, [.dashboard, .dashboard])
        subscription.cancel()
    }
}
