import XCTest
@testable import Glyphline

/// The fit was got wrong twice while this was being mocked up, once badly
/// enough that half of Las Vegas sat outside the frame. It is a pure function
/// precisely so it can be pinned here.
final class CircuitFitTests: XCTestCase {
    private func catalog() throws -> CircuitCatalog { try CircuitCatalog.bundled() }

    private let sizes: [CGSize] = [
        CGSize(width: 1_160, height: 820),   // the window's default, less the sidebar
        CGSize(width: 660, height: 560),     // the smallest the window allows
        CGSize(width: 1_800, height: 400),   // wide and short
        CGSize(width: 600, height: 900),     // tall and narrow
    ]

    func testEveryCircuitFitsEveryWindowShape() throws {
        let catalog = try catalog()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            for size in sizes {
                let fit = CircuitFit(circuit: circuit, in: size)
                for metre in circuit.points + circuit.pit {
                    let p = fit.point(metre)
                    XCTAssertTrue(
                        (0...size.width).contains(p.x) && (0...size.height).contains(p.y),
                        "\(key) at \(size): \(p) escapes the canvas"
                    )
                }
            }
        }
    }

    func testTheCircuitIsCentredRatherThanCornered() throws {
        let circuit = try XCTUnwrap(catalog().circuit("monaco"))
        let size = CGSize(width: 1_000, height: 600)
        let fit = CircuitFit(circuit: circuit, in: size)
        let xs = circuit.points.map { fit.point($0).x }
        let ys = circuit.points.map { fit.point($0).y }

        XCTAssertEqual((xs.min()! + xs.max()!) / 2, size.width / 2, accuracy: 1)
        XCTAssertEqual((ys.min()! + ys.max()!) / 2, size.height / 2, accuracy: 1)
    }

    /// One scale for both axes. Two would stretch the circuit into a shape it
    /// does not have, which is worse than leaving margin.
    func testTheAspectRatioIsPreserved() throws {
        let circuit = try XCTUnwrap(catalog().circuit("spa"))
        let fit = CircuitFit(circuit: circuit, in: CGSize(width: 1_800, height: 400))
        let xs = circuit.points.map { fit.point($0).x }
        let ys = circuit.points.map { fit.point($0).y }

        XCTAssertEqual(
            (xs.max()! - xs.min()!) / (ys.max()! - ys.min()!),
            circuit.spanX / circuit.spanY,
            accuracy: 0.01
        )
    }

    /// What is framed is the terrain box, not the racing line. The terrain and
    /// the scenery reach 500 m beyond the circuit on every side; fitting the
    /// circuit alone magnified the track and pushed the whole city off-frame.
    func testTheTerrainBoxIsWhatGetsFitted() throws {
        let catalog = try catalog()
        let size = CGSize(width: 1_000, height: 600)
        let usableWidth = size.width - 2 * CircuitFit.margin
        let usableHeight = size.height - 2 * CircuitFit.margin

        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            let terrain = circuit.terrain
            let spanX = CGFloat(terrain.maxX - terrain.minX)
            let spanY = CGFloat(terrain.maxY - terrain.minY)
            XCTAssertGreaterThan(spanX, CGFloat(circuit.spanX), "\(key): terrain must be the larger box")

            let fit = CircuitFit(circuit: circuit, in: size)
            XCTAssertEqual(fit.scale,
                           min(usableWidth / spanX, usableHeight / spanY),
                           accuracy: 1e-9,
                           "\(key): the fit is not framed on the terrain box")

            // And the terrain box itself lands centred inside the canvas.
            let lo = fit.point([terrain.minX, terrain.minY])
            let hi = fit.point([terrain.maxX, terrain.maxY])
            XCTAssertEqual((lo.x + hi.x) / 2, size.width / 2, accuracy: 1)
            XCTAssertEqual((lo.y + hi.y) / 2, size.height / 2, accuracy: 1)
        }
    }

    /// A circuit whose terrain failed to build must still render, so the fit
    /// falls back to the racing line's own box rather than dividing by nothing.
    func testADegenerateTerrainFallsBackToTheCircuitBox() throws {
        var circuit = try XCTUnwrap(catalog().circuit("monaco"))
        circuit.terrain = CircuitTerrain()
        let size = CGSize(width: 1_000, height: 600)
        let fit = CircuitFit(circuit: circuit, in: size)

        XCTAssertTrue(fit.scale.isFinite)
        XCTAssertGreaterThan(fit.scale, 0)
        XCTAssertEqual(
            fit.scale,
            min((size.width - 2 * CircuitFit.margin) / CGFloat(circuit.spanX),
                (size.height - 2 * CircuitFit.margin) / CGFloat(circuit.spanY)),
            accuracy: 1e-9
        )
    }

    func testADegenerateCanvasDoesNotProduceNonsense() throws {
        let circuit = try XCTUnwrap(catalog().circuit("monza"))
        let fit = CircuitFit(circuit: circuit, in: .zero)

        XCTAssertTrue(fit.scale.isFinite)
        XCTAssertGreaterThanOrEqual(fit.scale, 0)
    }
}
