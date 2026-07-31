import CoreGraphics
import SwiftUI

/// What a built picture depends on, and nothing else.
///
/// Two things in here are quantised rather than exact. The canvas size is
/// rounded to whole points, because half a point of window drag is not a
/// different picture. The sun is bucketed — two degrees of elevation, five of
/// azimuth — because it moves continuously: an exact elevation would produce a
/// new key on every single frame and the cache would never hit once.
struct StaticSceneKey: Hashable, Sendable {
    let circuit: String
    let width: Int
    let height: Int
    /// Backing-store scale, so a picture built for a Retina window is not served
    /// to a one-to-one one at half the detail it was drawn with.
    let scale: Int
    let elevationBucket: Int
    let azimuthBucket: Int
    let weather: Weather

    static let elevationStep = 2.0
    static let azimuthStep = 5.0

    /// - Parameters:
    ///   - elevation: Solar elevation in degrees.
    ///   - azimuth: Solar azimuth in degrees clockwise from north.
    init(circuit: String, size: CGSize, scale: Int,
         elevation: Double, azimuth: Double, weather: Weather) {
        self.circuit = circuit
        self.width = Int(size.width.rounded())
        self.height = Int(size.height.rounded())
        self.scale = max(1, scale)
        self.elevationBucket = Self.bucket(elevation, step: Self.elevationStep)
        self.azimuthBucket = Self.bucket(azimuth, step: Self.azimuthStep)
        self.weather = weather
    }

    /// The point size the picture was framed for.
    var size: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }

    private static func bucket(_ value: Double, step: Double) -> Int {
        // A NaN elevation would otherwise trap on the conversion to Int, and a
        // scene is not worth a crash.
        guard value.isFinite else { return 0 }
        return Int((value / step).rounded(.down))
    }
}

/// The built pictures, kept by key.
///
/// Building one costs half a second of Debug-build CPU, so it happens off the
/// main actor: `build` runs in a detached task, and only the finished `CGImage`
/// — which Core Graphics declares `Sendable`, being immutable — comes back
/// across. Storing the `Task` rather than the image is what makes a second
/// request arriving while the first is still drawing await that same build
/// instead of starting a rival one.
///
/// Bounded, because an entry is a full-canvas bitmap: a few megabytes for every
/// window size the user has ever dragged through.
@MainActor
final class StaticSceneCache {
    static let shared = StaticSceneCache()

    private let limit: Int
    private var entries: [StaticSceneKey: Task<CGImage?, Never>] = [:]
    /// Least recently used first.
    private var order: [StaticSceneKey] = []

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    var count: Int { entries.count }

    func image(
        for key: StaticSceneKey,
        build: @escaping @Sendable (StaticSceneKey) async -> CGImage?
    ) async -> CGImage? {
        let task: Task<CGImage?, Never>
        if let existing = entries[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { await build(key) }
            entries[key] = task
        }

        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }

        return await task.value
    }
}

/// Everything in the scene that does not move, drawn once into one bitmap.
///
/// The ground, the city, its shadows and the track are the same picture for as
/// long as the key holds. Only the cars are redrawn per frame, on top of this.
enum StaticSceneImage {
    /// The circuits' ground albedo as sRGB 0…255, keyed as `circuits.json` keys
    /// them. Taken from the mockup's `META` table; a circuit missing from it
    /// gets Monza's neutral green rather than black.
    private static let groundAlbedo: [String: SIMD3<Double>] = [
        "monaco": SIMD3(88, 81, 70),
        "spa": SIMD3(86, 102, 64),
        "suzuka": SIMD3(92, 106, 68),
        "monza": SIMD3(88, 104, 64),
        "vegas": SIMD3(142, 124, 96),
    ]

    static func ground(for circuit: Circuit) -> SIMD3<Double> {
        groundAlbedo[circuit.key] ?? SIMD3(88, 104, 64)
    }

    /// The backdrop the margin around the terrain keeps.
    static let backdrop = SIMD3<Double>(18, 18, 18)

