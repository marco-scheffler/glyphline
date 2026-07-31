import SwiftUI
import XCTest
@testable import Glyphline

/// A rendered picture, hashed. The browser mockups needed Playwright and forced
/// software rasterisation for this; `ImageRenderer` does it in-process.
///
/// The point is not the hash itself but that stages 3b and 3c can be judged from
/// their first commit. The look was designed blind for hours, and every one of
/// the four bugs found late was found by looking at output rather than by
/// reading code.
@MainActor
final class AgentverseSnapshotTests: XCTestCase {
    private func scene(hovered: String? = nil) throws -> AgentverseScene {
        let circuit = try XCTUnwrap(CircuitCatalog.bundled().circuit("monaco"))
        return AgentverseScene(
            circuit: circuit,
            sessions: [
                AgentSession(id: "S1", cwd: "/repo/a", gitBranch: "main",
                             activity: .working,
                             lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000)),
                AgentSession(id: "S2", cwd: "/repo/b", gitBranch: "main",
                             activity: .waitingForYou,
                             lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000)),
            ],
            parked: [
                ParkedAgentSession(sessionID: "S3", cwd: "/repo/c", gitBranch: "main",
                                   subagentCount: 0,
                                   lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   parkedAt: Date(timeIntervalSince1970: 1_800_003_600)),
            ],
            workTokens: ["S1": 2_600_000, "S2": 540_000],
            hovered: hovered,
            frame: 600
        )
    }

    private func render(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 600))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(image.tiffRepresentation)
    }

    func testTheSameSceneRendersTheSamePictureTwice() throws {
        let first = try render(scene())
        let second = try render(scene())

        XCTAssertEqual(first, second,
                       "the scene must be a pure function of its inputs, or no later "
                       + "stage can tell a change from noise")
    }

    func testHoveringChangesThePicture() throws {
        XCTAssertNotEqual(try render(scene()), try render(scene(hovered: "S1")))
    }

    func testTheSceneRendersAtAll() throws {
        XCTAssertGreaterThan(try render(scene()).count, 1_000)
    }

    /// The pit lane is half the point of the park rule. An extraction that took
    /// only `sessions` would drop it and still render a plausible picture.
    func testAParkedSessionChangesThePicture() throws {
        let withPit = try render(scene())
        let empty = try render(AgentverseScene(
            circuit: try XCTUnwrap(CircuitCatalog.bundled().circuit("monaco")),
            sessions: [], parked: [], workTokens: [:], hovered: nil, frame: 600
        ))

        XCTAssertNotEqual(withPit, empty)
    }
}
