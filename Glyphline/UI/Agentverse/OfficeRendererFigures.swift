import SwiftUI

/// The people in the room: the figures themselves, the crystal that names
/// each one's state, and the wander that carries a waiting agent to the
/// break room. Kept together because a figure and the crystal over its head
/// are one drawing — moving one without the other misaligns the pair.
extension OfficeRenderer {
    // MARK: - People

    /// One figure: legs, body, arms, head. Returns the top of its head in canvas
    /// coordinates, which is where the crystal is hung from.
    @discardableResult
    func person(_ context: GraphicsContext,
                        u: Double, v: Double, h: Double,
                        shirt: SceneRGB, facing: Bool, sitting: Bool,
                        seed: Double, alpha: Double) -> Double {
        let s = scale
        let centre = p(u, v, h)
        let cx = centre.x, cy = centre.y
        let breathe = sin(time * 1.6 + seed) * 0.9 * s
        let legH = (sitting ? 11.0 : 19.0) * s
        let bodyH = (sitting ? 23.0 : 26.0) * s + breathe
        let shW = 13.0 * s

        contact(context, u: u, v: v, rx: 0.34, ry: 0.34, alpha: alpha * 0.9)

        var ctx = context
        ctx.opacity = alpha

        let legTop = cy - legH
        ctx.fill(Path(roundedRect: CGRect(x: cx - 6.4 * s, y: legTop,
                                          width: 12.8 * s, height: legH + 1),
                      cornerRadius: 4.4 * s),
                 with: .linearGradient(
                    Gradient(colors: [SceneRGB(58, 66, 80).color, SceneRGB(38, 44, 55).color]),
                    startPoint: CGPoint(x: cx - 6 * s, y: legTop),
                    endPoint: CGPoint(x: cx + 6 * s, y: cy)))

        let bodyTop = legTop - bodyH
        ctx.fill(Path(roundedRect: CGRect(x: cx - shW / 2, y: bodyTop,
                                          width: shW, height: bodyH + 4 * s),
                      cornerRadius: 6.2 * s),
                 with: .linearGradient(
                    Gradient(stops: [.init(color: shirt.shaded(1.14), location: 0),
                                     .init(color: shirt.shaded(0.98), location: 0.55),
                                     .init(color: shirt.shaded(0.76), location: 1)]),
                    startPoint: CGPoint(x: cx - shW / 2, y: bodyTop),
                    endPoint: CGPoint(x: cx + shW / 2, y: legTop)))
        // A highlight down one shoulder. Without it the torso is a flat lozenge
        // and the figure stops reading as a body.
        ctx.fill(Path(roundedRect: CGRect(x: cx - shW / 2 + 1.4 * s, y: bodyTop + 1.4 * s,
                                          width: shW * 0.36, height: bodyH * 0.55),
                      cornerRadius: 4 * s),
                 with: .color(.white.opacity(0.13)))

        // The one bit of acting: someone seated and turned away is typing.
        let tap = sitting && !facing ? sin(time * 7 + seed) * 1.6 * s : 0
        for (dx, dy) in [(-shW / 2 - 3.4 * s, tap), (shW / 2 - 1 * s, -tap)] {
            ctx.fill(Path(roundedRect: CGRect(x: cx + dx, y: bodyTop + 7 * s + dy,
                                              width: 4.4 * s, height: bodyH * 0.52),
                          cornerRadius: 2.4 * s),
                     with: .color(shirt.shaded(0.86)))
        }

        let headR = 8.6 * s
        let headY = bodyTop - headR * 0.85
        ctx.fill(ellipse(at: CGPoint(x: cx, y: headY), rx: headR, ry: headR),
                 with: .radialGradient(
                    Gradient(colors: [SceneRGB(246, 209, 175).color,
                                      SceneRGB(206, 161, 124).color]),
                    center: CGPoint(x: cx - headR * 0.4, y: headY - headR * 0.4),
                    startRadius: headR * 0.15, endRadius: max(headR * 1.2, 0.001)))

        var hair = Path()
        hair.addArc(center: CGPoint(x: cx, y: headY - 1.4 * s), radius: max(headR, 0.001),
                    startAngle: .radians(.pi * 1.02), endAngle: .radians(.pi * 1.98),
                    clockwise: false)
        hair.closeSubpath()
        ctx.fill(hair, with: .color(SceneRGB(58, 42, 32).color))
        ctx.fill(ellipse(at: CGPoint(x: cx, y: headY - headR * 0.42),
                         rx: headR * 0.98, ry: headR * 0.62),
                 with: .color(SceneRGB(58, 42, 32).color))

        // Eyes only when the figure is turned towards you — which is what a
        // waiting agent does, and the whole reason it stands up at all.
        if facing {
            for dx in [-3.1 * s, 3.1 * s] {
                ctx.fill(ellipse(at: CGPoint(x: cx + dx, y: headY + 1.4 * s),
                                 rx: 1.35 * s, ry: 1.35 * s),
                         with: .color(Color(red: 40 / 255, green: 28 / 255, blue: 20 / 255)
                            .opacity(0.9)))
            }
        }
        return headY - headR
    }

    /// The three states, as three colours. Nothing else in the picture says
    /// which state a session is in as directly as this does.
    static let workingCrystal = SceneRGB(37, 255, 157)
    static let waitingCrystal = SceneRGB(255, 144, 18)
    static let parkedCrystal = SceneRGB(107, 123, 136)

