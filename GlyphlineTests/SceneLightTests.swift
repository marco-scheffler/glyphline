import XCTest
@testable import Glyphline

/// These tests pin the properties the look depends on, not the individual
/// constants. A test asserting `EXPOSURE == 1.05` pins a number nobody can
/// check; a test asserting that night exposure is several times the daytime
/// exposure pins the behaviour that makes night bright without making it grey.
final class SceneLightTests: XCTestCase {
    private func light(
        elevation: Double,
        azimuth: Double = 180,
        mapRotation: Double = 0,
        weather: Weather = .clear
    ) -> SceneLight {
        SceneLight.make(
            elevation: elevation,
            azimuth: azimuth,
            mapRotation: mapRotation,
            weather: weather
        )
    }

    /// Relative luminance in the linear working space, which is the only place
    /// where "brighter" is a meaningful comparison.
    private func luminance(_ linear: SIMD3<Double>) -> Double {
        0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
    }

    private func linearOfSRGB(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        SceneLight.linearFromSRGB(srgb)
    }

    // MARK: - The tone curve

    func testACESIsMonotonicStartsAtZeroAndNeverExceedsOne() {
        XCTAssertEqual(SceneLight.aces(0), 0, accuracy: 1e-12)

        var previous = SceneLight.aces(0)
        var x = 0.0
        while x <= 4.0 {
            let y = SceneLight.aces(x)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-12, "aces dipped at x = \(x)")
            XCTAssertLessThanOrEqual(y, 1.0, "aces exceeded 1 at x = \(x)")
            XCTAssertGreaterThanOrEqual(y, 0.0, "aces went negative at x = \(x)")
            previous = y
            x += 0.002
        }

