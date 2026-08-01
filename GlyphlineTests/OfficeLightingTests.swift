import XCTest
@testable import Glyphline

/// The office's daylight, asserted as relationships and never as colours.
///
/// Every test here names the production change it would catch. An absolute
/// colour would pin a number nobody can check and would have to be rewritten the
/// first time the sky curve is retouched; a relationship survives that and still
/// fails the moment the sun, the place or the weather stops reaching the room.
final class OfficeLightingTests: XCTestCase {
    // MARK: - Places and instants

    private static let berlin = UserPlace.Coordinates(latitude: 52.52, longitude: 13.40,
                                                      source: .table)

    /// UTC instants around the June solstice over Berlin. Local solar noon there
    /// is about 11:06 UTC, so these two are as near noon and midnight as makes no
    /// difference — and far enough apart that no rounding decides the outcome.
    private static let berlinNoon = Date(timeIntervalSince1970: 1_782_385_200) // 2026-06-25T11:00:00Z
    private static let berlinMidnight = Date(timeIntervalSince1970: 1_782_342_000) // 2026-06-24T23:00:00Z

    private func lighting(date: Date,
                          place: UserPlace.Coordinates = OfficeLightingTests.berlin,
                          weather: Weather = .clear) -> OfficeLighting {
        OfficeLighting.at(date: date, place: place, weather: weather)
    }

    /// Relative luminance of what the window actually shows: the sky after the
    /// exposure and the tone curve, brought back to linear, which is the only
    /// space in which "brighter" means anything.
    private func windowBrightness(_ lighting: OfficeLighting) -> Double {
        let linear = SceneLight.linearFromSRGB(lighting.windowSkySRGB)
        return 0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
    }

    // MARK: - Day and night

    /// Would catch: windows filled from a fixed colour rather than from
    /// `SceneLight.skyColor`, and an `OfficeLighting` that ignores the instant it
    /// is given — either one collapses these two into the same window.
    func testNoonAndMidnightGiveVisiblyDifferentWindows() {
        let noon = windowBrightness(lighting(date: Self.berlinNoon))
        let midnight = windowBrightness(lighting(date: Self.berlinMidnight))

        XCTAssertGreaterThan(midnight, 0,
                             "a night window is dark, not black — it still shows a sky")
        XCTAssertGreaterThan(noon / midnight, 6,
                             "day and night windows must be worlds apart, not shades apart")
    }

    /// Would catch: the day/night crossing never reaching the room, so the
    /// interior lamps are drawn at one fixed strength — the version of this scene
    /// that came before this task.
    func testInteriorLampsContributeMoreAtNightThanAtNoon() {
        let noon = lighting(date: Self.berlinNoon).interiorLampStrength
        let midnight = lighting(date: Self.berlinMidnight).interiorLampStrength

        // Not zero by day: the monitors are on at noon too, they are simply
        // overwhelmed. A constant 0 would pass a bare ratio assertion.
        XCTAssertGreaterThan(noon, 0, "the monitors are on during the day as well")
        XCTAssertGreaterThan(midnight / noon, 3,
                             "at night the interior has to take the room over, not tint it")
        XCTAssertLessThanOrEqual(midnight, 1)
    }

    /// The deliberate contrast: the office cools towards the windows at night,
    /// the break room does not. Would catch someone folding the break room's
    /// ceiling light into the same day/night curve as the office.
    func testTheBreakRoomKeepsItsWarmLightThroughout() {
        XCTAssertEqual(lighting(date: Self.berlinNoon).breakRoomLampStrength,
                       lighting(date: Self.berlinMidnight).breakRoomLampStrength,
                       accuracy: 1e-12)
        XCTAssertGreaterThan(lighting(date: Self.berlinNoon).breakRoomLampStrength, 0)
    }

    // MARK: - Weather

