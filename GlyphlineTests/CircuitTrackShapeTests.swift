import SwiftUI
import XCTest
@testable import Glyphline

/// The paths themselves are pixels and not worth asserting; what is worth
/// asserting is that the start/finish line is drawn at all, for every circuit
/// that ships, and that a degenerate centreline produces nothing rather than a
/// crash.
final class CircuitTrackShapeTests: XCTestCase {
    private let canvas = CGSize(width: 800, height: 600)

    func testTheStartFinishLineIsDrawnForEveryBundledCircuit() throws {
        let catalog = try CircuitCatalog.bundled()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            let fit = CircuitFit(circuit: circuit, in: canvas)

            XCTAssertFalse(
                CircuitTrackShape.startFinish(for: circuit, fit: fit).isEmpty,
                "\(key): no line across the track at its measured start/finish"
            )
        }
    }

    /// A tangent needs two points. One or none is a broken bundle, and the shape
    /// has to answer with an empty path rather than reading past the end.
    func testACentrelineTooShortForATangentDrawsNothing() throws {
        let catalog = try CircuitCatalog.bundled()
        var circuit = try XCTUnwrap(catalog.circuit("monaco"))
        let fit = CircuitFit(circuit: circuit, in: canvas)

        circuit.points = []
        circuit.startIdx = 0
        XCTAssertTrue(CircuitTrackShape.startFinish(for: circuit, fit: fit).isEmpty)

        circuit.points = [[0, 0]]
        XCTAssertTrue(CircuitTrackShape.startFinish(for: circuit, fit: fit).isEmpty)
    }
}