        // The point of the curve: the way into white is a curve, not an edge.
        // A hard clamp would already sit at 1 well before x = 4.
        XCTAssertLessThan(SceneLight.aces(2.0), 1.0)
        XCTAssertGreaterThan(SceneLight.aces(2.0), SceneLight.aces(1.0))
    }

    // MARK: - The linear round trip

    func testSRGBRoundTripsThroughLinearWithinOneStep() {
        for value in 0...255 {
            let linear = SceneLight.linearFromSRGB(SIMD3(repeating: Double(value)))
            let back = SceneLight.srgbFromLinear(linear.x)
            XCTAssertEqual(back, Double(value), accuracy: 1.0,
                           "sRGB \(value) did not survive the round trip")
        }
    }

    // MARK: - Sun colour

    func testSunIsNearWhiteHighUpAndWarmAtTheHorizon() {
        let high = SceneLight.sunTint(elevation: 60)
        let horizon = SceneLight.sunTint(elevation: 0)

        XCTAssertEqual(high.x / high.z, 1.0, accuracy: 0.15, "the high sun should be near white")
        XCTAssertGreaterThan(horizon.x / horizon.z, 3.0,
                             "the sun at the horizon should be markedly warmer")
        XCTAssertGreaterThan(horizon.x / horizon.z, 2 * (high.x / high.z))
    }

    func testTheKeyLightBecomesTheMoonBelowTheHorizon() {
        let moonLinear = linearOfSRGB(SceneLight.moonTint)

        let night = light(elevation: -15)
        XCTAssertEqual(night.sunLinear.x, moonLinear.x, accuracy: 1e-9)
        XCTAssertEqual(night.sunLinear.y, moonLinear.y, accuracy: 1e-9)
        XCTAssertEqual(night.sunLinear.z, moonLinear.z, accuracy: 1e-9)

        // The moon tint is cool; the daytime key light is not.
        let day = light(elevation: 40)
        XCTAssertLessThan(night.sunLinear.x / night.sunLinear.z, 1.0)
        XCTAssertGreaterThan(day.sunLinear.x / day.sunLinear.z, 1.0)
    }

    // MARK: - Sky colour

    func testSkyIsDarkBlueAtNightAndLightBlueByDay() {
        let night = SceneLight.skyTint(elevation: -20, weather: .clear, night: 1)
        let day = SceneLight.skyTint(elevation: 40, weather: .clear, night: 0)

        XCTAssertGreaterThan(night.z, night.x, "the night sky should be blue")
        XCTAssertGreaterThan(day.z, day.x, "the day sky should be blue")
        XCTAssertLessThan(night.z, 80, "the night sky should be dark")
        XCTAssertGreaterThan(day.z, 180, "the day sky should be light")

        let nightLuminance = luminance(linearOfSRGB(night))
        let dayLuminance = luminance(linearOfSRGB(day))
        XCTAssertGreaterThan(dayLuminance / nightLuminance, 20,
                             "day and night sky should be worlds apart, not shades apart")
    }

    // MARK: - Exposure

    func testNightExposureIsSeveralTimesTheDaytimeExposure() {
        let day = light(elevation: 45).exposure
        let night = light(elevation: -20).exposure

        XCTAssertGreaterThan(night / day, 3.0,
                             "night is a change of exposure, not a gamma lift")
        XCTAssertLessThan(night / day, 6.0,
                          "an exposure this high would wash the night out to grey")
    }

    // MARK: - Weather

    func testOvercastTradesDirectLightForDiffuseAndSoftensShadows() {
        let clear = light(elevation: 40, weather: .clear)
        let cloud = light(elevation: 40, weather: .cloud)
        let rain = light(elevation: 40, weather: .rain)

        XCTAssertGreaterThan(clear.direct, cloud.direct)
        XCTAssertGreaterThan(cloud.direct, rain.direct)

        XCTAssertGreaterThan(cloud.diffuse, clear.diffuse)
        XCTAssertGreaterThan(rain.diffuse, clear.diffuse)

        XCTAssertGreaterThan(clear.shadowAlpha, cloud.shadowAlpha)
        XCTAssertGreaterThan(cloud.shadowAlpha, rain.shadowAlpha)

        XCTAssertGreaterThan(cloud.shadowBlur, clear.shadowBlur)
        XCTAssertGreaterThan(rain.shadowBlur, cloud.shadowBlur)
    }

    // MARK: - Shading

    func testAWallFacingTheSunIsBrighterThanTheSameWallFacingAway() {
        let sun = light(elevation: 35, azimuth: 180)
        let albedo = SIMD3<Double>(180, 176, 168)

        let towards = sun.shadeWallLinear(normalX: sun.sunX, normalY: sun.sunY, albedo: albedo)
        let away = sun.shadeWallLinear(normalX: -sun.sunX, normalY: -sun.sunY, albedo: albedo)

        XCTAssertGreaterThan(luminance(towards), luminance(away) * 1.5,
                             "a lit wall and a shaded wall must not read the same")

        // The shaded wall is still lit by the sky rather than being black.
        XCTAssertGreaterThan(luminance(away), 0)
    }

    func testARoofTakesTheFullSkyAndTheSunBySineOfElevation() {
        let albedo = SIMD3<Double>(180, 176, 168)
        let high = light(elevation: 70)
        let low = light(elevation: 8)

        XCTAssertGreaterThan(
            luminance(high.shadeRoofLinear(albedo: albedo)),
            luminance(low.shadeRoofLinear(albedo: albedo))
        )
    }

    // MARK: - Shadows

    func testShadowsLengthenAsTheSunDropsAndAreClampedAtTheHorizon() {
        let steep = light(elevation: 60).shadowLength
        let middle = light(elevation: 20).shadowLength
        let low = light(elevation: 10).shadowLength

        XCTAssertLessThan(steep, middle)
        XCTAssertLessThan(middle, low)

        for elevation in [3.0, 2.2, 0.5, -1.0, -20.0] {
            let length = light(elevation: elevation).shadowLength
            XCTAssertTrue(length.isFinite, "shadow length ran away at \(elevation)°")
            XCTAssertLessThanOrEqual(length, 7.5,
                                     "shadow length must be clamped, not run to infinity")
        }

        XCTAssertEqual(light(elevation: 2.5).shadowLength, 7.5, accuracy: 1e-9)
    }

    func testShadowRunsOppositeTheSunDirection() {
        let sun = light(elevation: 30, azimuth: 135, mapRotation: 0.4)
        XCTAssertEqual(sun.shadowDirX, -sun.sunX, accuracy: 1e-12)
        XCTAssertEqual(sun.shadowDirY, -sun.sunY, accuracy: 1e-12)
        XCTAssertEqual((sun.sunX * sun.sunX + sun.sunY * sun.sunY).squareRoot(), 1,
                       accuracy: 1e-12)
    }

    func testMapRotationTurnsTheSunWithTheMap() {
        let unrotated = light(elevation: 30, azimuth: 90, mapRotation: 0)
        let rotated = light(elevation: 30, azimuth: 90, mapRotation: .pi / 2)

        // A quarter turn of the map takes (1, 0) to (0, 1).
        XCTAssertEqual(unrotated.sunX, 1, accuracy: 1e-12)
        XCTAssertEqual(unrotated.sunY, 0, accuracy: 1e-12)
        XCTAssertEqual(rotated.sunX, 0, accuracy: 1e-12)
        XCTAssertEqual(rotated.sunY, 1, accuracy: 1e-12)
    }
}
