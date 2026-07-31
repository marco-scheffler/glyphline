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

    // MARK: - Kerbs

    /// An oval: two 400 m straights joined by two half-circles, with the ends
    /// sampled at `perEnd` points so each of them turns `180 / perEnd` degrees
    /// per point. Coarse ends are hairpins, fine ends are barely a bend, and the
    /// straights are straight either way.
    private func oval(perEnd: Int) -> [[Double]] {
        var points: [[Double]] = []
        for step in 0..<20 { points.append([Double(step) * 21, 0]) }
        for step in 0...perEnd {
            let angle = -.pi / 2 + .pi * Double(step) / Double(perEnd)
            points.append([400 + 100 * cos(angle), 100 + 100 * sin(angle)])
        }
        for step in 0..<20 { points.append([Double(19 - step) * 21, 200]) }
        for step in 0...perEnd {
            let angle = .pi / 2 + .pi * Double(step) / Double(perEnd)
            points.append([100 * cos(angle), 100 + 100 * sin(angle)])
        }
        return points
    }

    /// The whole point of the threshold. A lap whose sharpest point turns six
    /// degrees is not a corner anywhere along it, straights included — a
    /// centreline that came out kerbed there would mean the angle is measured
    /// off something other than the direction of travel, and every circuit would
    /// be kerbed end to end.
    func testALapThatNeverTurnsHardHasNoKerbsAndAHairpinDoes() throws {
        let catalog = try CircuitCatalog.bundled()
        var circuit = try XCTUnwrap(catalog.circuit("monaco"))
        let fit = CircuitFit(circuit: circuit, in: canvas)

        circuit.points = oval(perEnd: 30)
        XCTAssertTrue(CircuitTrackShape.kerbs(for: circuit, fit: fit).isEmpty,
                      "six degrees a point is a straight and two sweepers, not a corner")

        circuit.points = oval(perEnd: 6)
        XCTAssertFalse(CircuitTrackShape.kerbs(for: circuit, fit: fit).isEmpty,
                       "thirty degrees a point is a hairpin and must be kerbed")
    }

    /// The other half of it: the kerbs the hairpin gets are at the hairpin. The
    /// oval's straights run along y = 0 and y = 200, so a block found out in the
    /// middle of one of them is a kerb laid down a straight.
    func testKerbsSitAtTheCornersAndNotDownTheStraights() throws {
        let catalog = try CircuitCatalog.bundled()
        var circuit = try XCTUnwrap(catalog.circuit("monaco"))
        circuit.points = oval(perEnd: 6)
        let fit = CircuitFit(circuit: circuit, in: canvas)

        // The straights run from x = 0 to x = 399; the turns are the ground
        // beyond both, and the kerb of the last point before a turn reaches a
        // little way back into it.
        let entry = fit.point([40, 0]).x
        let exit = fit.point([360, 0]).x
        for (block, _) in CircuitTrackShape.kerbs(for: circuit, fit: fit) {
            block.forEach { element in
                guard case let .line(to: point) = element else { return }
                XCTAssertFalse(point.x > entry && point.x < exit,
                               "a kerb block runs down the middle of a straight")
            }
        }
    }

    /// Red, white, red, white. Blocks that all came back with the same flag
    /// would be drawn as one solid band, which is a wall, not a kerb.
    func testKerbBlocksAlternate() throws {
        let catalog = try CircuitCatalog.bundled()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            let fit = CircuitFit(circuit: circuit, in: canvas)
            let flags = CircuitTrackShape.kerbs(for: circuit, fit: fit).map(\.1)

            XCTAssertGreaterThan(flags.count, 1, "\(key): a circuit has corners")
            XCTAssertTrue(flags.contains(true) && flags.contains(false),
                          "\(key): every kerb block came back the same colour")
        }
    }

    /// Not a count, which would pin the threshold's exact value: a floor and a
    /// ceiling, because the numbers that are wrong are wrong by an order of
    /// magnitude. Three kerbs at Monaco means the threshold stopped finding
    /// corners; ninety means it stopped telling them from straights.
    func testEveryCircuitGetsAPlausibleNumberOfKerbs() throws {
        let catalog = try CircuitCatalog.bundled()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            let fit = CircuitFit(circuit: circuit, in: canvas)
            let kerbed = CircuitTrackShape.kerbs(for: circuit, fit: fit).count

            XCTAssertGreaterThan(kerbed, 8, "\(key): too few kerb blocks to be a circuit")
            XCTAssertLessThan(kerbed, circuit.points.count * 8,
                              "\(key): the whole lap has been kerbed")
        }
    }

    /// Two points cannot describe a turn, and reading for a third is how the
    /// centreline shape got its guard in the first place.
    func testACentrelineTooShortForACornerHasNoKerbs() throws {
        let catalog = try CircuitCatalog.bundled()
        var circuit = try XCTUnwrap(catalog.circuit("monaco"))
        let fit = CircuitFit(circuit: circuit, in: canvas)

        for points in [[], [[0.0, 0.0]], [[0.0, 0.0], [10.0, 10.0]]] {
            circuit.points = points
            XCTAssertTrue(CircuitTrackShape.kerbs(for: circuit, fit: fit).isEmpty)
        }
    }

    // MARK: - Racing line

    func testTheRacingLineIsDrawnForEveryBundledCircuit() throws {
        let catalog = try CircuitCatalog.bundled()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            let fit = CircuitFit(circuit: circuit, in: canvas)

            XCTAssertFalse(CircuitTrackShape.racingLine(for: circuit, fit: fit).isEmpty,
                           "\(key): no racing line to lay the rubber on")
        }
    }
}
