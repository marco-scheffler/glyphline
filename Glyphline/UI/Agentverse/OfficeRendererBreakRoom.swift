import SwiftUI

/// The break room: its own warm floor and walls, the sign over its door, and
/// the furniture a waiting agent walks to.
extension OfficeRenderer {
    // MARK: - Break room

    func drawBreakFloor(_ context: GraphicsContext) {
        let b = layout.breakRoom
        let f = [p(b.u0 - 0.4, b.v0 - 0.4, 0), p(b.u1 + 0.4, b.v0 - 0.4, 0),
                 p(b.u1 + 0.4, b.v1 + 0.4, 0), p(b.u0 - 0.4, b.v1 + 0.4, 0)]
        poly(context, f, fill: .linearGradient(
            Gradient(colors: [Color(red: 0.227, green: 0.188, blue: 0.149),
                              Color(red: 0.165, green: 0.137, blue: 0.106)]),
            startPoint: f[0], endPoint: f[2]))

        // Warm ceiling light: the break room is not lit like the office, and it
        // is not lit by the sun either. Its strength is deliberately flat
        // through the day, so that as the office cools towards its windows this
        // room stays exactly as cosy as it was at noon.
        let ceiling = lighting.breakRoomLampStrength
        let cp = p(b.midU, b.midV, 0)
        context.fill(ellipse(at: cp, rx: 3.6 * tw, ry: 3.6 * th),
                     with: .radialGradient(
                        Gradient(colors: [Color(red: 1, green: 190 / 255, blue: 110 / 255)
                            .opacity(0.16 * ceiling),
                                          Color(red: 1, green: 190 / 255, blue: 110 / 255)
                            .opacity(0)]),
                        center: cp, startRadius: 0, endRadius: max(3.6 * tw, 0.001)))

        let wall = layout.wallHeight
        poly(context, [p(b.u0 - 0.4, b.v0 - 0.4, 0), p(b.u1 + 0.4, b.v0 - 0.4, 0),
                       p(b.u1 + 0.4, b.v0 - 0.4, wall), p(b.u0 - 0.4, b.v0 - 0.4, wall)],
             fill: .color(Color(red: 0.200, green: 0.165, blue: 0.133)))
        poly(context, [p(b.u0 - 0.4, b.v0 - 0.4, 0), p(b.u0 - 0.4, b.v1 + 0.4, 0),
                       p(b.u0 - 0.4, b.v1 + 0.4, wall), p(b.u0 - 0.4, b.v0 - 0.4, wall)],
             fill: .color(Color(red: 0.157, green: 0.122, blue: 0.098)))

        // The sign over the door
        var ctx = context
        ctx.opacity = 0.9
        let sp = p(b.u0 - 0.4, b.v0 + 1.5, wall * 0.62)
        let name = String(
            localized: "BREAK ROOM",
            comment: "Sign painted into Agentverse scene, over rest area. Drawn in capitals into fixed-width sign — keep it at most long as English."
        )
        // Cut to the room, by the same measurement it is drawn with. The sign
        // runs rightwards in screen space across the room it names and has to
        // stop at the room's far corner — past that there is no break room
        // under it, only office floor and then bare canvas.
        //
        // Nothing measured this until the app was translated. In the tightest
        // scene this app lays out — 24 sessions in a 900×600 pane — the room is
        // 78 points wide at the sign's height and English "BREAK ROOM" is 60,
        // which is why it read as settled. Spanish and Portuguese "SALA DE
        // DESCANSO" is 91 and would hang 12 points off the room's far corner.
        let sign = fittedBreakRoomSign(name) { self.measure(context, self.signText($0)) }
        let text = signText(sign)
            .foregroundStyle(Color(red: 1, green: 206 / 255, blue: 140 / 255).opacity(0.85))
        ctx.draw(ctx.resolve(text), at: CGPoint(x: sp.x + 8, y: sp.y), anchor: .bottomLeading)
    }

    /// How far the break room's sign may run: from the wall it hangs on, out to
    /// the room's far corner in screen coordinates.
    ///
    /// Derived from the projection rather than written down, because the room's
    /// screen width is a function of the pane and of how many desks are in it —
    /// the same reason the plates are cut to a measured column and not to a
    /// character count.
    var signAvailableWidth: Double {
        let b = layout.breakRoom
        let h = layout.wallHeight * 0.62
        return max(0, p(b.u1 + 0.4, b.v0 - 0.4, h).x - (p(b.u0 - 0.4, b.v0 + 1.5, h).x + 8))
    }

    /// The sign, in one place, so it is measured with the font it is drawn with.
    /// The size follows the zoom, so the fit has to as well.
    func signText(_ string: String) -> Text {
        Text(string).font(.system(size: 11 * max(0.8, scale)))
    }

