import SwiftUI

/// The drawing itself. Split from the view so that the room is a function of a
/// layout and a time, and of nothing else.
struct OfficeRenderer {
    let layout: IsoLayout
    /// The frame number, kept whole rather than reduced to seconds: the break
    /// room's wander is a function of it, and rounding it first would make two
    /// callers disagree about where a figure is.
    let frame: Int
    let hovered: String?
    /// The sun over the user's own place, and the weather there.
    let lighting: OfficeLighting

    var time: Double { Double(frame) / 60 }

    private var proj: IsoProjection { layout.projection }
    var tw: Double { proj.tileWidth }
    var th: Double { proj.tileHeight }
    /// Everything sized in the reference was sized at tile width 46.
    var scale: Double { layout.zoom }

    func p(_ u: Double, _ v: Double, _ h: Double = 0) -> CGPoint {
        proj.point(u: u, v: v, h: h)
    }

    /// How brightly a surface facing this way comes out, as a multiplier on its
    /// own colour. Three terms, and each of them is somebody in the room:
    /// the sky through the windows, the sun itself, and the lamps and monitors
    /// inside. By day the sun dominates and the pools swing round with it; at
    /// night it is down to the moon and the interior takes over.
    func lit(_ nx: Double, _ ny: Double, _ nz: Double) -> Double {
        let s = lighting.sunDirection
        let sky = 0.20 + 0.26 * min(1.3, lighting.light.diffuse)
        let key = 0.85 * lighting.light.direct * max(0, nx * s.x + ny * s.y + nz * s.z)
        // The lamps hang from the ceiling, so an upward face gets more of them
        // than a wall does.
        let interior = 0.32 * lighting.interiorLampStrength * (0.55 + 0.45 * max(0, nz))
        return min(1.25, sky + key + interior)
    }

    /// The warm the interior lighting adds, as a colour to wash over the room.
    /// Deliberately not applied to the windows: the whole picture at night is a
    /// warm room against a cold sky.
    static let lampWarm = SceneRGB(255, 186, 118)

    // MARK: - Primitives

    func path(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        return path
    }

    func poly(_ context: GraphicsContext,
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
    func contact(_ context: GraphicsContext,
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

    func ellipse(at centre: CGPoint, rx: Double, ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry,
                               width: 2 * rx, height: 2 * ry))
    }

    /// A box with its four sides shaded by which way they face, drawn back to
    /// front so the near faces cover the far ones.
    func box(_ context: GraphicsContext,
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

    func cyl(_ context: GraphicsContext,
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

    func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    // MARK: - The room

    func draw(in context: GraphicsContext, size: CGSize,
              desks: [OfficeDesk], offClock: [OfficeDesk]) {
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.051, green: 0.071, blue: 0.110),
                                          Color(red: 0.027, green: 0.039, blue: 0.067)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)))

        drawFloor(context)
        drawWalls(context)
        drawBreakFloor(context)

        // One depth order over everything on the floor: desks, break room
        // furniture and the people walking about, in a single list sorted by
        // `u + v`. Sorting the three groups separately is the bug this avoids —
        // an agent crossing behind the counter has to be hidden by it.
        var items: [(d: Double, draw: (GraphicsContext) -> Void)] = []
        for (slot, desk) in zip(layout.desks, desks) {
            items.append((slot.u + slot.v, { self.drawDesk($0, slot: slot, desk: desk) }))
        }
        items.append(contentsOf: breakFurniture())
        items.append(contentsOf: walkers(desks: desks))
        for item in items.sorted(by: { $0.d < $1.d }) { item.draw(context) }

        // The labels go on afterwards, in one pass over the whole set — and
        // outside the room, in the two columns the fit reserved for them. On the
        // desks they hid the very agents they named.
        let anchors = workerAnchors(desks: desks)
        let fitted = fittedText(context, desks: desks)
        let placed = MarginLabelLayout.place(
            labelRequests(context, desks: desks, anchors: anchors, fitted: fitted),
            canvas: size,
            columnWidth: layout.labelColumnWidth,
            roomCentreX: layout.roomArea.midX)
        var texts: [String: LabelText] = [:]
        for desk in desks {
            let text = fitted[desk.id]
                ?? FittedLabelText(name: desk.name, caption: desk.caption)
            texts[desk.id] = LabelText(name: text.name, caption: text.caption,
                                      waiting: desk.waiting,
                                      dim: hovered != nil && hovered != desk.id,
                                      fontSize: 12.5 * labelZoom)
        }
        drawLabels(context, labels: placed, texts: texts)

        drawOffClock(context, size: size, offClock: offClock)
    }
}
