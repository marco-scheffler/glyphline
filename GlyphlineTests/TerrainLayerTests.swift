import CoreGraphics
import XCTest
@testable import Glyphline

/// A shader can only be tested honestly on its pixels, so these tests render a
/// small synthetic terrain and compare pixels against each other. They assert
/// relative brightness, never an absolute triple: an exact RGB value would break
/// on any deliberate change to the light and say nothing about whether the hill
/// still looks like a hill.
final class TerrainLayerTests: XCTestCase {
    private let ground = SIMD3<Double>(88, 104, 64)

    private func light(elevation: Double, azimuth: Double = 90) -> SceneLight {
        SceneLight.make(
            elevation: elevation,
            azimuth: azimuth,
            mapRotation: 0,
            weather: .clear
        )
    }

    /// A ridge running north-south: the ground climbs to the middle column and
    /// falls again, so the two flanks face opposite ways in x.
    private func ridge(width: Int = 21, height: Int = 11, sea: [Int]? = nil) -> CircuitTerrain {
        var terrain = CircuitTerrain()
        terrain.minX = 0
        terrain.minY = 0
        terrain.maxX = Double(width) * 10
        terrain.maxY = Double(height) * 10
        terrain.gw = width
        terrain.gh = height
        let mid = width / 2
        var grid: [Int] = []
        for _ in 0..<height {
            for x in 0..<width {
                grid.append((mid - abs(x - mid)) * 12)
            }
        }
        terrain.grid = grid
        terrain.lo = 0
        terrain.hi = Double(mid * 12)
        terrain.sea = sea
        return terrain
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private func luminance(_ image: CGImage, x: Int, y: Int) -> Double {
        let data = pixels(image)
        let i = (y * image.width + x) * 4
        return 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
    }

    // MARK: - Shape

    /// Catches a rasteriser that renders at canvas resolution instead of the
    /// grid's own — the whole reason this layer is affordable.
    func testImageHasTheGridsOwnResolution() {
        let terrain = ridge()
        let image = TerrainLayer.image(terrain: terrain, light: light(elevation: 30), ground: ground)
        XCTAssertEqual(image?.width, terrain.gw)
        XCTAssertEqual(image?.height, terrain.gh)
    }

    /// Catches a crash or a zero-sized context on a circuit whose terrain never
    /// decoded.
    func testDegenerateTerrainReturnsNil() {
        XCTAssertNil(TerrainLayer.image(terrain: CircuitTerrain(), light: light(elevation: 30), ground: ground))

        var truncated = ridge()
        truncated.grid = []
        XCTAssertNil(TerrainLayer.image(terrain: truncated, light: light(elevation: 30), ground: ground))
    }

    // MARK: - Hillshading

    /// The core of the layer. At azimuth 90 the key light's scene-space vector
    /// points along +x, so the ridge's far flank — the one whose normal has a
    /// positive x component — must come out brighter than the near one, and the
    /// order must reverse when the sun moves to the opposite azimuth. Catches a
    /// sign error in the normal or a dropped Lambert term, either of which
    /// flattens the terrain without producing an obviously broken image.
    func testSlopeFacingTheSunIsBrighter() {
        let terrain = ridge()
        let y = terrain.gh / 2
        let nearX = 4, farX = terrain.gw - 5

        let east = try! XCTUnwrap(
            TerrainLayer.image(terrain: terrain, light: light(elevation: 25, azimuth: 90), ground: ground)
        )
        XCTAssertGreaterThan(luminance(east, x: farX, y: y), luminance(east, x: nearX, y: y))

        let west = try! XCTUnwrap(
            TerrainLayer.image(terrain: terrain, light: light(elevation: 25, azimuth: 270), ground: ground)
        )
        XCTAssertGreaterThan(luminance(west, x: nearX, y: y), luminance(west, x: farX, y: y))
    }

    /// A high sun lights the flanks differently from a low one. Catches a layer
    /// that ignores the light it was handed.
    func testLowSunDiffersFromHighSun() {
        let terrain = ridge()
        let y = terrain.gh / 2
        let low = try! XCTUnwrap(TerrainLayer.image(terrain: terrain, light: light(elevation: 6), ground: ground))
        let high = try! XCTUnwrap(TerrainLayer.image(terrain: terrain, light: light(elevation: 60), ground: ground))
        XCTAssertNotEqual(luminance(low, x: 4, y: y), luminance(high, x: 4, y: y), accuracy: 0)
    }

    // MARK: - Water

    /// Sea cells take a different path entirely. Catches a sea mask that is read
    /// but not acted on — the inland circuits would look identical either way.
    func testSeaCellDiffersFromLandCellAtTheSameElevation() {
        let terrain = ridge()
        var mask = [Int](repeating: 0, count: terrain.gw * terrain.gh)
        let y = terrain.gh / 2
        let seaX = 3
        mask[y * terrain.gw + seaX] = 1
        var withSea = terrain
        withSea.sea = mask

        let sceneLight = light(elevation: 25)
        let land = try! XCTUnwrap(TerrainLayer.image(terrain: terrain, light: sceneLight, ground: ground))
        let water = try! XCTUnwrap(TerrainLayer.image(terrain: withSea, light: sceneLight, ground: ground))

        XCTAssertEqual(luminance(land, x: seaX + 4, y: y), luminance(water, x: seaX + 4, y: y), accuracy: 0.5)
        XCTAssertNotEqual(luminance(land, x: seaX, y: y), luminance(water, x: seaX, y: y), accuracy: 1.0)
    }
}
