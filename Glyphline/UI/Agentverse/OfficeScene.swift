import SwiftUI

/// The office seen from above: floor, walls, desks and the break room.
///
/// A port of the approved reference sketch, not a redesign of it. Everything is
/// drawn from the fixed directional light below — the sun model that lives
/// elsewhere in this folder is deliberately not consulted here.
///
/// No people yet: the figures, their crystals and the desk labels come later.
struct OfficeScene: View {
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    /// Tokens worked per session id, keyed the same way the sidebar keys it.
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int

    var body: some View {
        // Pulled out of the closure: `Canvas`'s renderer is `@Sendable`, so it
        // may only capture values, never the view.
        let desks = sessions.map { session in
            OfficeDesk(id: session.id,
                       waiting: session.activity == .waitingForYou,
                       subagentCount: session.subagentCount)
        }
        let hovered = hovered
        let time = Double(frame) / 60

        Canvas(opaque: true) { context, size in
            OfficeRenderer(layout: IsoLayout.fit(sessionCount: desks.count, canvas: size),
                           time: time,
                           hovered: hovered)
                .draw(in: context, size: size, desks: desks)
        }
    }
}

/// What the room needs to know about one session to give it a desk.
struct OfficeDesk: Equatable, Sendable {
    let id: String
    let waiting: Bool
    let subagentCount: Int
}

/// A colour the way the reference keeps them: 0–255 components that get shaded
/// by a lighting factor rather than by an opacity.
struct SceneRGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func shaded(_ f: Double) -> Color {
        Color(red: min(1, max(0, r * f / 255)),
              green: min(1, max(0, g * f / 255)),
              blue: min(1, max(0, b * f / 255)))
    }

    func alpha(_ a: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255).opacity(a)
    }
}

/// The drawing itself. Split from the view so that the room is a function of a
/// layout and a time, and of nothing else.
struct OfficeRenderer {
    let layout: IsoLayout
    let time: Double
    let hovered: String?

    /// Fixed directional light from the upper left. Not the sun's real
    /// position — every surface here is lit by its orientation alone.
    private static let sun = (x: -0.52, y: -0.58, z: 0.63)

    private var proj: IsoProjection { layout.projection }
    private var tw: Double { proj.tileWidth }
    private var th: Double { proj.tileHeight }
    /// Everything sized in the reference was sized at tile width 46.
    private var scale: Double { layout.zoom }

    private func p(_ u: Double, _ v: Double, _ h: Double = 0) -> CGPoint {
        proj.point(u: u, v: v, h: h)
    }

    private func lit(_ nx: Double, _ ny: Double, _ nz: Double) -> Double {
        0.34 + 0.66 * max(0, nx * Self.sun.x + ny * Self.sun.y + nz * Self.sun.z)
    }

    // MARK: - Primitives

    private func path(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        return path
    }

    private func poly(_ context: GraphicsContext,
                      _ pts: [CGPoint],
                      fill: GraphicsContext.Shading?,
                      alpha: Double = 1,
                      stroke: Color? = nil) {
        var ctx = context
        ctx.opacity = alpha
        let shape = path(pts)
        if let fill { ctx.fill(shape, with: fill) }
        if let stroke { ctx.stroke(shape, with: .color(stroke), lineWidth: 1) }
    }

