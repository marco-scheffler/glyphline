import XCTest
@testable import Glyphline

final class AgentverseWindowTests: XCTestCase {
    /// The two windows must not share an id, or `openWindow` raises whichever
    /// SwiftUI happens to have registered first and the map opens the dashboard.
    func testTheWindowIdsAreDistinct() {
        XCTAssertNotEqual(AppMode.agentverseWindowID, AppMode.dashboardWindowID)
        XCTAssertFalse(AppMode.agentverseWindowID.isEmpty)
    }

    /// The coordinator is created by the App, off the main actor's isolation, so
    /// its initialiser has to be callable from there. If this stops compiling,
    /// `GlyphlineApp` cannot own it — and an agentverse coordinator owned by the
    /// window forgets, every opening, whom the last sweep had on track, which
    /// means nothing ever parks.
    func testTheCoordinatorCanBeBuiltOutsideTheMainActor() {
        let build: @Sendable () -> AgentverseCoordinator = {
            AgentverseCoordinator(ledger: nil)
        }
        _ = build
    }

    /// The rule that keeps the app `.regular` and keeps `closeVisibleWindows()`
    /// from destroying the map. The identifier it matches was read off a built
    /// app: SwiftUI names the window `agentverse-AppWindow-1`, the scene id plus
    /// its own counter — hence a prefix and not an equality. A predicate that
    /// silently matched nothing would look exactly like the bug still being there.
    func testOnlyTheAgentverseWindowKeepsTheAppRegular() {
        XCTAssertTrue(
            AppActivationController.isWindowNeedingRegularApp(identifier: "agentverse-AppWindow-1")
        )
        XCTAssertTrue(
            AppActivationController.isWindowNeedingRegularApp(identifier: AppMode.agentverseWindowID)
        )
        XCTAssertFalse(
            AppActivationController.isWindowNeedingRegularApp(identifier: "dashboard-AppWindow-1")
        )
        XCTAssertFalse(AppActivationController.isWindowNeedingRegularApp(identifier: nil))
    }
}
