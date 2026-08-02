import AppKit
import os
import SwiftUI
import XCTest

@testable import Glyphline

/// The dashboard's summary row: Spend, Agents and Model Mix, which have to end at
/// the same line.
///
/// Two commits have claimed this measurement in their message and committed no
/// probe with it — 136/70/92 before and 136/136/136 after in one, 148/148/148 in
/// the other. A figure that lives only in a commit message reads as verified and
/// regresses in silence, which is the same class of problem as an assertion that
/// cannot fail. So it is measured here instead.
///
/// Measured, not eyeballed and not driven: the overview is laid out in an
/// off-screen `NSHostingView` with the activation policy left at `.prohibited`,
/// so nothing appears on screen and no GUI is touched.
@MainActor
final class DashboardSummaryRowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The test bundle's host must not come forward. Nothing below needs a
        // window at all.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// The dashboard's minimum window width, which is the width the tiles are
    /// tightest at and so the one worth pinning.
    private static let paneWidth: CGFloat = 980

    /// The height every tile in the row was laid out at, in row order.
    private func tileHeights() -> [CGFloat] {
        let box = HeightBox()
        let sync = SyncCoordinator(ledger: nil, credentials: KeychainStore(),
                                   registry: ProviderAdapterRegistry())
        let agentverse = AgentverseCoordinator(ledger: nil)
        let host = NSHostingView(
            rootView: AnyView(
                DashboardOverview(
                    accountSummaries: [],
                    loadError: nil,
                    syncFailureMessage: nil,
                    openAgentverse: {}
                )
                .environmentObject(sync)
                .environmentObject(agentverse)
                .environment(\.summaryTileHeightReport) { index, height in
                    box.record(height, at: index)
                }
                // Width only, deliberately. Giving the host a definite height
                // would hand the ScrollView a finite proposal it does not have
                // on the dashboard, and that is precisely the condition
                // `b5b8e39`'s `fixedSize` exists to survive.
                .frame(width: Self.paneWidth)
            )
        )
        host.layoutSubtreeIfNeeded()
        return box.ordered()
    }

    /// The property both commits claimed and neither held.
    ///
    /// Would catch: `maxHeight: .infinity` going missing from any one tile.
    /// Removing it from Model Mix gives 83/83/68 and names the tile.
    ///
    /// What it would *not* catch, said out loud rather than left to be
    /// discovered: removing `.fixedSize(horizontal: false, vertical: true)` from
    /// the row leaves this green. That was tried, with the host given a width and
    /// no height so the ScrollView had no finite proposal to pass on — the case
    /// `b5b8e39` wrote the modifier for — and the row still equalised. An
    /// `NSHostingView` sized from `fittingSize` resolves the ideal height either
    /// way. So the row's other half is held by the app, not by this file.
    func testTheThreeSummaryTilesShareOneHeight() {
        let heights = tileHeights()
        XCTAssertEqual(heights.count, 3, "all three tiles have to report: \(heights)")
        for (index, height) in heights.enumerated() {
            XCTAssertGreaterThan(height, 0, "tile \(index) laid out to nothing")
            XCTAssertEqual(height, heights[0], accuracy: 0.5,
                           "tile \(index) is \(height) against tile 0's \(heights[0]): \(heights)")
        }
    }

    /// The height itself, pinned.
    ///
    /// This is the empty state — no accounts, no scanned usage, no sessions — and
    /// it is the one the probe can reach, because the tiles' figures arrive from
    /// `.task`s that an off-screen layout never runs. It is also the state with
    /// the widest natural spread between the three tiles, so it is the case most
    /// likely to end ragged.
    ///
    /// Would catch: a tile growing or losing a line without anybody noticing —
    /// the row's height is what pushes the chart down the page.
    ///
    /// The number is not the 148 of `02d971b`. The deployment target was raised
    /// to macOS 26 in `7cd7c09` and the cards took real `glassEffect` in place of
    /// the hand-built material, which carries its own padding; the row measures
    /// what it measures now, and this pins today's value rather than yesterday's
    /// claim.
    func testTheEmptyStateRowIsTheHeightItIs() {
        XCTAssertEqual(tileHeights()[0], Self.emptyStateTileHeight, accuracy: 0.5)
    }

    /// Measured, not chosen. See `testTheEmptyStateRowIsTheHeightItIs`.
    private static let emptyStateTileHeight: CGFloat = 83
}

/// Somewhere for the probe to put what it measured. A lock rather than a plain
/// mutable class: the report is `@Sendable`, and this repo takes no
/// `@unchecked Sendable` to get around that.
private final class HeightBox: Sendable {
    private let state = OSAllocatedUnfairLock<[Int: CGFloat]>(initialState: [:])

    func record(_ height: CGFloat, at index: Int) {
        state.withLock { $0[index] = height }
    }

    func ordered() -> [CGFloat] {
        state.withLock { heights in
            heights.keys.sorted().compactMap { heights[$0] }
        }
    }
}