    /// The crystal over a figure's head. It turns, it bobs, and when the session
    /// is waiting on you it pulses.
    func plumbob(_ context: GraphicsContext,
                         cx: Double, topY: Double, colour: SceneRGB,
                         pulsing: Bool, alpha: Double, seed: Double) {
        let s = scale
        let cy = topY - 16 * s + sin(time * 1.7 + seed) * 2.2 * s
        let spin = abs(cos(time * 1.5 + seed))
        let hw = (4.6 + 5.2 * spin) * s
        let hh = 12.0 * s
        let pulse = pulsing ? (0.5 + 0.5 * abs(sin(time * 3.2))) : 1

        // Two glows: a tight core and a wide halo. One alone reads as a blob;
        // the pair is what makes it look lit from inside.
        var glow = context
        glow.opacity = alpha * pulse * 0.85
        let centre = CGPoint(x: cx, y: cy)
        glow.fill(ellipse(at: centre, rx: 52 * s, ry: 52 * s),
                  with: .radialGradient(
                    Gradient(stops: [.init(color: colour.alpha(0.80), location: 0),
                                     .init(color: colour.alpha(0.33), location: 0.35),
                                     .init(color: colour.alpha(0), location: 1)]),
                    center: centre, startRadius: 0, endRadius: max(52 * s, 0.001)))
        glow.fill(ellipse(at: centre, rx: 17 * s, ry: 17 * s),
                  with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.75), colour.alpha(0)]),
                    center: centre, startRadius: 0, endRadius: max(17 * s, 0.001)))

        var ctx = context
        ctx.opacity = alpha * pulse
        ctx.fill(path([CGPoint(x: cx, y: cy - hh), CGPoint(x: cx, y: cy + hh),
                       CGPoint(x: cx - hw, y: cy)]),
                 with: .linearGradient(
                    Gradient(colors: [colour.shaded(0.55), colour.shaded(1.0)]),
                    startPoint: CGPoint(x: cx - hw, y: cy), endPoint: centre))
        ctx.fill(path([CGPoint(x: cx, y: cy - hh), CGPoint(x: cx, y: cy + hh),
                       CGPoint(x: cx + hw, y: cy)]),
                 with: .linearGradient(
                    Gradient(colors: [colour.shaded(1.18), colour.shaded(0.72)]),
                    startPoint: centre, endPoint: CGPoint(x: cx + hw, y: cy)))
        ctx.stroke(line(CGPoint(x: cx, y: cy - hh),
                        CGPoint(x: cx - hw * 0.5, y: cy - hh * 0.15)),
                   with: .color(.white.opacity(0.55)), lineWidth: 1.1)
    }

    /// The cup a figure carries when it is somewhere a cup comes from.
    private func coffee(_ context: GraphicsContext,
                        at anchor: CGPoint, alpha: Double) {
        let s = scale
        var ctx = context
        ctx.opacity = alpha
        ctx.fill(Path(roundedRect: CGRect(x: anchor.x + 7 * s, y: anchor.y - 3 * s,
                                          width: 5.5 * s, height: 6 * s),
                      cornerRadius: 1.5 * s),
                 with: .color(SceneRGB(238, 242, 246).color))
        var steam = Path()
        steam.move(to: CGPoint(x: anchor.x + 9.5 * s, y: anchor.y - 5 * s))
        steam.addQuadCurve(to: CGPoint(x: anchor.x + 9 * s, y: anchor.y - 12 * s),
                           control: CGPoint(x: anchor.x + 12 * s, y: anchor.y - 9 * s))
        ctx.opacity = alpha * 0.5
        ctx.stroke(steam, with: .color(Color(red: 230 / 255, green: 220 / 255,
                                             blue: 205 / 255).opacity(0.8)), lineWidth: 1)
    }

    // MARK: - The break room's people

    /// Everyone who is waiting on you, wherever the wander has put them.
    func walkers(desks: [OfficeDesk])
        -> [(d: Double, draw: (GraphicsContext) -> Void)] {
        let room = BreakRoom(room: layout.breakRoom)
        let waiting = desks.filter(\.waiting)
        return waiting.enumerated().map { order, desk in
            let walker = room.walker(for: order, seed: desk.id, frame: frame)
            let pos = walker.position
            return (pos.u + pos.v, { context in
                let dim = self.hovered != nil && self.hovered != desk.id
                let al = dim ? 0.24 : 1.0
                let s = self.scale
                let moving = walker.isMoving
                let sitting = !moving && walker.slot.sitting
                // Whoever is walking bobs; whoever has arrived sits still.
                let bob = moving ? abs(sin(self.time * 9)) * 2.2 * s : 0
                let h = (sitting ? 9 * s : 0) + bob
                let topY = self.person(context, u: pos.u, v: pos.v, h: h,
                                       shirt: desk.shirt, facing: !moving,
                                       sitting: sitting, seed: desk.seed, alpha: al)
                self.plumbob(context, cx: self.p(pos.u, pos.v, h).x, topY: topY,
                             colour: Self.waitingCrystal, pulsing: true,
                             alpha: al, seed: desk.seed)
                if !moving && walker.slot.activity.holdsCoffee {
                    self.coffee(context, at: self.p(pos.u, pos.v, h + 26 * s), alpha: al)
                }
            })
        }
    }
}
