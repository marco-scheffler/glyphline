import CoreGraphics
import Foundation

/// The city on the ground: OpenStreetMap footprints extruded into buildings,
/// with their shadows, over the water, wood and grass polygons that surround
/// them.
///
/// Nothing here is invented. Every building is a real footprint with its tagged
/// height, every area a real polygon. Monaco alone carries 951 buildings with
/// 5 368 vertices, so this is a once-per-cache-key pass and never a per-frame
/// one — it is written to be correct rather than fast.
///
/// The extrusion is an oblique projection: what is high slides up the image.
/// Draw order is load-bearing — areas, then shadows, then the buildings — because
/// a shadow drawn over its own building reads as dirt rather than as light.
///
/// The context is expected to be in a y-down, top-left user space, the space
/// `CircuitFit` maps into, and to be backed by sRGB. `SceneLight` hands out
/// colours that have already been through the tone curve and the sRGB transfer
/// function; a context in any other space would convert on top of that and undo
/// the whole lighting pipeline at the very last step, which then gets debugged
/// in the lighting file instead of here.
enum SceneryLayer {
    /// How far a metre of height leans up the screen. The same constant governs
    /// the terrain's own lift, which is what makes Monaco climb its hill.
    private static let lean = 0.62

    /// - Parameters:
    ///   - fit: The metre-to-canvas mapping; its `scale` is the pixels-per-metre
    ///     the JS reference calls `MPP`.
    ///   - time: Phase of the water ripple, in seconds. Constant per cache key.
    static func draw(
        into context: CGContext,
        scenery: CircuitScenery,
        light: SceneLight,
        fit: CircuitFit,
        time: Double = 0
    ) {
        let prepared = Prepared(scenery: scenery, fit: fit)
        guard !prepared.areas.isEmpty || !prepared.buildings.isEmpty else { return }
        let mpp = Double(fit.scale)

        drawAreas(into: context, areas: prepared.areas, light: light, mpp: mpp, time: time)
        drawShadows(into: context, buildings: prepared.buildings, light: light)
        drawBuildings(into: context, buildings: prepared.buildings, light: light, mpp: mpp)
    }

    // MARK: - Preparation

    private struct Building {
        var ring: [CGPoint]
        /// Screen-space height of the extrusion, in points.
        var lift: CGFloat
        var seed: UInt32
        var wall: SIMD3<Double>
        var roof: SIMD3<Double>
    }

    private struct Area {
        var ring: [CGPoint]
        var kind: String
    }

    private struct Prepared {
        var buildings: [Building] = []
        var areas: [Area] = []

        init(scenery: CircuitScenery, fit: CircuitFit) {
            let mpp = Double(fit.scale)

            // Largest first, so a lake does not paint over the wood on its bank.
            areas = scenery.areas
                .sorted { $0.a > $1.a }
                .compactMap { area in
                    let ring = area.p.map(fit.point)
                    return ring.count >= 3 ? Area(ring: ring, kind: area.k) : nil
                }

            buildings = scenery.buildings.enumerated().compactMap { index, source in
                var ring = source.p.map(fit.point)
                guard ring.count >= 3 else { return nil }
                // One winding for every footprint, so the wall cull below can be
                // a single sign test instead of a per-building special case.
                if signedArea(ring) < 0 { ring.reverse() }

                // A city does not have one grey. Wall and roof tone are hashed
                // from the index — deterministic, so the same house keeps its
                // colour across restarts.
                let seed = UInt32(truncatingIfNeeded: (index + 1) &* 2_654_435_761)
                let v = Double(seed % 1000) / 1000
                let warm = Double((seed >> 10) % 1000) / 1000

                return Building(
                    ring: ring,
                    lift: CGFloat(source.h * mpp * lean),
                    seed: seed,
                    wall: SIMD3(138 + v * 34, 131 + v * 32 - warm * 6, 121 + v * 30 - warm * 14),
                    roof: SIMD3(104 + v * 40, 99 + v * 36 - warm * 8, 93 + v * 32 - warm * 16)
                )
            }
            // Painter's algorithm: what is lower on the screen stands in front,
            // so it has to be drawn last.
            .sorted { ($0.ring.map(\.y).max() ?? 0) < ($1.ring.map(\.y).max() ?? 0) }
        }
    }

    private static func signedArea(_ ring: [CGPoint]) -> Double {
        var total = 0.0
        for i in ring.indices {
            let j = (i + 1) % ring.count
            total += Double(ring[i].x * ring[j].y - ring[j].x * ring[i].y)
        }
        return total * 0.5
    }

    // MARK: - Shadows

