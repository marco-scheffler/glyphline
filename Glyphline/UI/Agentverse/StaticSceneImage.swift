import CoreGraphics
import CoreText
import Foundation

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

        // The margin around the terrain is sky, not a card the scene sits on: it
        // goes through the same exposure and the same tone curve as everything
        // else, or it stays flat at the one time of day the rest of the picture
        // lifts most.
        context.setFillColor(colour(light.skySRGB))
        context.fill(CGRect(origin: .zero, size: size))

        let fit = CircuitFit(circuit: circuit, in: size)
        drawTerrain(into: context, circuit: circuit, light: light, fit: fit)
        SceneryLayer.draw(into: context, scenery: circuit.scenery, light: light, fit: fit)
        drawTrack(into: context, circuit: circuit, light: light, fit: fit)

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

    /// The same strokes `AgentverseScene` draws when no picture is ready yet, in
    /// the same order and the same colours, plus the corner names — which only
    /// ever appear here, because text is the one thing in the scene that would
    /// have to be laid out again on every frame.
    private static func drawTrack(into context: CGContext, circuit: Circuit,
                                 light: SceneLight, fit: CircuitFit) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in TrackStroke.all {
            let width = stroke.points(fit: fit)
            switch stroke.path {
            case .centreline:
                self.stroke(CircuitTrackShape.centreline(for: circuit, fit: fit).cgPath,
                            into: context, paint: stroke.paint, alpha: stroke.alpha,
                            width: width, light: light)
            case .racingLine:
                self.stroke(CircuitTrackShape.racingLine(for: circuit, fit: fit).cgPath,
                            into: context, paint: stroke.paint, alpha: stroke.alpha,
                            width: width, light: light)
            case .kerbs:
                drawKerbs(into: context, circuit: circuit, fit: fit,
                          paint: stroke.paint, width: width, light: light)
            case .pitLane:
                self.stroke(CircuitTrackShape.pitLane(for: circuit, fit: fit).cgPath,
                            into: context, paint: stroke.paint, alpha: stroke.alpha,
                            width: width, light: light)
            case .startFinish:
                self.stroke(CircuitTrackShape.startFinish(for: circuit, fit: fit).cgPath,
                            into: context, paint: stroke.paint, alpha: stroke.alpha,
                            width: width, light: light)
            }
        }

        context.restoreGState()
        drawCornerNames(into: context, circuit: circuit, light: light, fit: fit)
    }

    /// Butt caps, not the round ones the rest of the track uses: a round cap on
    /// both ends of every block closes the gaps the alternation is made of, and
    /// the kerb comes out a solid pink line.
    private static func drawKerbs(into context: CGContext, circuit: Circuit, fit: CircuitFit,
                                  paint: TrackStroke.Paint, width: CGFloat, light: SceneLight) {
        let blocks = CircuitTrackShape.kerbs(for: circuit, fit: fit)
        guard !blocks.isEmpty else { return }

        context.saveGState()
        context.setLineCap(.butt)
        context.setLineWidth(width)
        for (block, red) in blocks {
            let path = block.cgPath
            guard !path.isEmpty else { continue }
            context.setStrokeColor(colour(srgb(paint, red: red, light: light)))
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The stroke's own colour, put through the light as emissive. The track is
    /// designed as finished screen colours, but it lies in the scene: left raw
    /// it is the only thing in the picture that does not change between noon and
    /// midnight, which reads as the road glowing on its own at night.
    private static func srgb(_ paint: TrackStroke.Paint, red: Bool,
                             light: SceneLight) -> SIMD3<Double> {
        switch paint {
        case .flat(let flat): return light.emissiveSRGB(flat)
        case .alternating(let kerbRed, let pale):
            return light.emissiveSRGB(red ? kerbRed : pale)
        }
    }

    // MARK: - Corner names

    /// Where each named corner's caption sits, already pushed clear of the road.
    ///
    /// Empty for Monaco and Las Vegas: OpenStreetMap names no corner on either,
    /// so the two circuits the picker opens on have nothing to label. Separated
    /// from the drawing so that can be asserted without rasterising anything.
    static func cornerLabels(for circuit: Circuit,
                             fit: CircuitFit) -> [(name: String, at: CGPoint)] {
        // Far enough out to clear the verge stroke and the kerb standing on it.
        let offset = fit.width(metres: 95, atLeast: 45) / 2 + fit.width(metres: 8, atLeast: 6)

        return circuit.corners.compactMap { corner in
            guard circuit.points.indices.contains(corner.idx),
                  let heading = CarPosition.heading(points: circuit.points, index: corner.idx,
                                                    closed: true, fit: fit)
            else { return nil }
            let normal = CGPoint(x: -sin(heading), y: cos(heading))
            let centre = fit.point(circuit.points[corner.idx])
            return (corner.name, CGPoint(x: centre.x + normal.x * offset,
                                         y: centre.y + normal.y * offset))
        }
    }

    private static func drawCornerNames(into context: CGContext, circuit: Circuit,
                                        light: SceneLight,
                                        fit: CircuitFit) {
        let labels = cornerLabels(for: circuit, fit: fit)
        guard !labels.isEmpty else { return }

        // Core Text falls back through the system cascade on its own, which is
        // what puts Suzuka's 逆バンク on screen rather than a row of boxes.
        let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour(light.emissiveSRGB(SIMD3(232, 228, 216)), alpha: 0.72),
        ]

        for label in labels {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: label.name, attributes: attributes))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

            context.saveGState()
            // The context is flipped so `CircuitFit`'s y-down points land where
            // they should; text drawn into it would come out mirrored, so it is
            // flipped back around its own baseline and nowhere else.
            context.textMatrix = .identity
            context.translateBy(x: label.at.x, y: label.at.y)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = CGPoint(x: -width / 2, y: 0)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    private static func stroke(_ path: CGPath, into context: CGContext,
                               paint: TrackStroke.Paint, alpha: Double, width: CGFloat,
                               light: SceneLight) {
        guard !path.isEmpty else { return }
        context.setStrokeColor(colour(srgb(paint, red: false, light: light),
                                      alpha: CGFloat(alpha)))
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
