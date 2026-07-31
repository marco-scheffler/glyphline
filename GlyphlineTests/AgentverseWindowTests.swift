import AppKit
import SwiftUI
import XCTest
@testable import Glyphline

final class AgentverseWindowTests: XCTestCase {
    /// The interval is a judgement call, but not a free one: below ten seconds a
    /// hard-working session has not moved a car far enough to see and the sweep
    /// is a pure disk cost, and above thirty a watched car stands still long
    /// enough to look like the bug this replaced.
    func testTheRefreshIntervalStaysInTheRangeThatBuysVisibleMotion() {
        XCTAssertGreaterThanOrEqual(AgentverseRefreshSchedule.interval, 10)
        XCTAssertLessThanOrEqual(AgentverseRefreshSchedule.interval, 30)
    }

    /// The whole point of the loop being gated: a window nobody can see must not
    /// walk three thousand transcripts every fifteen seconds.
    func testOnlyAWindowOnScreenSweeps() {
        XCTAssertTrue(AgentverseRefreshSchedule.shouldRun(onScreen: true))
        XCTAssertFalse(AgentverseRefreshSchedule.shouldRun(onScreen: false))
    }

    /// The fix itself. A visible window in an app that is not frontmost is the
    /// case the old `scenePhase == .active` gate got wrong — it is the intended
    /// way to use the map, and `occlusionState` still reports `.visible` there,
    /// so the rule must say yes to it and no to every way of taking the window
    /// off screen.
    func testTheOnScreenRuleFollowsOcclusionAndNotFocus() {
        // Visible, whatever app happens to be frontmost — occlusion carries no
        // focus information at all, which is exactly why it is the right input.
        XCTAssertTrue(WindowVisibility.isOnScreen(isVisible: true, occlusion: .visible))
        // Fully covered by another window, or on a Space that was switched away
        // from: AppKit still lists the window, but no pixel of it reaches a
        // screen.
        XCTAssertFalse(WindowVisibility.isOnScreen(isVisible: true, occlusion: []))
        // Minimised, app-hidden, or closed.
        XCTAssertFalse(WindowVisibility.isOnScreen(isVisible: false, occlusion: .visible))
        XCTAssertFalse(WindowVisibility.isOnScreen(isVisible: false, occlusion: []))
    }

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
