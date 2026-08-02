import SwiftUI

/// The shell the room is drawn into: floor, walls, windows, and the daylight
/// the windows lay on the floor. The panes and the pools are the same fact
/// twice — where the sun gets in — so they are decided in one place.
extension OfficeRenderer {
    private var floorLow: Double { -IsoLayout.floorMargin }

    func drawFloor(_ context: GraphicsContext) {
        let lo = floorLow, hi = layout.span
        let f = [p(lo, lo, 0), p(hi, lo, 0), p(hi, hi, 0), p(lo, hi, 0)]
        poly(context, f, fill: .linearGradient(
            Gradient(colors: [Color(red: 0.173, green: 0.204, blue: 0.251),
                              Color(red: 0.118, green: 0.141, blue: 0.180)]),
            startPoint: f[0], endPoint: f[2]))

        // Joints between the floor tiles, clipped to the floor so they do not
        // run out over the walls.
        var ctx = context
        ctx.clip(to: path(f))
        var k = lo
        while k < hi {
            ctx.stroke(line(p(k, lo, 0), p(k, hi, 0)),
                       with: .color(.white.opacity(0.045)), lineWidth: 1)
            ctx.stroke(line(p(lo, k, 0), p(hi, k, 0)),
                       with: .color(.white.opacity(0.045)), lineWidth: 1)
            k += 1.0
        }

        // The lamps' own colour on the floor. By day it is a rounding error; at
        // night it is what makes the room read warm against the cold windows.
        ctx.fill(path(f), with: .color(
            Self.lampWarm.alpha(0.30 * lighting.interiorLampStrength)))

        // The pools the windows throw. Drawn after the joints so the sunlight
        // lies over the tiles rather than under them.
        drawSunPools(ctx, lo: lo, hi: hi)
    }

    // MARK: - Windows

    /// Where the panes sit in a back wall, as fractions of its length.
    private static let windowBands: [(a: Double, b: Double)] = [
        (0.08, 0.30), (0.39, 0.61), (0.70, 0.92)
    ]
    /// Sill and head, as fractions of the wall height.
    private static let windowSill = 0.30
    private static let windowHead = 0.88

    /// The centre of each pane on the floor plan, together with the direction
    /// the room lies in from it. The back wall runs along `v = lo` and looks
    /// towards `+v`; the left wall runs along `u = lo` and looks towards `+u`.
    private func windowCentres(lo: Double, hi: Double)
        -> [(u: Double, v: Double, inwardU: Double, inwardV: Double)] {
        Self.windowBands.flatMap { band -> [(u: Double, v: Double, inwardU: Double, inwardV: Double)] in
            let mid = (band.a + band.b) / 2
            let along = lo + (hi - lo) * mid
            return [(along, lo, 0, 1), (lo, along, 1, 0)]
        }
    }

    /// Daylight lying on the floor where a window let it in.
    ///
    /// The offset is the sun's own direction and the shadow length it already
    /// implies, so the pools stretch out and swing round through the day rather
    /// than sitting under the windows all afternoon. A pane the sun is behind
    /// throws nothing, which is what `inward` decides.
    private func drawSunPools(_ context: GraphicsContext, lo: Double, hi: Double) {
        let light = lighting.light
        let reach = min(3.4, light.shadowLength * 0.5)
        let colour = light.encode(light.sunLinear)
        for window in windowCentres(lo: lo, hi: hi) {
            let entering = max(0, light.sunX * window.inwardU + light.sunY * window.inwardV)
            let strength = light.direct * entering
            guard strength > 0.01 else { continue }
            let centre = p(window.u + light.sunX * reach, window.v + light.sunY * reach, 0)
            let rx = 1.5 * tw, ry = 1.5 * th
            context.fill(ellipse(at: centre, rx: rx, ry: ry),
                         with: .radialGradient(
                            Gradient(stops: [
                                .init(color: colour.opacity(0.30 * strength), location: 0),
                                .init(color: colour.opacity(0.14 * strength), location: 0.5),
                                .init(color: colour.opacity(0), location: 1)
                            ]),
                            center: centre, startRadius: 0, endRadius: max(rx, 0.001)))
        }
    }

    /// The panes themselves. This is where the sky gets into the room: the fill
    /// is `SceneLight`'s sky, so the windows run the dawn/day/dusk/night curve
    /// without the office knowing anything about it.
    private func drawWindows(_ context: GraphicsContext,
                             lo: Double, hi: Double, wall: Double) {
        let sill = wall * Self.windowSill, head = wall * Self.windowHead
        let sky = lighting.windowSkyColor
        let highlight = lighting.windowSkyHighlight
        for band in Self.windowBands {
            let a = lo + (hi - lo) * band.a, b = lo + (hi - lo) * band.b
            // The back wall, then the left one. Same pane, two axes.
            pane(context,
                 corners: [p(a, lo, sill), p(b, lo, sill), p(b, lo, head), p(a, lo, head)],
                 sky: sky, highlight: highlight)
            pane(context,
                 corners: [p(lo, a, sill), p(lo, b, sill), p(lo, b, head), p(lo, a, head)],
                 sky: sky, highlight: highlight)
        }
    }

    private func pane(_ context: GraphicsContext,
                      corners: [CGPoint], sky: Color, highlight: Color) {
        poly(context, corners, fill: .linearGradient(
            Gradient(colors: [highlight, sky]),
            startPoint: corners[3], endPoint: corners[0]))
        // A reveal, so the pane sits in the wall rather than on it, and a
        // glancing highlight off the glass.
        poly(context, corners, fill: nil, stroke: .black.opacity(0.35))
        var ctx = context
        ctx.opacity = 0.18
        ctx.stroke(line(corners[3], corners[2]), with: .color(.white), lineWidth: 1.4)
    }

    func drawWalls(_ context: GraphicsContext) {
        let lo = floorLow, hi = layout.span, wall = layout.wallHeight
        // Seen from inside, the back wall's face looks towards +v and the left
        // wall's towards +u, so `lit` shades them by where the sun really is and
        // the two stop being two fixed greys. They are brighter than the
        // reference's values because they are albedos now rather than finished
        // colours: a fully lit wall lands back on the reference, a wall the sun
        // has left goes well below it.
        let back = SceneRGB(64, 76, 96)
        let left = SceneRGB(54, 66, 86)
        poly(context, [p(lo, lo, 0), p(hi, lo, 0), p(hi, lo, wall), p(lo, lo, wall)],
             fill: .color(back.shaded(lit(0, 1, 0))))
        poly(context, [p(lo, lo, 0), p(lo, hi, 0), p(lo, hi, wall), p(lo, lo, wall)],
             fill: .color(left.shaded(lit(1, 0, 0))))
        drawWindows(context, lo: lo, hi: hi, wall: wall)
    }
}
