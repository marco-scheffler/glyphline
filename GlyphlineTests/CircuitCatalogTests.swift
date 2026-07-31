import XCTest
@testable import Glyphline

/// These are the figures the data was measured to, and every one of them was
/// wrong at some point while it was being built: the pit lane resolved to the
/// wrong layout at Spa and Suzuka, start/finish was misplaced on all five
/// circuits, and Monaco's pit lane was stored against the racing direction.
/// Asserting them is cheaper than finding them a fourth time.
final class CircuitCatalogTests: XCTestCase {
    private func catalog() throws -> CircuitCatalog {
        try CircuitCatalog.bundled()
    }

    func testAllFiveCircuitsLoadFromTheBundle() throws {
        XCTAssertEqual(
            try catalog().keys.sorted(),
            ["monaco", "monza", "spa", "suzuka", "vegas"]
        )
    }

    func testLengthsMatchWhatWasMeasured() throws {
        let catalog = try catalog()
        let expected: [String: Double] = [
            "monaco": 3.324, "spa": 6.978, "suzuka": 5.812,
            "monza": 5.787, "vegas": 6.221,
        ]

        for (key, km) in expected {
            XCTAssertEqual(
                try XCTUnwrap(catalog.circuit(key)).lengthKm, km, accuracy: 0.001,
                "\(key) drifted from the measured centreline"
            )
        }
    }

    func testStartFinishIndexesIntoItsOwnCentreline() throws {
        let catalog = try catalog()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            XCTAssertTrue(
                circuit.points.indices.contains(circuit.startIdx),
                "\(key): start/finish points outside the centreline"
            )
        }
    }

    /// Four are driven clockwise; Las Vegas is the odd one out. Screen space runs
    /// y downwards, so a positive shoelace area reads as clockwise.
    func testRacingDirectionSurvivedTheProjection() throws {
        let catalog = try catalog()
        for key in catalog.keys {
            let points = try XCTUnwrap(catalog.circuit(key)).points
            let area = (0 ..< points.count).reduce(0.0) { sum, i in
                let a = points[i], b = points[(i + 1) % points.count]
                return sum + (a[0] * b[1] - b[0] * a[1])
            }
            XCTAssertEqual(
                area > 0, key != "vegas",
                "\(key) is wound the wrong way round"
            )
        }
    }

    func testTerrainGridIsAsWideAndTallAsItClaims() throws {
        let catalog = try catalog()
        for key in catalog.keys {
            let terrain = try XCTUnwrap(catalog.circuit(key)).terrain
            XCTAssertEqual(
                terrain.grid.count, terrain.gw * terrain.gh,
                "\(key): elevation grid does not match its stated dimensions"
            )
        }
    }

    /// Only Monaco has a coast. The others must carry no mask at all rather than
    /// an empty one, so "inland" cannot be confused with "not computed".
    func testOnlyTheCoastalCircuitCarriesASeaMask() throws {
        let catalog = try catalog()
        XCTAssertNotNil(try XCTUnwrap(catalog.circuit("monaco")).terrain.sea)
        for key in ["spa", "suzuka", "monza", "vegas"] {
            XCTAssertNil(try XCTUnwrap(catalog.circuit(key)).terrain.sea)
        }
    }

    func testAMissingResourceFailsLoudly() throws {
        XCTAssertThrowsError(try CircuitCatalog.bundled(in: Bundle(for: XCTestCase.self))) { error in
            XCTAssertEqual(
                error as? CircuitCatalogError,
                .missingResource(name: "circuits", extension: "json"),
                "an absent resource is a build mistake and must not read as an empty scene"
            )
        }
    }
}
