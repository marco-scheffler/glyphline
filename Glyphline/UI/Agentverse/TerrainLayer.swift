import CoreGraphics
import Foundation

/// The ground under the circuit: hillshaded elevation, and water where the
/// circuit meets the sea.
///
/// The image is rasterised at the grid's own resolution — 150 × 105 for every
/// circuit we ship — and scaled up by whoever draws it. Shading one pixel per
/// canvas pixel would cost orders of magnitude more for a gradient field that
/// carries no detail beyond its cells.
enum TerrainLayer {
    /// - Parameters:
    ///   - terrain: Elevation grid, row-major, in metres.
    ///   - light: The instant's lighting. Its `keyElevation` is in degrees.
    ///   - ground: The circuit's ground albedo as sRGB 0…255.
    /// - Returns: A `gw × gh` image, or nil for a degenerate grid.
    static func image(
        terrain: CircuitTerrain,
        light: SceneLight,
        ground: SIMD3<Double>
    ) -> CGImage? {
        let gw = terrain.gw
        let gh = terrain.gh
        guard gw > 0, gh > 0, terrain.grid.count >= gw * gh else { return nil }

        let grid = terrain.grid
        let mx = (terrain.maxX - terrain.minX) / Double(gw)
        let my = (terrain.maxY - terrain.minY) / Double(gh)
        let range = max(1, terrain.hi - terrain.lo)
        let groundLinear = SceneLight.linearFromSRGB(ground)

        let keyElevation = max(0, light.keyElevation) * .pi / 180
        // A floor under the sine: at a grazing sun the terrain would otherwise
        // lose its ambient footing entirely and go flat black.
        let sinEl = max(0.05, sin(keyElevation))
        let cosEl = cos(keyElevation)

        let sea = terrain.sea
        // Deep water swallows nearly everything; what is left is the reflected
        // sky plus the sun's track on it.
        let water = SceneLight.linearFromSRGB(SIMD3(9, 26, 42))

        var pixels = [UInt8](repeating: 255, count: gw * gh * 4)

        for y in 0..<gh {
            for x in 0..<gw {
                let idx = y * gw + x
                let linear: SIMD3<Double>

                if let sea, idx < sea.count, sea[idx] != 0 {
                    // Ripple as a normal perturbation — this is what makes the
                    // sun's reflection a track instead of a blob.
                    let rip = sin(Double(x) * 0.55 + Double(y) * 0.31) * 0.10
                        + sin(Double(x) * 0.17 - Double(y) * 0.44) * 0.07
                    let nx = rip, ny = rip * 0.6
                    let nl = (nx * nx + ny * ny + 1).squareRoot()
                    let hdotn = max(
                        0,
                        (nx / nl) * light.sunX * cosEl
                            + (ny / nl) * light.sunY * cosEl
                            + (1 / nl) * sinEl
                    )
                    let glint = pow(hdotn, 90) * light.direct * 5.0
                    // A flat view reflects more.
                    let refl = 0.34 + 0.22 * (1 - sinEl)
                    linear = water * light.ambientLinear * light.diffuse
                        + light.skyLinear * (refl * light.diffuse)
                        + light.sunLinear * glint
                } else {
                    let xm = max(0, x - 1), xp = min(gw - 1, x + 1)
                    let ym = max(0, y - 1), yp = min(gh - 1, y + 1)
                    let dzdx = Double(grid[y * gw + xp] - grid[y * gw + xm])
                        / (Double(xp - xm) * mx)
                    let dzdy = Double(grid[yp * gw + x] - grid[ym * gw + x])
                        / (Double(yp - ym) * my)
                    // Normal (-dz/dx, -dz/dy, 1), normalised.
                    let len = (dzdx * dzdx + dzdy * dzdy + 1).squareRoot()
                    let nx = -dzdx / len, ny = -dzdy / len, nz = 1 / len
                    let lambert = max(0, nx * light.sunX * cosEl + ny * light.sunY * cosEl + nz * sinEl)
                    let h = (Double(grid[idx]) - terrain.lo) / range
                    // Height brightens slightly — tops catch more sky.
                    let tint = 0.90 + h * 0.22
                    let kd = light.diffuse * tint
                    let ks = light.direct * lambert
                    linear = groundLinear * (light.ambientLinear * kd + light.sunLinear * ks)
                }

                let srgb = light.encodeSRGB(linear)
                let i = idx * 4
                pixels[i] = channel(srgb.x)
                pixels[i + 1] = channel(srgb.y)
                pixels[i + 2] = channel(srgb.z)
            }
        }

        // Explicitly sRGB: the encode above already applied the tone curve and
        // the sRGB transfer function, so any other colour space would convert on
        // top of it and undo the whole pipeline at the last step.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: gw,
            height: gh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        guard let buffer = context.data else { return nil }
        let rowBytes = context.bytesPerRow
        pixels.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<gh {
                buffer.advanced(by: row * rowBytes)
                    .copyMemory(from: base.advanced(by: row * gw * 4), byteCount: gw * 4)
            }
        }
        return context.makeImage()
    }

    private static func channel(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8(min(255, max(0, value.rounded())))
    }
}
