import SwiftUI
import XCTest
@testable import Glyphline

/// Outside the class because a default argument cannot reference a member of
/// the type it is declared in.
private let parkedSession = ParkedAgentSession(
    sessionID: "S3", cwd: "/repo/c", gitBranch: "main",
    subagentCount: 0,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
    parkedAt: Date(timeIntervalSince1970: 1_800_003_600))

/// A rendered picture, hashed. The browser mockups needed Playwright and forced
/// software rasterisation for this; `ImageRenderer` does it in-process.
///
/// The point is not the hash itself but that stages 3b and 3c can be judged from
/// their first commit. The look was designed blind for hours, and every one of
/// the four bugs found late was found by looking at output rather than by
/// reading code.
@MainActor
final class AgentverseSnapshotTests: XCTestCase {
    /// Every input is fixed but the ones a caller overrides, so each test can
    /// vary exactly one thing and know that nothing else accounts for a
    /// difference in bytes.
    private func scene(hovered: String? = nil,
                       parked: [ParkedAgentSession] = [parkedSession])
    throws -> AgentverseScene {
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
            parked: parked,
            workTokens: ["S1": 2_600_000, "S2": 540_000],
            hovered: hovered,
            frame: 600
        )
    }

    /// Nothing on the circuit and nothing in the pit lane: whatever this draws
    /// is the track itself.
    private func emptyScene() throws -> AgentverseScene {
        AgentverseScene(
            circuit: try XCTUnwrap(CircuitCatalog.bundled().circuit("monaco")),
            sessions: [], parked: [], workTokens: [:], hovered: nil, frame: 600
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

    /// A scene that drew nothing would still hand back a megabyte of black
    /// pixels, so size proves nothing. With no cars in it, the only thing that
    /// can separate the scene from its own background colour is the track.
    func testTheTrackIsDrawn() throws {
        XCTAssertNotEqual(try render(emptyScene()), try render(Color(white: 0.07)),
                          "with nothing on it the scene must still draw the circuit")
    }

    /// The pit lane is half the point of the park rule. An extraction that took
    /// only `sessions` would drop it and still render a plausible picture.
    func testAParkedSessionChangesThePicture() throws {
        let withPit = try render(scene())
        let withoutPit = try render(scene(parked: []))

        XCTAssertNotEqual(withPit, withoutPit,
                          "only `parked` differs, so a car in the pit lane is the "
                          + "only thing that can account for a difference")
    }
}
