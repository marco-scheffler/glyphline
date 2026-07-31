import XCTest
@testable import Glyphline

/// The expected elevations and azimuths here were not produced by the code under
/// test. Each was computed beforehand by two independent implementations that
/// share no lineage with the NOAA algorithm in `SunPosition`: PyEphem 4.2.1
/// (libastro/XEphem) and pvlib 0.14 (the NREL SPA). The two agree with each
/// other to better than 0.005° on every value below, so a tolerance of 0.3°
/// leaves room for the NOAA approximation without letting a real error through.
final class SunPositionTests: XCTestCase {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private let greenwichLatitude = 51.4769
    private let greenwichLongitude = 0.0
    private let monacoLatitude = 43.7347
    private let monacoLongitude = 7.4206

    // MARK: - Anchors

    func testGreenwichAtSolsticeNoonUTC() {
        // 2026 June solstice is 2026-06-21 08:24 UTC; noon that day.
        // PyEphem 61.9661° / 179.1134°, pvlib SPA 61.9666° / 179.1133°.
        let sun = SunPosition.at(
            latitude: greenwichLatitude,
            longitude: greenwichLongitude,
            date: utc(2026, 6, 21, 12, 0)
        )
        XCTAssertEqual(sun.elevation, 61.966, accuracy: 0.3)
        XCTAssertEqual(sun.azimuth, 179.113, accuracy: 0.3)
    }

    func testGreenwichAtSolsticeMidnightIsWellBelowTheHorizon() {
        // PyEphem and pvlib both give −15.087°.
        let sun = SunPosition.at(
            latitude: greenwichLatitude,
            longitude: greenwichLongitude,
            date: utc(2026, 6, 21, 0, 0)
        )
        XCTAssertLessThan(sun.elevation, 0)
        XCTAssertEqual(sun.elevation, -15.087, accuracy: 0.3)
    }

    func testMonacoLateAfternoon() {
        // PyEphem 17.0306° / 279.1012°, pvlib SPA 17.0327° / 279.1012°.
        let sun = SunPosition.at(
            latitude: monacoLatitude,
            longitude: monacoLongitude,
            date: utc(2026, 7, 31, 17, 11)
        )
        XCTAssertEqual(sun.elevation, 17.031, accuracy: 0.3)
        XCTAssertEqual(sun.azimuth, 279.101, accuracy: 0.3)
        // Late afternoon: the sun is in the western half of the sky.
        XCTAssertGreaterThan(sun.azimuth, 180)
        XCTAssertLessThan(sun.azimuth, 360)
    }

    // MARK: - Refraction

    func testRefractionLiftsTheSunAtTheHorizon() {
        // Where the interesting colours live. pvlib reports the same instant as
        // 16.9788° true and 17.0327° apparent, so the correction must be
        // present and positive — but small at this elevation.
        let sun = SunPosition.at(
            latitude: monacoLatitude,
            longitude: monacoLongitude,
            date: utc(2026, 7, 31, 17, 11)
        )
        XCTAssertGreaterThan(sun.elevation, 16.9788)
    }

    // MARK: - Invariants

    func testElevationAndAzimuthStayInRangeAllYearAndAllOverTheGlobe() {
        let latitudes = [-89.5, -66.0, -43.7, 0.0, 35.0, 51.5, 66.0, 89.5]
        let longitudes = [-179.0, -74.0, 0.0, 7.4, 139.7, 179.0]
        for latitude in latitudes {
            for longitude in longitudes {
                for dayOfYear in stride(from: 1, through: 365, by: 29) {
                    for hour in stride(from: 0, to: 24, by: 3) {
                        let date = utc(2026, 1, 1, hour, 0)
                            .addingTimeInterval(Double(dayOfYear - 1) * 86_400)
                        let sun = SunPosition.at(
                            latitude: latitude,
                            longitude: longitude,
                            date: date
                        )
                        XCTAssertTrue(sun.elevation.isFinite)
                        XCTAssertTrue(sun.azimuth.isFinite)
                        XCTAssertGreaterThanOrEqual(sun.elevation, -90)
                        XCTAssertLessThanOrEqual(sun.elevation, 90)
                        XCTAssertGreaterThanOrEqual(sun.azimuth, 0)
                        XCTAssertLessThan(sun.azimuth, 360)
                    }
                }
            }
        }
    }

    func testSameInstantOfDayAYearApartGivesASimilarElevation() {
        // PyEphem: Monaco 17.0306° in 2026 against 17.0716° in 2027.
        let first = SunPosition.at(
            latitude: monacoLatitude,
            longitude: monacoLongitude,
            date: utc(2026, 7, 31, 17, 11)
        )
        let second = SunPosition.at(
            latitude: monacoLatitude,
            longitude: monacoLongitude,
            date: utc(2027, 7, 31, 17, 11)
        )
        XCTAssertEqual(first.elevation, second.elevation, accuracy: 2.0)
    }
}