    /// The soft shadow a thing casts where it meets the floor. Offset slightly
    /// away from the light, which is what makes an object sit on the floor
    /// rather than hover over it.
    private func contact(_ context: GraphicsContext,
                         u: Double, v: Double,
                         rx: Double, ry: Double, alpha: Double) {
        let centre = p(u + 0.10, v + 0.12, 0)
        let radius = max(rx * tw, 0.001)
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: Color(red: 6 / 255, green: 10 / 255, blue: 16 / 255)
                    .opacity(0.50 * alpha), location: 0),
                .init(color: Color(red: 6 / 255, green: 10 / 255, blue: 16 / 255)
                    .opacity(0.24 * alpha), location: 0.55),
                .init(color: Color(red: 6 / 255, green: 10 / 255, blue: 16 / 255)
                    .opacity(0), location: 1)
            ]),
            center: centre, startRadius: 0, endRadius: radius)
        context.fill(ellipse(at: centre, rx: rx * tw, ry: ry * th), with: shading)
    }

    private func ellipse(at centre: CGPoint, rx: Double, ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry,
                               width: 2 * rx, height: 2 * ry))
    }

    /// A box with its four sides shaded by which way they face, drawn back to
    /// front so the near faces cover the far ones.
    private func box(_ context: GraphicsContext,
                     u: Double, v: Double, su: Double, sv: Double,
                     h0: Double, h1: Double,
                     colour: SceneRGB, alpha: Double = 1, bevel: Bool = false) {
        let a = (u - su, v - sv), b = (u + su, v - sv)
        let c = (u + su, v + sv), d = (u - su, v + sv)
        let faces: [(q0: (Double, Double), q1: (Double, Double), n: (Double, Double))] = [
            (a, d, (-1, 0)), (d, c, (0, 1)), (c, b, (1, 0)), (b, a, (0, -1))
        ]
        let sorted = faces.sorted {
            (($0.q0.0 + $0.q1.0) / 2 + ($0.q0.1 + $0.q1.1) / 2)
                < (($1.q0.0 + $1.q1.0) / 2 + ($1.q0.1 + $1.q1.1) / 2)
        }
        for face in sorted {
            let base = lit(face.n.0, face.n.1, 0)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [colour.shaded(base * 1.06), colour.shaded(base * 0.86)]),
                startPoint: p(face.q0.0, face.q0.1, h1),
                endPoint: p(face.q1.0, face.q1.1, h0))
            poly(context, [p(face.q0.0, face.q0.1, h0), p(face.q1.0, face.q1.1, h0),
                           p(face.q1.0, face.q1.1, h1), p(face.q0.0, face.q0.1, h1)],
                 fill: shading, alpha: alpha)
        }
        let top = [p(a.0, a.1, h1), p(b.0, b.1, h1), p(c.0, c.1, h1), p(d.0, d.1, h1)]
        let topShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [colour.shaded(lit(0, 0, 1) * 1.10),
                              colour.shaded(lit(0, 0, 1) * 0.94)]),
            startPoint: top[0], endPoint: top[2])
        poly(context, top, fill: topShading, alpha: alpha,
             stroke: bevel ? Color.white.opacity(0.10) : nil)
    }

    private func cyl(_ context: GraphicsContext,
                     u: Double, v: Double, r: Double,
                     h0: Double, h1: Double,
                     colour: SceneRGB, alpha: Double = 1, seg: Int = 22) {
        var bot: [CGPoint] = [], top: [CGPoint] = []
        for k in 0..<seg {
            let a = Double(k) * (6.283 / Double(seg))
            bot.append(p(u + cos(a) * r, v + sin(a) * r, h0))
            top.append(p(u + cos(a) * r, v + sin(a) * r, h1))
        }
        // Sorted by the depth of each strip's middle, so the far side of the
        // cylinder is laid down before the near side covers it.
        let order = (0..<seg).map { k -> (k: Int, d: Double, nx: Double, ny: Double) in
            let a = (Double(k) + 0.5) * (6.283 / Double(seg))
            return (k, cos(a) + sin(a), cos(a), sin(a))
        }.sorted { $0.d < $1.d }
        for o in order {
            let k2 = (o.k + 1) % seg
            poly(context, [bot[o.k], bot[k2], top[k2], top[o.k]],
                 fill: .color(colour.shaded(lit(o.nx, o.ny, 0))), alpha: alpha)
        }
        poly(context, top, fill: .color(colour.shaded(lit(0, 0, 1))), alpha: alpha)
    }

    // MARK: - The room

    func draw(in context: GraphicsContext, size: CGSize, desks: [OfficeDesk]) {
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.051, green: 0.071, blue: 0.110),
                                          Color(red: 0.027, green: 0.039, blue: 0.067)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)))

        drawFloor(context)
        drawWalls(context)
        drawBreakFloor(context)

        // One depth order over everything on the floor, so a desk in front
        // covers the one behind it and the break room furniture interleaves
        // with both.
        var items: [(d: Double, draw: (GraphicsContext) -> Void)] = []
        for (slot, desk) in zip(layout.desks, desks) {
            items.append((slot.u + slot.v, { self.drawDesk($0, slot: slot, desk: desk) }))
        }
        items.append(contentsOf: breakFurniture())
        for item in items.sorted(by: { $0.d < $1.d }) { item.draw(context) }
    }

    private var floorLow: Double { -IsoLayout.floorMargin }

    private func drawFloor(_ context: GraphicsContext) {
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
    }

    private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func drawWalls(_ context: GraphicsContext) {
        let lo = floorLow, hi = layout.span, wall = layout.wallHeight
        poly(context, [p(lo, lo, 0), p(hi, lo, 0), p(hi, lo, wall), p(lo, lo, wall)],
             fill: .color(Color(red: 0.145, green: 0.173, blue: 0.220)))
        poly(context, [p(lo, lo, 0), p(lo, hi, 0), p(lo, hi, wall), p(lo, lo, wall)],
             fill: .color(Color(red: 0.114, green: 0.141, blue: 0.188)))
    }

    // MARK: - Desks

    private static let workingWash = SceneRGB(36, 255, 160)
    private static let waitingWash = SceneRGB(255, 132, 20)

    private func drawDesk(_ context: GraphicsContext, slot: DeskSlot, desk: OfficeDesk) {
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
        // switched on at all.
        let spillCentre = CGPoint(x: mp.x, y: mp.y + 16 * s)
        ctx.fill(ellipse(at: spillCentre, rx: 44 * s, ry: 20 * s),
                 with: .radialGradient(
                    Gradient(colors: [Color(red: 60 / 255, green: 1, blue: 205 / 255)
                        .opacity(0.28),
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

    // MARK: - Break room

    private func drawBreakFloor(_ context: GraphicsContext) {
        let b = layout.breakRoom
        let f = [p(b.u0 - 0.4, b.v0 - 0.4, 0), p(b.u1 + 0.4, b.v0 - 0.4, 0),
                 p(b.u1 + 0.4, b.v1 + 0.4, 0), p(b.u0 - 0.4, b.v1 + 0.4, 0)]
        poly(context, f, fill: .linearGradient(
            Gradient(colors: [Color(red: 0.227, green: 0.188, blue: 0.149),
                              Color(red: 0.165, green: 0.137, blue: 0.106)]),
            startPoint: f[0], endPoint: f[2]))

        // Warm ceiling light: the break room is not lit like the office.
        let cp = p(b.midU, b.midV, 0)
        context.fill(ellipse(at: cp, rx: 3.6 * tw, ry: 3.6 * th),
                     with: .radialGradient(
                        Gradient(colors: [Color(red: 1, green: 190 / 255, blue: 110 / 255)
                            .opacity(0.16),
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
        let text = Text("BREAK ROOM")
            .font(.system(size: 11 * max(0.8, scale)))
            .foregroundStyle(Color(red: 1, green: 206 / 255, blue: 140 / 255).opacity(0.85))
        ctx.draw(ctx.resolve(text), at: CGPoint(x: sp.x + 8, y: sp.y), anchor: .bottomLeading)
    }

    private func breakFurniture() -> [(d: Double, draw: (GraphicsContext) -> Void)] {
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
