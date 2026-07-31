import CoreGraphics
import XCTest
@testable import Glyphline

/// A renderer can only be tested honestly on its pixels, so these tests draw a
/// tiny synthetic city into a bitmap and compare regions against each other.
/// Every assertion is relative — this side is darker than that one, this shadow
/// moved when the sun moved, a taller building throws a longer one. An exact RGB
/// triple would break on any deliberate change to the light and would say
/// nothing about whether a building still looks like a building.
final class SceneryLayerTests: XCTestCase {
    private let side = 200

    // MARK: - Fixtures

    /// A circuit whose terrain box is a flat 1 000 m square, so `CircuitFit`
    /// frames exactly that box and the metre-to-pixel mapping is easy to reason
    /// about in the assertions below.
    private func circuit() -> Circuit {
        var terrain = CircuitTerrain()
        terrain.minX = 0
        terrain.minY = 0
        terrain.maxX = 1000
        terrain.maxY = 1000
        terrain.gw = 2
        terrain.gh = 2
        terrain.grid = [0, 0, 0, 0]

        var circuit = Circuit(
            name: "Test", location: nil, tz: "UTC", lengthKm: 1,
            lat: 0, lon: 0, rot: 0,
            minX: 0, minY: 0, spanX: 1000, spanY: 1000,
            startIdx: 0, points: [[0, 0]], pit: []
        )
        circuit.terrain = terrain
        return circuit
    }

    private func fit() -> CircuitFit {
        CircuitFit(circuit: circuit(), in: CGSize(width: side, height: side))
    }

    private func light(azimuth: Double, elevation: Double = 25) -> SceneLight {
        SceneLight.make(elevation: elevation, azimuth: azimuth, mapRotation: 0, weather: .clear)
    }

    private func square(centreX: Double, centreY: Double, half: Double) -> [[Double]] {
        [[centreX - half, centreY - half],
         [centreX + half, centreY - half],
         [centreX + half, centreY + half],
         [centreX - half, centreY + half]]
    }

    private func building(height: Double, centreX: Double = 500, centreY: Double = 500) -> CircuitScenery {
        var scenery = CircuitScenery()
        scenery.buildings = [
            CircuitBuilding(p: square(centreX: centreX, centreY: centreY, half: 40), h: height, a: 6400)
        ]
        return scenery
    }

    // MARK: - Rendering

