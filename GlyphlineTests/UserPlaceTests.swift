import XCTest
@testable import Glyphline

/// The coordinates in `timezone-places.json` come from the IANA tzdb's own
/// `zone.tab`, which lists the representative city of each zone. The expected
/// values below were not read out of that file: they are the textbook
/// coordinates of the cities themselves, so a table built from the wrong column
/// — or from a zone's meridian rather than its city — fails here.
final class UserPlaceTests: XCTestCase {
    func testBerlinResolvesToBerlin() throws {
        let place = UserPlace.current(timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")))

        XCTAssertEqual(place.latitude, 52.52, accuracy: 0.5)
        XCTAssertEqual(place.longitude, 13.40, accuracy: 0.5)
        XCTAssertEqual(place.source, .table)
    }

    /// The one that matters. A flipped hemisphere lights the office brightly at
    /// midnight and leaves it dark at noon, and every frame of it looks
    /// plausible, so nothing about the rendering would give the error away.
    func testSydneyIsInTheSouthernHemisphere() throws {
        let place = UserPlace.current(timeZone: try XCTUnwrap(TimeZone(identifier: "Australia/Sydney")))

        XCTAssertLessThan(place.latitude, 0)
        XCTAssertEqual(place.latitude, -33.87, accuracy: 0.5)
        XCTAssertEqual(place.longitude, 151.21, accuracy: 0.5)
        XCTAssertEqual(place.source, .table)
    }

    /// Two zones that share an offset and are 600 km apart: a table keyed off the
    /// offset rather than the city cannot tell them apart.
    func testLisbonAndLondonDoNotShareCoordinates() throws {
        let lisbon = UserPlace.current(timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon")))
        let london = UserPlace.current(timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/London")))

        XCTAssertEqual(lisbon.latitude, 38.72, accuracy: 0.5)
        XCTAssertEqual(london.latitude, 51.51, accuracy: 0.5)
        XCTAssertGreaterThan(london.latitude - lisbon.latitude, 10)
    }

    func testUnknownZoneFallsBackToItsOffsetMeridian() throws {
        // A fixed-offset zone is never in a table keyed by city name.
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))

        let place = UserPlace.current(timeZone: zone)

        XCTAssertEqual(place.source, .offsetFallback)
        XCTAssertEqual(place.longitude, Double(zone.secondsFromGMT()) / 240, accuracy: 8)
    }

    func testUnknownWesternZoneFallsBackToANegativeLongitude() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: -5 * 3600))

        let place = UserPlace.current(timeZone: zone)

        XCTAssertEqual(place.source, .offsetFallback)
        XCTAssertEqual(place.longitude, -75, accuracy: 8)
    }

    func testManualOverrideWinsOverTheTable() throws {
        let place = UserPlace.current(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            override: UserPlace.Coordinates(latitude: -41.29, longitude: 174.78, source: .table)
        )

        XCTAssertEqual(place.latitude, -41.29, accuracy: 0.001)
        XCTAssertEqual(place.longitude, 174.78, accuracy: 0.001)
        XCTAssertEqual(place.source, .manual)
    }

    func testManualOverrideWinsOverTheOffsetFallback() throws {
        let place = UserPlace.current(
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600)),
            override: UserPlace.Coordinates(latitude: 12.5, longitude: -3.25, source: .manual)
        )

        XCTAssertEqual(place.latitude, 12.5, accuracy: 0.001)
        XCTAssertEqual(place.longitude, -3.25, accuracy: 0.001)
        XCTAssertEqual(place.source, .manual)
    }

    func testEveryTableEntryIsAPointOnTheGlobe() throws {
        let table = try UserPlace.TimeZonePlaceTable.bundled()

        XCTAssertGreaterThanOrEqual(table.places.count, 120)

        for (identifier, place) in table.places {
            XCTAssert((-90...90).contains(place.latitude), "\(identifier) latitude \(place.latitude)")
            XCTAssert((-180...180).contains(place.longitude), "\(identifier) longitude \(place.longitude)")
        }
    }

    func testTableCoversTheRegionsAUserIsPlausiblyIn() throws {
        let table = try UserPlace.TimeZonePlaceTable.bundled()

        for region in ["Europe/", "America/", "Asia/", "Australia/", "Africa/", "Pacific/", "Atlantic/"] {
            let count = table.places.keys.filter { $0.hasPrefix(region) }.count
            XCTAssertGreaterThan(count, 0, "no entries for \(region)")
        }
    }

    func testAMissingResourceIsATypedError() {
        XCTAssertThrowsError(try UserPlace.TimeZonePlaceTable.bundled(in: Bundle(for: Self.self))) { error in
            XCTAssertEqual(
                error as? UserPlaceError,
                .missingResource(name: "timezone-places", extension: "json")
            )
        }
    }
}
