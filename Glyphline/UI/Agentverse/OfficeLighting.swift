import SwiftUI

/// The daylight the office is drawn under: where the sun really stands over the
/// user's own place at this instant, and what the sky over it is doing.
///
/// It is resolved *outside* the `Canvas` and handed in, exactly as the frame
/// number is. `ImageRenderer` never runs a `.task`, so a snapshot has to be able
/// to render any instant without a clock and without a network; and the solve
/// walks a `Calendar`, which is far too much to repeat sixty times a second for
/// a number that moves by a quarter of a degree a minute.
struct OfficeLighting: Sendable {
    let sun: SolarAngles
    let weather: Weather
    let light: SceneLight

    /// How far the room is turned against the world, in radians — the unit
    /// `SceneLight.make` wants, where the two angles beside it are degrees.
    ///
    /// Zero, and that is a decision rather than an omission: with no rotation
    /// world south maps onto -v, so in the northern hemisphere the noon sun
    /// comes in through the long back wall and the morning sun through the left
    /// one. Both walls carry windows, so the pools on the floor swing from one
    /// to the other across the day.
    static let mapRotation: Double = 0

    static func at(date: Date,
                   place: UserPlace.Coordinates,
                   weather: Weather) -> OfficeLighting {
        // Latitude and longitude in that order and with their own signs: a
        // hemisphere flipped here produces a completely plausible sun that is
        // completely wrong.
        let sun = SunPosition.at(latitude: place.latitude,
                                 longitude: place.longitude,
                                 date: date)
        return OfficeLighting(
            sun: sun,
            weather: weather,
            light: SceneLight.make(elevation: sun.elevation,
                                   azimuth: sun.azimuth,
                                   mapRotation: mapRotation,
                                   weather: weather)
        )
    }

    /// What the windows show: the sky, through the same exposure and tone curve
    /// as everything else in the picture, as sRGB 0…255.
    var windowSkySRGB: SIMD3<Double> { light.skySRGB }

    var windowSkyColor: Color { light.skyColor }

    /// A brighter band of the same sky, for the top of a pane — a window filled
    /// with one flat colour reads as a hole in the wall.
    var windowSkyHighlight: Color { light.encode(light.skyLinear * 1.5) }

    /// How much of the room the desk lamps and monitors are carrying.
    ///
    /// Never zero: the monitors are on at noon too, they are simply overwhelmed.
    /// At night they are the room.
    var interiorLampStrength: Double { 0.16 + 0.84 * light.night }

    /// The break room's own ceiling light, which does not follow the sun at all.
    /// That contrast — a cosy room against a cooling office — is the point.
    var breakRoomLampStrength: Double { 1 }

    /// The direction *towards* the key light in scene space, unit length.
    /// `SceneLight` carries the direction the light travels, which is the
    /// opposite, and its elevation in degrees.
    var sunDirection: (x: Double, y: Double, z: Double) {
        let elevation = max(0, light.keyElevation) * .pi / 180
        let horizontal = cos(elevation)
        return (-light.sunX * horizontal, -light.sunY * horizontal, sin(elevation))
    }
}