    /// A white canvas in a y-down, top-left user space — the convention
    /// `SceneryLayer` draws in, matching `CircuitFit`'s output.
    private func render(_ scenery: CircuitScenery, light: SceneLight, time: Double = 0) -> Raster {
        // Explicitly sRGB: the layer hands the context colours that have already
        // been through the tone curve and the sRGB transfer function, so any
        // other space would convert on top of that and undo the pipeline.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            SceneryLayer.draw(into: context, scenery: scenery, light: light, fit: fit(), time: time)
        }
        return Raster(pixels: buffer, side: side)
    }

    /// Pixels addressed in the same y-down space the layer draws in.
    private struct Raster {
        let pixels: [UInt8]
        let side: Int

        func rgb(x: Int, y: Int) -> (Double, Double, Double) {
            let row = side - 1 - y
            let i = (row * side + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }

        func luminance(x: Int, y: Int) -> Double {
            let (r, g, b) = rgb(x: x, y: y)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        /// How far the paint reaches from `fromX` in `step` direction, along one row.
        func reach(fromX: Int, y: Int, step: Int) -> Int {
            var distance = 0
            var x = fromX
            while x >= 0 && x < side {
                if luminance(x: x, y: y) < 250 { distance = abs(x - fromX) }
                x += step
            }
            return distance
        }

        var isBlank: Bool {
            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] != 255 {
                return false
            }
            return true
        }
    }

    // MARK: - Buildings

    /// The most basic fact there is: a building puts something on the canvas.
    /// Catches a draw that silently no-ops — a wrong winding cull, an empty
    /// path, a colour that came out white.
    func testABuildingDrawsSomething() {
        let empty = render(CircuitScenery(), light: light(azimuth: 90))
        let city = render(building(height: 30), light: light(azimuth: 90))
        XCTAssertTrue(empty.isBlank)
        XCTAssertFalse(city.isBlank)
    }

    /// Empty scenery must draw nothing and must not crash. Catches a shadow pass
    /// that dirties the canvas before it notices it has nothing to cast.
    func testEmptySceneryDrawsNothing() {
        XCTAssertTrue(render(CircuitScenery(), light: light(azimuth: 90)).isBlank)
    }

    /// With the sun due east the shadow falls west and vice versa. Catches a sign
    /// error in the shadow direction, which is invisible in a still frame and
    /// wrong all day.
    func testShadowFallsAwayFromTheSun() {
        let f = fit()
        let left = Int(f.point([460, 500]).x) - 2
        let right = Int(f.point([540, 500]).x) + 2
        let row = Int(f.point([500, 500]).y)

        let sunEast = render(building(height: 60), light: light(azimuth: 90))
        let sunWest = render(building(height: 60), light: light(azimuth: 270))

        XCTAssertGreaterThan(sunEast.reach(fromX: left, y: row, step: -1),
                             sunEast.reach(fromX: right, y: row, step: 1))
        XCTAssertGreaterThan(sunWest.reach(fromX: right, y: row, step: 1),
                             sunWest.reach(fromX: left, y: row, step: -1))
    }

    /// Shadow length scales with the caster's height. Catches a shadow offset
    /// that dropped the height factor and became a constant smear.
    func testTallerBuildingCastsLongerShadow() {
        let f = fit()
        let left = Int(f.point([460, 500]).x) - 2
        let row = Int(f.point([500, 500]).y)

        let low = render(building(height: 8), light: light(azimuth: 90))
        let tall = render(building(height: 90), light: light(azimuth: 90))

        XCTAssertGreaterThan(tall.reach(fromX: left, y: row, step: -1),
                             low.reach(fromX: left, y: row, step: -1))
    }

    // MARK: - Shadow blur

    /// The reference states its blur as a standard deviation. What the box
    /// passes actually produce has to come back to that number, or the shadows
    /// are a different softness than the picture they were ported from — which
    /// is exactly what reading it as a diameter did.
    func testBoxRadiusCarriesTheRequestedStandardDeviation() {
        // sigma = 1.2 + shadowBlur * 4, at a Retina scale of two.
        for sigma in [6.8, 9.2, 9.6, 3.4, 4.8] {
            for passes in [2, 3] {
                let radius = Double(SceneryLayer.boxRadius(sigma: sigma, passes: passes))
                // n passes of a (2r+1)-wide uniform window: variance n(r²+r)/3.
                let produced = (Double(passes) * (radius * radius + radius) / 3).squareRoot()
                XCTAssertEqual(produced, sigma, accuracy: 0.5,
                               "\(passes) passes at radius \(radius) carry \(produced), "
                               + "not the \(sigma) the reference asked for")
            }
        }
    }

    /// The bug in one line: a radius of sigma/2 is what the old conversion used.
    func testBoxRadiusIsWiderThanHalfTheStandardDeviation() {
        XCTAssertGreaterThan(SceneryLayer.boxRadius(sigma: 9.2, passes: 3), 5)
    }

    // MARK: - Areas

    /// Water, wood and green take three different paths through the shader.
    /// Catches a kind that is read but not acted on — every area would still
    /// render, just all in the same colour.
    func testAreaKindsRenderDifferentColours() {
        let f = fit()
        let sample = f.point([500, 500])
        let x = Int(sample.x), y = Int(sample.y)

        func colour(_ kind: String) -> (Double, Double, Double) {
            var scenery = CircuitScenery()
            scenery.areas = [CircuitArea(p: square(centreX: 500, centreY: 500, half: 200), k: kind, a: 160_000)]
            return render(scenery, light: light(azimuth: 90)).rgb(x: x, y: y)
        }

        let water = colour("water"), wood = colour("wood"), green = colour("green")
        XCTAssertNotEqual(water.0 + water.1 + water.2, wood.0 + wood.1 + wood.2, accuracy: 1)
        XCTAssertNotEqual(water.0 + water.1 + water.2, green.0 + green.1 + green.2, accuracy: 1)
        XCTAssertNotEqual(wood.0 + wood.1 + wood.2, green.0 + green.1 + green.2, accuracy: 1)
    }
}
