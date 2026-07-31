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

    /// A corner name is only ever drawn at `points[idx]`, and the index comes out
    /// of a separate file built in a separate run. Monaco and Las Vegas have no
    /// named corners in OpenStreetMap at all, so an empty list is the right
    /// answer for them and must not be mistaken for a missing one.
    func testEveryCornerIndexesIntoItsOwnCentreline() throws {
        let catalog = try catalog()
        for key in catalog.keys {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            for corner in circuit.corners {
                XCTAssertTrue(
                    circuit.points.indices.contains(corner.idx),
                    "\(key): '\(corner.name)' points outside the centreline"
                )
            }
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
            // Without this the check below is satisfied by the empty default
            // that a missing terrain key falls back to, and 0 == 0 * 0 would
            // keep passing while the terrain quietly disappeared.
            XCTAssertGreaterThan(terrain.gw, 0, "\(key): no terrain at all")
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

    /// The picker's entries. Sorted by the label it shows, not by key and not in
    /// dictionary order — the latter differs between launches, so the circuits
    /// would sit somewhere else in the control every time the window is opened.
    func testTheCircuitsAreOfferedByLabelInAStableOrder() throws {
        let entries = try catalog().entriesInPickerOrder

        XCTAssertEqual(entries.map(\.short), entries.map(\.short).sorted())
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(
            entries.first(where: { $0.key == "monaco" })?.name, "Circuit de Monaco"
        )
    }

    /// A tab has room for a venue, not for "Circuit de Spa-Francorchamps". Every
    /// circuit in the bundle needs one, or a tab comes out blank.
    func testEveryCircuitHasAShortLabel() throws {
        let entries = try catalog().entriesInPickerOrder

        XCTAssertEqual(entries.map(\.short),
                       ["Las Vegas", "Monaco", "Monza", "Spa", "Suzuka"])
        for entry in entries {
            XCTAssertFalse(entry.short.isEmpty)
            XCTAssertLessThanOrEqual(entry.short.count, entry.name.count)
        }
    }

    /// The window puts this string in front of the user. `Error`'s default
    /// description reads "The operation couldn't be completed", which says
    /// nothing about which file is missing from the bundle.
    func testTheFailureNamesTheResourceItCouldNotFind() {
        let error: Error = CircuitCatalogError.missingResource(name: "corners", extension: "json")

        XCTAssertTrue(error.localizedDescription.contains("corners.json"),
                      "the pane would not say what is missing: \(error.localizedDescription)")
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
