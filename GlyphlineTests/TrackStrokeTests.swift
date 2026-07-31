import XCTest
@testable import Glyphline

/// The table both track renderers read. What it has to hold is the draw order
/// and the fact that the verge is the wider of the two centreline strokes —
/// swap either and the road becomes a pale worm with a dark rim.
final class TrackStrokeTests: XCTestCase {
    func testTheStrokesAreInDrawOrder() {
        XCTAssertEqual(TrackStroke.all.map(\.path),
                       [.centreline, .centreline, .racingLine, .kerbs, .pitLane, .startFinish])
    }

    func testTheVergeIsStrokedFirstAndWiderThanTheSurface() throws {
        let circuit = try XCTUnwrap(CircuitCatalog.bundled().circuit("monaco"))
        let fit = CircuitFit(circuit: circuit, in: CGSize(width: 900, height: 600))

        XCTAssertGreaterThan(TrackStroke.all[0].points(fit: fit),
                             TrackStroke.all[1].points(fit: fit))
        XCTAssertLessThan(TrackStroke.all[0].alpha, TrackStroke.all[1].alpha,
                          "the verge is the translucent one")
    }

    /// The kerbs are one definition with two colours, not two definitions that
    /// can drift apart — which is exactly what the duplicated renderers did.
    func testTheKerbsAlternateBetweenTwoDistinctColours() throws {
        let kerbs = try XCTUnwrap(TrackStroke.all.first { $0.path == .kerbs })
        guard case .alternating(let red, let pale) = kerbs.paint else {
            return XCTFail("the kerbs have to alternate, or they read as a solid line")
        }
        XCTAssertNotEqual(red, pale)
        XCTAssertGreaterThan(red.x, red.y + red.z, "the red block is red")
        XCTAssertEqual(pale.x, pale.y)
        XCTAssertEqual(pale.y, pale.z)
    }

    func testTheStartFinishLineDoesNotScaleWithTheCircuit() {
        let line = TrackStroke.all[5]
        guard case .points = line.width else {
            return XCTFail("the start/finish line is a marking, not a width of road")
        }
    }
}
