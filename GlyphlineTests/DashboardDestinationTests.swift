import XCTest
@testable import Glyphline

@MainActor
final class DashboardDestinationTests: XCTestCase {
    func testSidebarOffersExactlyThreeDestinationsInOrder() {
        XCTAssertEqual(DashboardDestination.allCases, [.dashboard, .accounts, .settings])
        XCTAssertEqual(DashboardDestination.allCases.map(\.title), ["Dashboard", "Accounts", "Settings"])
    }

    /// The removed cases must not come back through the raw value either: a
    /// selection stored under an older build names `overview`, `statistics` or
    /// `addAccount`, and those have to stay unresolvable.
    func testRemovedDestinationsDoNotResolveFromTheirStoredRawValues() {
        XCTAssertNil(DashboardDestination(rawValue: "overview"))
        XCTAssertNil(DashboardDestination(rawValue: "statistics"))
        XCTAssertNil(DashboardDestination(rawValue: "addAccount"))
    }

    /// The whole point of resolving through the failable initialiser: an
    /// out-of-date stored selection lands on the dashboard instead of trapping.
    func testUnknownStoredSelectionFallsBackToDashboard() {
        XCTAssertEqual(DashboardDestination.resolved("statistics"), .dashboard)
        XCTAssertEqual(DashboardDestination.resolved(nil), .dashboard)
        XCTAssertEqual(DashboardDestination.resolved("accounts"), .accounts)
    }
}