    /// The sign cut to the room. Split out of the drawing so the rule can be
    /// asserted without a render pass, like the plates' fit above it.
    func fittedBreakRoomSign(_ sign: String, measure: (String) -> Double) -> String {
        LabelFit.truncated(sign, to: signAvailableWidth, measure: measure)
    }

    func breakFurniture() -> [(d: Double, draw: (GraphicsContext) -> Void)] {
        let b = layout.breakRoom
        let mu = b.midU
        let s = scale
        return [
            // Sofa
            (b.u0 + 0.9 + b.v0 + 1.55, { context in
                self.contact(context, u: b.u0 + 0.9, v: b.v0 + 1.55,
                             rx: 0.9, ry: 0.9, alpha: 1)
                self.box(context, u: b.u0 + 0.9, v: b.v0 + 1.55, su: 0.52, sv: 0.95,
                         h0: 0, h1: 14 * s, colour: SceneRGB(92, 72, 96), bevel: true)
                self.box(context, u: b.u0 + 0.42, v: b.v0 + 1.55, su: 0.12, sv: 0.95,
                         h0: 0, h1: 30 * s, colour: SceneRGB(108, 84, 112), bevel: true)
            }),
            // Counter with the coffee machine
            (b.u1 - 1.0 + b.v0 + 1.4, { context in
                self.contact(context, u: b.u1 - 1.0, v: b.v0 + 1.4,
                             rx: 1.0, ry: 1.1, alpha: 1)
                self.box(context, u: b.u1 - 1.0, v: b.v0 + 1.4, su: 0.42, sv: 1.25,
                         h0: 0, h1: 26 * s, colour: SceneRGB(78, 88, 102), bevel: true)
                self.box(context, u: b.u1 - 1.0, v: b.v0 + 0.55, su: 0.24, sv: 0.20,
                         h0: 26 * s, h1: 44 * s, colour: SceneRGB(46, 52, 62), bevel: true)
                // The pot glows — the one warm point in the room
                let kp = self.p(b.u1 - 1.0, b.v0 + 0.55, 44 * s)
                context.fill(self.ellipse(at: kp, rx: 22 * s, ry: 22 * s),
                             with: .radialGradient(
                                Gradient(colors: [
                                    Color(red: 1, green: 150 / 255, blue: 60 / 255)
                                        .opacity(0.55),
                                    Color(red: 1, green: 150 / 255, blue: 60 / 255)
                                        .opacity(0)]),
                                center: kp, startRadius: 0, endRadius: max(22 * s, 0.001)))
                context.fill(Path(roundedRect: CGRect(x: kp.x - 4 * s, y: kp.y - 4 * s,
                                                      width: 8 * s, height: 8 * s),
                                  cornerRadius: 2 * s),
                             with: .color(Color(red: 216 / 255, green: 98 / 255,
                                                blue: 44 / 255)))
            }),
            // Table
            (mu + 0.6 + b.v1 - 1.15, { context in
                self.contact(context, u: mu + 0.6, v: b.v1 - 1.15,
                             rx: 0.85, ry: 0.85, alpha: 1)
                self.cyl(context, u: mu + 0.6, v: b.v1 - 1.15, r: 0.10,
                         h0: 0, h1: 20 * s, colour: SceneRGB(86, 74, 60), seg: 10)
                self.cyl(context, u: mu + 0.6, v: b.v1 - 1.15, r: 0.62,
                         h0: 20 * s, h1: 24 * s, colour: SceneRGB(142, 110, 76), seg: 20)
            }),
            // Plant
            (b.u1 - 0.6 + b.v1 - 0.6, { context in
                self.contact(context, u: b.u1 - 0.6, v: b.v1 - 0.6,
                             rx: 0.4, ry: 0.4, alpha: 1)
                self.cyl(context, u: b.u1 - 0.6, v: b.v1 - 0.6, r: 0.20,
                         h0: 0, h1: 20 * s, colour: SceneRGB(150, 96, 66), seg: 12)
                let pp = self.p(b.u1 - 0.6, b.v1 - 0.6, 20 * s)
                for (i, o) in [(0.0, -12.0), (-9.0, -5.0), (9.0, -5.0), (0.0, -2.0)]
                    .enumerated() {
                    let centre = CGPoint(x: pp.x + o.0 * s, y: pp.y + o.1 * s)
                    let leaf = self.ellipse(at: .zero, rx: 8 * s, ry: 11 * s)
                        .applying(CGAffineTransform(rotationAngle: Double(i) * 0.6))
                        .applying(CGAffineTransform(translationX: centre.x, y: centre.y))
                    context.fill(leaf, with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 110 / 255, green: 208 / 255, blue: 124 / 255),
                            Color(red: 56 / 255, green: 132 / 255, blue: 80 / 255)]),
                        startPoint: CGPoint(x: centre.x, y: centre.y - 9 * s),
                        endPoint: CGPoint(x: centre.x, y: centre.y + 6 * s)))
                }
            })
        ]
    }
}