    private static func drawShadows(into context: CGContext, buildings: [Building], light: SceneLight) {
        // Below this the shadow is not a shadow any more, only a cost.
        guard light.shadowAlpha >= 0.02, !buildings.isEmpty else { return }
        // Core Graphics has no canvas-style blur filter, so the silhouettes are
        // rasterised into an alpha mask, that mask is blurred, and the result is
        // composited once. Doing it per building with `setShadow` would put the
        // blur in base space, whose relation to this context's flipped user space
        // is exactly the kind of thing that is wrong only at certain scales.
        guard let mask = shadowMask(context: context, buildings: buildings, light: light) else {
            return
        }
        context.saveGState()
        // Composite in device space: the mask was rasterised there.
        context.concatenate(context.ctm.inverted())
        context.draw(mask.image, in: mask.deviceRect)
        context.restoreGState()
    }

    private static func shadowMask(
        context: CGContext, buildings: [Building], light: SceneLight
    ) -> (image: CGImage, deviceRect: CGRect)? {
        // The destination's own pixel grid, not its clip box: an unclipped
        // context reports an infinite bounding box, and sizing a mask from that
        // silently drops every shadow in the scene.
        let width = context.width, height = context.height
        let ctm = context.ctm
        let deviceRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0, width * height <= 64_000_000 else { return nil }

        // An 8-bit grey coverage mask rather than an alpha-only one: Swift's
        // `CGContext` initialiser will not take the null colour space that an
        // alpha-only bitmap requires. White is full shadow, black is none.
        guard let alpha = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Same user space as the caller, so the silhouettes land on the same
        // pixels they will be composited onto.
        alpha.concatenate(ctm)
        // Filled per building at the shadow's own alpha, exactly as the
        // reference does, so overlapping casters darken each other.
        alpha.setFillColor(gray: 1, alpha: light.shadowAlpha)

        // The offsets are in the caller's user space, so they come from the
        // screen-space lift rather than from device pixels.
        for building in buildings {
            let ring = building.ring
            // lift = h * mpp * lean, and the shadow wants h * mpp, so the lean
            // divides straight back out.
            let travel = Double(building.lift) / lean * light.shadowLength
            let dx = CGFloat(light.shadowDirX * travel)
            // Foreshortened in y: the ground recedes in this projection.
            let dy = CGFloat(light.shadowDirY * travel * 0.55)

            // The footprint at the shadow's far end, plus one quad per edge to
            // join it back to the caster. Every piece is wound the same way
            // first: under the nonzero rule the trailing and leading edges of a
            // footprint come out with opposite windings and cancel each other
            // into a hole through the middle of the shadow.
            let path = CGMutablePath()
            addPositively(ring.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, to: path)
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                addPositively([
                    a, b,
                    CGPoint(x: b.x + dx, y: b.y + dy),
                    CGPoint(x: a.x + dx, y: a.y + dy),
                ], to: path)
            }
            alpha.addPath(path)
            alpha.fillPath()
        }