    /// Would catch: the weather never reaching `SceneLight.make`, whether because
    /// it is hard-coded to `.clear` or because the stored reading is dropped on
    /// the way in. Both look entirely plausible and both leave the office
    /// permanently sunny.
    func testRainAndClearDifferAtTheSameInstant() {
        let clear = lighting(date: Self.berlinNoon, weather: .clear)
        let rain = lighting(date: Self.berlinNoon, weather: .rain)

        XCTAssertGreaterThan(windowBrightness(clear), windowBrightness(rain) * 1.5,
                             "rain has to grey the window down, not tint it")
        XCTAssertGreaterThan(clear.light.direct, rain.light.direct * 2,
                             "rain takes nearly all of the direct light with it")
        XCTAssertEqual(rain.weather, .rain)
    }

    // MARK: - The place

    /// The one that catches a latitude fed through with the wrong sign — negated,
    /// dropped for the fallback constant, or swapped with the longitude. All
    /// three still produce a plausible sun; none of them produces *this*.
    ///
    /// Both places share a longitude, so they share a local solar time. At the
    /// December solstice, 75° north is in polar night while 75° south has the sun
    /// well up: same instant, opposite signs.
    func testTheHemisphereFlipsTheSignOfTheSunsElevation() {
        let instant = Date(timeIntervalSince1970: 1_766_318_400) // 2025-12-21T12:00:00Z
        let north = lighting(date: instant,
                             place: UserPlace.Coordinates(latitude: 75, longitude: 0,
                                                          source: .manual))
        let south = lighting(date: instant,
                             place: UserPlace.Coordinates(latitude: -75, longitude: 0,
                                                          source: .manual))

        XCTAssertLessThan(north.sun.elevation, -3, "75° N is in polar night in December")
        XCTAssertGreaterThan(south.sun.elevation, 3, "75° S has the sun up at the same moment")
        XCTAssertLessThan(north.sun.elevation * south.sun.elevation, 0)

        // And the room follows it: one window is a night window, the other is not.
        XCTAssertGreaterThan(windowBrightness(south), windowBrightness(north) * 2)
    }

    // MARK: - The sun through the day

    /// Would catch: an azimuth passed as a constant, or the sun's angle never
    /// reaching the directional light — the light pools on the floor would then
    /// sit still all day instead of swinging round.
    func testTheSunSwingsFromOneSideOfTheRoomToTheOther() {
        // 09:00 and 17:00 local in Berlin in June.
        let morning = lighting(date: Date(timeIntervalSince1970: 1_782_370_800)) // 07:00Z
        let afternoon = lighting(date: Date(timeIntervalSince1970: 1_782_399_600)) // 15:00Z

        XCTAssertGreaterThan(morning.light.sunX, 0.3,
                             "morning light crosses the room one way")
        XCTAssertLessThan(afternoon.light.sunX, -0.3,
                          "evening light crosses it the other")

        // Both are still daytime, so this is a change of direction and not of
        // day and night sneaking in through the back.
        XCTAssertGreaterThan(morning.sun.elevation, 5)
        XCTAssertGreaterThan(afternoon.sun.elevation, 5)
    }

    /// The unit trap `SceneLight.make` documents: elevation and azimuth in
    /// degrees, map rotation in radians. Feeding `SunPosition`'s degrees in as
    /// radians is silent and wrong, so this pins the one value the office turns
    /// its walls by.
    func testTheOfficeIsNotTurnedAgainstTheSun() {
        // Noon in the northern hemisphere puts the sun in the south, and the
        // office's back wall is the one that faces it: the light travels towards
        // +v, into the room, rather than out of it.
        let noon = lighting(date: Self.berlinNoon)
        XCTAssertGreaterThan(noon.light.sunY, 0.5,
                             "the noon sun has to come in through the back wall")
        XCTAssertLessThan(abs(OfficeLighting.mapRotation), 2 * .pi,
                          "map rotation is radians, not degrees")
    }
}
