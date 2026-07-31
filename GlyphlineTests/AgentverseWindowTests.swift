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
}
