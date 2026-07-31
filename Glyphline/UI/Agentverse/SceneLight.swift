import Foundation
import SwiftUI

/// The weather over the circuit. It is a light model, not a particle system:
/// cloud takes the sun away and gives it back as sky, rain takes nearly all of
/// the direct light, fog does the same but keeps more bounce.
enum Weather: String, CaseIterable, Sendable {
    case clear
    case cloud
    case rain
    case fog

    /// How much of the direct sun survives to the ground.
    var directFactor: Double {
        switch self {
        case .clear: return 1.00
        case .cloud: return 0.34
        case .rain: return 0.10
        case .fog: return 0.16
        }
    }

    /// How much the sky bounces back. Overcast is *more* than clear: the whole
    /// dome becomes the light source.
    var diffuseFactor: Double {
        switch self {
        case .clear: return 1.00
        case .cloud: return 1.18
        case .rain: return 1.02
        case .fog: return 1.12
        }
    }

    var shadowFactor: Double {
        switch self {
        case .clear: return 1.00
        case .cloud: return 0.34
        case .rain: return 0.10
        case .fog: return 0.14
        }
    }

    var shadowBlurFactor: Double {
        switch self {
        case .clear: return 0.10
        case .cloud: return 0.55
        case .rain: return 0.85
        case .fog: return 0.90
        }
    }
}

/// The lighting model for one instant over one circuit: a linear working space,
/// output in sRGB, with a filmic tone curve in between.
///
/// Multiplying sRGB values together directly is the mistake that makes a scene
/// look like a toy: light adds up in a space where 128 is not half of 255, and
/// without tonemapping everything bright clips hard to white. Monaco's pale
/// backdrop showed it first.
///
/// So: albedo and light colours go to linear, the arithmetic happens there,
/// one single exposure scales it, the ACES curve takes it out, and back to
/// sRGB. Highlights roll off softly, shadows keep their drawing.
///
/// Night is not a gamma lift any more but a change of exposure — what a camera
/// would do. The tone curve is what stops the window lights burning out.
struct SceneLight: Sendable {
    /// The elevation the key light is actually shaded from. Below the horizon
    /// this is the moon's, so the scene does not go flat at dusk.
    let keyElevation: Double
    /// Strength of the direct key light, sun or moon.
    let direct: Double
    /// Strength of the sky's ambient contribution.
    let diffuse: Double

    let sunLinear: SIMD3<Double>
    let skyLinear: SIMD3<Double>
    let ambientLinear: SIMD3<Double>

    /// The one exposure. Not spread over materials — exactly one knob.
    let exposure: Double

    /// Direction the sunlight travels, in scene space, unit length.
    let sunX: Double
    let sunY: Double
    /// Direction a shadow is cast, which is the opposite.
    let shadowDirX: Double
    let shadowDirY: Double
    /// Shadow length as a multiple of the caster's height, clamped so it does
    /// not run to infinity as the sun touches the horizon.
    let shadowLength: Double
    let shadowAlpha: Double
    let shadowBlur: Double

    /// 0 by day, 1 at night, with a smooth crossing around the horizon.
    let night: Double
    let weather: Weather

    // MARK: - Construction

