import SwiftUI

/// One desk and everything on it: the state wash under it, the lamp, the
/// table, the monitor, the plant, the chair and the subagent sparks over it.
extension OfficeRenderer {
    // MARK: - Desks

    private static let workingWash = SceneRGB(36, 255, 160)
    private static let waitingWash = SceneRGB(255, 132, 20)

    func drawDesk(_ context: GraphicsContext, slot: DeskSlot, desk: OfficeDesk) {
        let u = slot.u, v = slot.v
        let dim = hovered != nil && hovered != desk.id
        let al = dim ? 0.24 : 1.0
        let waiting = desk.waiting
        let s = scale

        // The state colours the whole place, not just a badge on it — that is
        // what makes the room readable at a glance.
        let wash = waiting ? Self.waitingWash : Self.workingWash
        let wp = p(u, v, 0)
        let pulse = waiting ? (0.55 + 0.45 * abs(sin(time * 2.4))) : 1
        context.fill(ellipse(at: wp, rx: 1.9 * tw, ry: 1.9 * th),
                     with: .radialGradient(
                        Gradient(stops: [
                            .init(color: wash.alpha(0.30 * pulse * al), location: 0),
                            .init(color: wash.alpha(0.12 * pulse * al), location: 0.55),
                            .init(color: wash.alpha(0), location: 1)
                        ]),
                        center: wp, startRadius: 0, endRadius: max(1.9 * tw, 0.001)))

        // The desk lamp. Always on, and by day invisible under the daylight —
        // as the sun goes it becomes the only thing holding this corner of the
        // room together.
        let lamp = lighting.interiorLampStrength
        let lp = p(u - 0.2, v - 0.55, 0)
        context.fill(ellipse(at: lp, rx: 1.5 * tw, ry: 1.5 * th),
                     with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Self.lampWarm.alpha(0.34 * lamp * al), location: 0),
                            .init(color: Self.lampWarm.alpha(0.13 * lamp * al), location: 0.5),
                            .init(color: Self.lampWarm.alpha(0), location: 1)
                        ]),
                        center: lp, startRadius: 0, endRadius: max(1.5 * tw, 0.001)))

        // Rug
        poly(context, [p(u - 1.05, v - 1.0, 0), p(u + 1.05, v - 1.0, 0),
                       p(u + 1.05, v + 1.15, 0), p(u - 1.05, v + 1.15, 0)],
             fill: .color(wash.alpha(waiting ? 0.20 : 0.11)), alpha: al)

        // Table top and legs
        contact(context, u: u, v: v - 0.5, rx: 0.95, ry: 0.95, alpha: al * 0.8)
        box(context, u: u, v: v - 0.52, su: 0.92, sv: 0.36, h0: 0, h1: 15 * s,
            colour: SceneRGB(150, 116, 78), alpha: al, bevel: true)
        for o in [(-0.82, -0.28), (0.82, -0.28), (-0.82, 0.28), (0.82, 0.28)] {
            cyl(context, u: u + o.0, v: v - 0.52 + o.1, r: 0.045, h0: 0, h1: 15 * s,
                colour: SceneRGB(86, 70, 52), alpha: al, seg: 8)
        }

        drawMonitor(context, u: u, v: v, waiting: waiting, al: al, s: s)

        // Keyboard
        box(context, u: u + 0.06, v: v - 0.42, su: 0.28, sv: 0.09,
            h0: 15 * s, h1: 17 * s, colour: SceneRGB(64, 74, 88), alpha: al)

        // Not every desk gets a plant — a room where every desk is identical
        // reads as a pattern rather than as a room.
        if Int(u * 7) % 2 == 0 { drawDeskPlant(context, u: u, v: v, al: al, s: s) }

        // Chair
        let chairV = v + 0.42
        cyl(context, u: u, v: chairV, r: 0.30, h0: 0, h1: 10 * s,
            colour: SceneRGB(52, 60, 72), alpha: al, seg: 16)
        box(context, u: u, v: chairV + 0.26, su: 0.30, sv: 0.06,
            h0: 10 * s, h1: 30 * s, colour: SceneRGB(58, 66, 80), alpha: al, bevel: true)

        // A waiting session's chair is empty: it is in the break room. That
        // absence is half of what makes the state readable from across a room.
        if !waiting {
            let topY = person(context, u: u, v: chairV, h: 10 * s,
                              shirt: desk.shirt, facing: false, sitting: true,
                              seed: desk.seed, alpha: al)
            plumbob(context, cx: p(u, chairV, 10 * s).x, topY: topY,
                    colour: Self.workingCrystal, pulsing: false, alpha: al, seed: desk.seed)
        }

        drawSubagentSparks(context, u: u, v: v, count: desk.subagentCount,
                           waiting: waiting, al: al, s: s)
    }

    private func drawMonitor(_ context: GraphicsContext,
                             u: Double, v: Double, waiting: Bool, al: Double, s: Double) {
        box(context, u: u - 0.26, v: v - 0.74, su: 0.30, sv: 0.06,
            h0: 15 * s, h1: 34 * s, colour: SceneRGB(42, 49, 58), alpha: al, bevel: true)
        let mp = p(u - 0.26, v - 0.74, 34 * s)
        var ctx = context
        ctx.opacity = al
        let screen = Path(roundedRect: CGRect(x: mp.x - 15 * s, y: mp.y + 1 * s,
                                              width: 30 * s, height: 15 * s),
                          cornerRadius: 2 * s)
        guard !waiting else {
            ctx.fill(screen, with: .color(Color(red: 22 / 255, green: 30 / 255,
                                                blue: 38 / 255).opacity(0.9)))
            return
        }
        // The screen throws light onto the table — the cheapest cue that it is
        // switched on at all. It throws further once the daylight has gone,
        // which is half of what "the interior takes over at night" means.
        let spill = 0.55 + 0.75 * lighting.light.night
        let spillCentre = CGPoint(x: mp.x, y: mp.y + 16 * s)
        ctx.fill(ellipse(at: spillCentre, rx: 44 * s, ry: 20 * s),
                 with: .radialGradient(
                    Gradient(colors: [Color(red: 60 / 255, green: 1, blue: 205 / 255)
                        .opacity(0.28 * spill),
                                      Color(red: 60 / 255, green: 1, blue: 205 / 255)
                        .opacity(0)]),
                    center: CGPoint(x: mp.x, y: mp.y + 14 * s),
                    startRadius: 0, endRadius: max(46 * s, 0.001)))
        ctx.fill(screen, with: .linearGradient(
            Gradient(colors: [Color(red: 70 / 255, green: 1, blue: 210 / 255).opacity(0.52),
                              Color(red: 30 / 255, green: 150 / 255, blue: 175 / 255)
                                .opacity(0.24)]),
            startPoint: CGPoint(x: mp.x - 16 * s, y: mp.y),
            endPoint: CGPoint(x: mp.x + 16 * s, y: mp.y + 16 * s)))
        for r in 0..<4 {
            let w = Double(4 + ((Int(time * 8) + r * 3 + Int(u * 3)) % 16))
            let colour = r == 0
                ? Color(red: 190 / 255, green: 1, blue: 238 / 255).opacity(0.98)
                : Color(red: 120 / 255, green: 240 / 255, blue: 215 / 255).opacity(0.72)
            ctx.fill(Path(CGRect(x: mp.x - 12 * s, y: mp.y + 4 * s + Double(r) * 3 * s,
                                 width: w * s, height: 1.4 * s)), with: .color(colour))
        }
    }

    private func drawDeskPlant(_ context: GraphicsContext,
                               u: Double, v: Double, al: Double, s: Double) {
        cyl(context, u: u + 0.66, v: v - 0.72, r: 0.10, h0: 15 * s, h1: 22 * s,
            colour: SceneRGB(150, 96, 66), alpha: al, seg: 12)
        var ctx = context
        ctx.opacity = al
        let pp = p(u + 0.66, v - 0.72, 22 * s)
        for (i, o) in [(0.0, -7.0), (-6.0, -3.0), (6.0, -3.0)].enumerated() {
            let centre = CGPoint(x: pp.x + o.0 * s, y: pp.y + o.1 * s)
            let leaf = ellipse(at: .zero, rx: 5.5 * s, ry: 7.5 * s)
                .applying(CGAffineTransform(rotationAngle: Double(i) * 0.5))
                .applying(CGAffineTransform(translationX: centre.x, y: centre.y))
            ctx.fill(leaf, with: .linearGradient(
                Gradient(colors: [Color(red: 96 / 255, green: 186 / 255, blue: 110 / 255),
                                  Color(red: 52 / 255, green: 124 / 255, blue: 74 / 255)]),
                startPoint: CGPoint(x: centre.x, y: centre.y - 6 * s),
                endPoint: CGPoint(x: centre.x, y: centre.y + 4 * s)))
        }
    }

    /// The subagents: sparks circling over the desk, one ring per session.
    private func drawSubagentSparks(_ context: GraphicsContext,
                                    u: Double, v: Double, count: Int,
                                    waiting: Bool, al: Double, s: Double) {
        guard count > 0 else { return }
        let n = min(9, 2 + Int((Double(count) / 8).rounded()))
        var ctx = context
        ctx.opacity = al * (waiting ? 0.30 : 0.85)
        for k in 0..<n {
            let ang = (waiting ? 0.2 : time * 0.85) + Double(k) * (6.283 / Double(n))
            let hp = p(u + cos(ang) * 0.62, v - 0.52 + sin(ang) * 0.34,
                       40 * s + sin(time * 2 + Double(k)) * 3 * s)
            ctx.fill(ellipse(at: hp, rx: 9 * s, ry: 9 * s),
                     with: .radialGradient(
                        Gradient(colors: [Color(red: 1, green: 230 / 255, blue: 170 / 255)
                            .opacity(0.95),
                                          Color(red: 1, green: 230 / 255, blue: 170 / 255)
                            .opacity(0)]),
                        center: hp, startRadius: 0, endRadius: max(9 * s, 0.001)))
            ctx.fill(ellipse(at: hp, rx: 1.5 * s, ry: 1.5 * s),
                     with: .color(Color(red: 1, green: 248 / 255, blue: 224 / 255)
                        .opacity(0.95)))
        }
    }
}