        guard let data = alpha.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: alpha.bytesPerRow * height)
        var mask = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                mask[row * width + column] = buffer[row * alpha.bytesPerRow + column]
            }
        }

        let blurPixels = light.shadowBlur > 0.2
            ? (1.2 + light.shadowBlur * 4) * Double(scaleOf(ctm: ctm, unit: 1))
            : 0
        if blurPixels > 0.5 {
            let radius = max(1, Int((blurPixels / 2).rounded()))
            // Two box passes: close enough to a Gaussian for a shadow, and it
            // needs no framework beyond arithmetic.
            for _ in 0..<2 {
                boxBlur(&mask, width: width, height: height, radius: radius)
            }
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            // Premultiplied black: only the alpha carries the shadow.
            rgba[index * 4 + 3] = mask[index]
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let out = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let target = out.data
        else { return nil }

        let targetBuffer = target.bindMemory(to: UInt8.self, capacity: out.bytesPerRow * height)
        for row in 0..<height {
            for byte in 0..<(width * 4) {
                targetBuffer[row * out.bytesPerRow + byte] = rgba[row * width * 4 + byte]
            }
        }
        guard let image = out.makeImage() else { return nil }
        return (image, deviceRect)
    }

    /// How many device pixels one user-space unit covers.
    private static func scaleOf(ctm: CGAffineTransform, unit: CGFloat) -> CGFloat {
        let determinant = abs(ctm.a * ctm.d - ctm.b * ctm.c)
        return unit * (determinant > 0 ? determinant.squareRoot() : 1)
    }

    private static func boxBlur(_ buffer: inout [UInt8], width: Int, height: Int, radius: Int) {
        var scratch = [UInt8](repeating: 0, count: width * height)
        let window = radius * 2 + 1

        for row in 0..<height {
            var sum = 0
            for offset in -radius...radius {
                sum += Int(buffer[row * width + min(width - 1, max(0, offset))])
            }
            for column in 0..<width {
                scratch[row * width + column] = UInt8(sum / window)
                let leaving = min(width - 1, max(0, column - radius))
                let entering = min(width - 1, max(0, column + radius + 1))
                sum += Int(buffer[row * width + entering]) - Int(buffer[row * width + leaving])
            }
        }

        for column in 0..<width {
            var sum = 0
            for offset in -radius...radius {
                sum += Int(scratch[min(height - 1, max(0, offset)) * width + column])
            }
            for row in 0..<height {
                buffer[row * width + column] = UInt8(sum / window)
                let leaving = min(height - 1, max(0, row - radius))
                let entering = min(height - 1, max(0, row + radius + 1))
                sum += Int(scratch[entering * width + column]) - Int(scratch[leaving * width + column])
            }
        }
    }

    // MARK: - Buildings

    private static func drawBuildings(
        into context: CGContext, buildings: [Building], light: SceneLight, mpp: Double
    ) {
        for building in buildings {
            let ring = building.ring
            let lift = building.lift

            for i in ring.indices {
                let a = ring[i], q = ring[(i + 1) % ring.count]
                let dx = q.x - a.x, dy = q.y - a.y
                // Walls whose edge runs to the right belong to the far side of
                // the footprint and are hidden behind the block itself.
                if dx >= 0 { continue }
                let length = Double(hypot(dx, dy))
                let unit = CGFloat(length == 0 ? 1 : length)
                let nx = Double(dy / unit), ny = Double(-dx / unit)

                context.setFillColor(color(light.encodeSRGB(
                    light.shadeWallLinear(normalX: nx, normalY: ny, albedo: building.wall)
                )))
                let wall = CGMutablePath()
                wall.addLines(between: [
                    a, q,
                    CGPoint(x: q.x, y: q.y - lift),
                    CGPoint(x: a.x, y: a.y - lift),
                ])
                wall.closeSubpath()
                context.addPath(wall)
                context.fillPath()

                if light.night > 0.05 && lift > 4 {
                    drawWindows(
                        into: context, light: light, seed: building.seed,
                        anchor: a, dx: dx, dy: dy, edgeLength: length, lift: lift, mpp: mpp
                    )
                }
            }

            let roof = CGMutablePath()
            roof.addLines(between: ring.map { CGPoint(x: $0.x, y: $0.y - lift) })
            roof.closeSubpath()
            context.setFillColor(color(light.encodeSRGB(light.shadeRoofLinear(albedo: building.roof))))
            context.addPath(roof)
            context.fillPath()

            // A hairline where roof meets sky: without it a block of flat roofs
            // merges into one grey field.
            if lift > 2.5 {
                context.setStrokeColor(gray: 0, alpha: 0.10 + 0.12 * light.diffuse)
                context.setLineWidth(max(0.5, CGFloat(mpp * 0.35)))
                context.addPath(roof)
                context.strokePath()
            }
        }
    }

    private static func drawWindows(
        into context: CGContext, light: SceneLight, seed: UInt32,
        anchor: CGPoint, dx: CGFloat, dy: CGFloat, edgeLength: Double,
        lift: CGFloat, mpp: Double
    ) {
        let columns = max(1, Int(edgeLength / (5.4 * mpp)))
        let rows = max(1, Int(Double(lift) / (3.4 * mpp)))
        let ux = dx / CGFloat(columns), uy = dy / CGFloat(columns)
        let vy = lift / CGFloat(rows)

        for column in 0..<columns {
            for row in 0..<rows {
                let hash = seed
                    ^ UInt32(truncatingIfNeeded: column &* 73_856_093)
                    ^ UInt32(truncatingIfNeeded: row &* 19_349_663)
                // A little over half the windows are dark; a fully lit facade
                // reads as a lightbox, not as a building at night.
                if hash % 100 > 46 { continue }
                let x = anchor.x + ux * (CGFloat(column) + 0.28)
                let y = anchor.y + uy * (CGFloat(column) + 0.28)
                let srgb = light.encodeSRGB(SceneLight.linearFromSRGB(
                    SIMD3(255, 200 + Double(hash % 40), 140 + Double(hash % 50))
                ) * 0.55)
                context.setFillColor(color(srgb, alpha: 0.34 + 0.52 * light.night))
                context.fill(CGRect(
                    x: x,
                    y: y - lift + CGFloat(row) * vy + vy * 0.30,
                    width: max(1, abs(ux) * 0.44),
                    height: max(1, vy * 0.38)
                ))
            }
        }
    }

    // MARK: - Areas

    private static func drawAreas(
        into context: CGContext, areas: [Area], light: SceneLight, mpp: Double, time: Double
    ) {
        for area in areas {
            switch area.kind {
            case "water": drawWater(into: context, area: area, light: light, mpp: mpp, time: time)
            case "wood": drawWood(into: context, area: area, light: light, mpp: mpp)
            default:
                context.setFillColor(color(
                    light.encodeSRGB(light.shadeRoofLinear(albedo: SIMD3(98, 120, 70))),
                    alpha: 0.88
                ))
                context.addPath(ringPath(area.ring))
                context.fillPath()
            }
        }
    }

    private static func drawWater(
        into context: CGContext, area: Area, light: SceneLight, mpp: Double, time: Double
    ) {
        let lit = light.encodeSRGB(light.shadeRoofLinear(
            albedo: light.night > 0.5 ? SIMD3(26, 44, 78) : SIMD3(40, 92, 130)
        ))
        // Water is bluer and brighter than the same albedo on land would be: it
        // is mostly reflected sky.
        context.setFillColor(color(SIMD3(lit.x * 1.2, lit.y * 1.2, lit.z * 1.35)))
        let path = ringPath(area.ring)
        context.addPath(path)
        context.fillPath()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setStrokeColor(color(SIMD3(255, 246, 224), alpha: 0.03 + 0.13 * light.direct))
        context.setLineWidth(max(1, CGFloat(mpp * 0.8)))
        let ys = area.ring.map(\.y)
        let step = CGFloat(7 * max(1, mpp))
        var y = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        while y < maxY {
            let wave = CGFloat(sin(time * 0.55 + Double(y) * 0.09) * 3 * max(1, mpp))
            context.move(to: CGPoint(x: -9999, y: y + wave))
            context.addLine(to: CGPoint(x: 9999, y: y + wave))
            context.strokePath()
            y += step
        }
        context.restoreGState()
    }

    private static func drawWood(
        into context: CGContext, area: Area, light: SceneLight, mpp: Double
    ) {
        context.setFillColor(color(light.encodeSRGB(light.shadeRoofLinear(albedo: SIMD3(58, 84, 46)))))
        let path = ringPath(area.ring)
        context.addPath(path)
        context.fillPath()

        context.saveGState()
        context.addPath(path)
        context.clip()

        let xs = area.ring.map(\.x), ys = area.ring.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let step = CGFloat(max(5, 9 * mpp))
        let crown = light.encodeSRGB(light.shadeRoofLinear(albedo: SIMD3(88, 124, 62)))
        let dark = light.encodeSRGB(light.shadeRoofLinear(albedo: SIMD3(34, 52, 28)))

        // Canopy as jittered discs rather than a flat green field: a wood at this
        // scale is texture, and the texture is what stops it reading as a lawn.
        var k: UInt32 = 0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                let hash = UInt32(truncatingIfNeeded: k &* 2_654_435_761)
                k &+= 1
                let jx = x + CGFloat(Double(hash % 100) / 100) * step
                let jy = y + CGFloat(Double((hash >> 7) % 100) / 100) * step
                let radius = step * CGFloat(0.36 + Double(hash % 37) / 120)

                context.setFillColor(color(dark, alpha: 0.55))
                context.fillEllipse(in: CGRect(
                    x: jx + CGFloat(light.shadowDirX) * radius * 0.5 - radius,
                    y: jy + CGFloat(light.shadowDirY) * radius * 0.3 - radius,
                    width: radius * 2, height: radius * 2
                ))
                context.setFillColor(color(crown, alpha: 0.9))
                let crownRadius = radius * 0.82
                context.fillEllipse(in: CGRect(
                    x: jx - crownRadius, y: jy - radius * 0.25 - crownRadius,
                    width: crownRadius * 2, height: crownRadius * 2
                ))
                x += step
            }
            y += step
        }
        context.restoreGState()
    }

    // MARK: - Small helpers

    /// Adds a polygon wound so its signed area is positive, which is what makes
    /// the nonzero fill rule produce a union rather than a difference.
    private static func addPositively(_ points: [CGPoint], to path: CGMutablePath) {
        path.addLines(between: signedArea(points) < 0 ? points.reversed() : points)
        path.closeSubpath()
    }

    private static func ringPath(_ ring: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: ring)
        path.closeSubpath()
        return path
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// sRGB 0…255 as `SceneLight` hands it out, into a colour that is explicitly
    /// tagged sRGB. Letting Core Graphics infer the space is how a correct
    /// tone curve ends up looking like a lighting bug.
    private static func color(_ srgb: SIMD3<Double>, alpha: Double = 1) -> CGColor {
        let components: [CGFloat] = [
            CGFloat(min(255, max(0, srgb.x)) / 255),
            CGFloat(min(255, max(0, srgb.y)) / 255),
            CGFloat(min(255, max(0, srgb.z)) / 255),
            CGFloat(min(1, max(0, alpha))),
        ]
        if let sRGB, let color = CGColor(colorSpace: sRGB, components: components) {
            return color
        }
        return CGColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }
}