    /// - Parameters:
    ///   - elevation: Solar elevation in degrees, as `SunPosition` returns it.
    ///   - azimuth: Solar azimuth in degrees clockwise from north, as
    ///     `SunPosition` returns it. `SunPosition` applies no rotation into
    ///     scene space; that happens here.
    ///   - mapRotation: `Circuit.rot`, in radians — how far the map was spun to
    ///     lay the circuit's long axis flat. Turning the sun by the same angle
    ///     is what puts it back where it belongs.
    static func make(
        elevation: Double,
        azimuth: Double,
        mapRotation: Double,
        weather: Weather
    ) -> SceneLight {
        let el = elevation
        let night = smooth(6, -6, el)

        let above = max(0, sin(el * .pi / 180))
        // Light through more atmosphere at a low angle: extinction, not a fade.
        let extinction = smooth(-2.5, 7, el)
        let directSun = above * extinction * weather.directFactor
        let directMoon = 0.14 * night * weather.directFactor
        let direct = max(directSun, directMoon)

        let dayDiffuse = 0.10 + 0.42 * smooth(-9, 14, el)
        let diffuse = max(dayDiffuse, nightFloor) * weather.diffuseFactor

        let azimuthRadians = azimuth * .pi / 180
        let worldX = sin(azimuthRadians)
        let worldY = -cos(azimuthRadians)
        let sunX = worldX * cos(mapRotation) - worldY * sin(mapRotation)
        let sunY = worldX * sin(mapRotation) + worldY * cos(mapRotation)

        let keyElevation = el > 2 ? el : moonElevation * night + max(2.2, el) * (1 - night)
        let shadowLength = min(7.5, 1 / tan(max(2.2, keyElevation) * .pi / 180))

        let sun = mix(sunTint(elevation: el), moonTint, night)
        let sky = skyTint(elevation: el, weather: weather, night: night)
        let ambient = mix(
            mix(sky, SIMD3(150, 170, 200), 0.35),
            SIMD3(104, 130, 176),
            night * 0.75
        )

        return SceneLight(
            keyElevation: keyElevation,
            direct: direct,
            diffuse: diffuse,
            sunLinear: linearFromSRGB(sun),
            skyLinear: linearFromSRGB(sky),
            ambientLinear: linearFromSRGB(ambient),
            exposure: baseExposure * (1 + nightExposure * night),
            sunX: sunX,
            sunY: sunY,
            shadowDirX: -sunX,
            shadowDirY: -sunY,
            shadowLength: shadowLength,
            shadowAlpha: max(0.13 * night, 0.16 + 0.40 * smooth(0, 22, el)) * weather.shadowFactor,
            shadowBlur: max(weather.shadowBlurFactor, night * 0.5),
            night: night,
            weather: weather
        )
    }

    // MARK: - The one way out of linear space