    /// - Parameters:
    ///   - size: The canvas in points.
    ///   - scale: Backing-store pixels per point.
    /// - Returns: A `size × scale` pixel image, or nil for a degenerate canvas.
    nonisolated static func build(circuit: Circuit, size: CGSize, scale: Int,
                                  light: SceneLight) -> CGImage? {
        let pixelWidth = Int((size.width * CGFloat(scale)).rounded())
        let pixelHeight = Int((size.height * CGFloat(scale)).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Explicitly sRGB. `SceneLight` hands out colours that have already been
        // through the ACES curve and the sRGB transfer function; a context in
        // any other space would convert on top of that and undo the whole
        // lighting pipeline at the very last step.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // `SceneryLayer` sizes its shadow mask from `context.width`/`height`,
        // because `boundingBoxOfClipPath` reports an infinite rect on an
        // unclipped context. A destination that is not a bitmap therefore comes
        // out with buildings and no shadows at all, which reads as a lighting
        // bug rather than as the wrong destination. Fail here instead.
        guard context.width > 0, context.height > 0 else {
            assertionFailure("the static scene must be built into a bitmap context, "
                             + "or every building shadow is silently dropped")
            return nil
        }

        // Into the y-down, top-left point space `CircuitFit` maps into.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

        context.setFillColor(colour(backdrop))
        context.fill(CGRect(origin: .zero, size: size))

        let fit = CircuitFit(circuit: circuit, in: size)
        drawTerrain(into: context, circuit: circuit, light: light, fit: fit)
        SceneryLayer.draw(into: context, scenery: circuit.scenery, light: light, fit: fit)
        drawTrack(into: context, circuit: circuit, fit: fit)

        return context.makeImage()
    }

    // MARK: - Ground

    private static func drawTerrain(into context: CGContext, circuit: Circuit,
                                    light: SceneLight, fit: CircuitFit) {
        let terrain = circuit.terrain
        guard let image = TerrainLayer.image(terrain: terrain, light: light,
                                             ground: ground(for: circuit))
        else { return }

        let topLeft = fit.point([terrain.minX, terrain.minY])
        let bottomRight = fit.point([terrain.maxX, terrain.maxY])
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)
        guard rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        context.interpolationQuality = .high
        // The grid's first row is its lowest y — `build_terrain.py` walks gy from
        // minY — and that is the top of a y-down canvas. Core Graphics draws an
        // image upright in its own y-up space, so in this flipped space it needs
        // flipping back, or the hillside would light from the wrong side of the
        // valley and look like a shading bug.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: - Track

    /// The same four strokes `AgentverseScene` draws when no picture is ready
    /// yet, in the same order and the same colours.
    private static func drawTrack(into context: CGContext, circuit: Circuit, fit: CircuitFit) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let centreline = CircuitTrackShape.centreline(for: circuit, fit: fit).cgPath
        stroke(centreline, into: context, white: 1, alpha: 0.18,
               width: fit.width(metres: 19, atLeast: 9))
        stroke(centreline, into: context, white: 0.20, alpha: 1,
               width: fit.width(metres: 13, atLeast: 6))
        stroke(CircuitTrackShape.pitLane(for: circuit, fit: fit).cgPath, into: context,
               white: 0.16, alpha: 1, width: fit.width(metres: 12, atLeast: 5))
        stroke(CircuitTrackShape.startFinish(for: circuit, fit: fit).cgPath, into: context,
               white: 0.85, alpha: 1, width: 2)

        context.restoreGState()
    }

    private static func stroke(_ path: CGPath, into context: CGContext,
                               white: CGFloat, alpha: CGFloat, width: CGFloat) {
        guard !path.isEmpty else { return }
        context.setStrokeColor(colour(SIMD3(Double(white) * 255,
                                            Double(white) * 255,
                                            Double(white) * 255), alpha: alpha))
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// Never `CGColor(red:green:blue:alpha:)`: that picks a generic space and
    /// hands the tone-mapped values a second conversion.
    private static func colour(_ srgb: SIMD3<Double>, alpha: CGFloat = 1) -> CGColor {
        let components: [CGFloat] = [
            CGFloat(min(255, max(0, srgb.x)) / 255),
            CGFloat(min(255, max(0, srgb.y)) / 255),
            CGFloat(min(255, max(0, srgb.z)) / 255),
            alpha,
        ]
        guard let sRGB, let colour = CGColor(colorSpace: sRGB, components: components) else {
            return CGColor(gray: CGFloat(srgb.x / 255), alpha: alpha)
        }
        return colour
    }
}