    /// Everything visible goes through here.
    func encodeSRGB(_ linear: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            SceneLight.srgbFromLinear(SceneLight.aces(linear.x * exposure)),
            SceneLight.srgbFromLinear(SceneLight.aces(linear.y * exposure)),
            SceneLight.srgbFromLinear(SceneLight.aces(linear.z * exposure))
        )
    }

    func encode(_ linear: SIMD3<Double>) -> Color {
        let srgb = encodeSRGB(linear)
        return Color(
            red: min(1, max(0, srgb.x / 255)),
            green: min(1, max(0, srgb.y / 255)),
            blue: min(1, max(0, srgb.z / 255))
        )
    }

    /// The sky is itself a light source and goes through the same curve as
    /// everything else — otherwise it stands next to the scene instead of in it.
    ///
    /// As sRGB 0…255 for the Core Graphics side, and as a `Color` for the
    /// SwiftUI one. Both are the same value; a raw grey in either place is the
    /// one surface in the picture the exposure never reaches, and it shows the
    /// moment night lifts everything around it.
    var skySRGB: SIMD3<Double> { encodeSRGB(skyLinear) }

    var skyColor: Color { encode(skyLinear) }

    /// For things already conceived as finished screen colours (HUD, lines):
    /// through the same curve, so they do not sit apart from the scene.
    ///
    /// The track and its captions are drawn from flat greys but are still in the
    /// picture, and a flat grey is the one thing the night exposure never
    /// reaches — the same mistake the backdrop used to make.
    func emissiveSRGB(_ srgb: SIMD3<Double>, strength: Double = 1) -> SIMD3<Double> {
        encodeSRGB(SceneLight.linearFromSRGB(srgb) * strength)
    }

    func emissive(_ srgb: SIMD3<Double>, strength: Double = 1) -> Color {
        encode(SceneLight.linearFromSRGB(srgb) * strength)
    }

    // MARK: - Shading

    /// Lambert for a vertical wall — in linear space.
    func shadeWallLinear(normalX: Double, normalY: Double, albedo: SIMD3<Double>) -> SIMD3<Double> {
        let a = SceneLight.linearFromSRGB(albedo)
        let cosElevation = cos(max(0, keyElevation) * .pi / 180)
        let lambert = max(0, normalX * sunX + normalY * sunY) * cosElevation
        let kd = diffuse * 0.74
        let ks = direct * lambert
        return a * (ambientLinear * kd + sunLinear * ks)
    }

    /// A roof looks up: the full sky, and the sun by its sine.
    func shadeRoofLinear(albedo: SIMD3<Double>) -> SIMD3<Double> {
        let a = SceneLight.linearFromSRGB(albedo)
        let sinElevation = max(0, sin(max(0, keyElevation) * .pi / 180))
        let ks = direct * sinElevation
        return a * (ambientLinear * diffuse + sunLinear * ks)
    }

    // MARK: - Colour space

    /// sRGB 0…255 to linear 0…1, as a table, because this is called per wall and
    /// per terrain cell — Monaco alone has hundreds of buildings.
    static let srgbToLinearTable: [Double] = (0...255).map { index in
        let v = Double(index) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func linearFromSRGB(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            srgbToLinearTable[tableIndex(srgb.x)],
            srgbToLinearTable[tableIndex(srgb.y)],
            srgbToLinearTable[tableIndex(srgb.z)]
        )
    }

    private static func tableIndex(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return min(255, max(0, Int(value)))
    }

    static func srgbFromLinear(_ value: Double) -> Double {
        let v = value <= 0 ? 0 : value
        return 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }

    /// ACES, Narkowicz's approximation. One line, and it does exactly what is
    /// missing without it: the way into white becomes a curve instead of an edge.
    static func aces(_ x: Double) -> Double {
        let a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14
        let y = (x * (a * x + b)) / (x * (c * x + d) + e)
        return y < 0 ? 0 : (y > 1 ? 1 : y)
    }

    // MARK: - Tints

    static let moonTint = SIMD3<Double>(150, 178, 222)

    static func sunTint(elevation: Double) -> SIMD3<Double> {
        let e = max(-6, elevation)
        let warm = smooth(25, 0, e)
        let base = mix(SIMD3(255, 250, 244), SIMD3(255, 152, 66), warm)
        return mix(base, SIMD3(255, 100, 52), smooth(6, -2, e) * 0.6)
    }

    static func skyTint(elevation e: Double, weather: Weather, night: Double) -> SIMD3<Double> {
        var c: SIMD3<Double>
        if e <= -12 {
            c = SIMD3(13, 20, 38)
        } else if e <= -4 {
            c = mix(SIMD3(13, 20, 38), SIMD3(44, 50, 88), smooth(-12, -4, e))
        } else if e <= 2 {
            c = mix(SIMD3(44, 50, 88), SIMD3(214, 128, 84), smooth(-4, 2, e))
        } else if e <= 12 {
            c = mix(SIMD3(214, 128, 84), SIMD3(136, 184, 226), smooth(2, 12, e))
        } else {
            c = mix(SIMD3(136, 184, 226), SIMD3(86, 152, 214), smooth(12, 55, e))
        }
        switch weather {
        case .clear:
            break
        case .cloud:
            c = mix(c, night > 0.5 ? SIMD3(34, 40, 54) : SIMD3(104, 112, 126), 0.58)
        case .rain:
            c = mix(c, night > 0.5 ? SIMD3(26, 32, 44) : SIMD3(62, 70, 82), 0.78)
        case .fog:
            c = mix(c, night > 0.5 ? SIMD3(46, 54, 68) : SIMD3(168, 176, 186), 0.70)
        }
        return c
    }

    // MARK: - Constants

    /// The ambient never falls below this, so a night scene keeps its drawing.
    private static let nightFloor = 0.22
    /// The elevation the moon is shaded from, regardless of where it really is.
    private static let moonElevation = 34.0
    private static let baseExposure = 1.05
    private static let nightExposure = 2.6

    // MARK: - Small helpers

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }
}
