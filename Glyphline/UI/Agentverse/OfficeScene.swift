import SwiftUI

/// The daylight the office is drawn under: where the sun really stands over the
/// user's own place at this instant, and what the sky over it is doing.
///
/// It is resolved *outside* the `Canvas` and handed in, exactly as the frame
/// number is. `ImageRenderer` never runs a `.task`, so a snapshot has to be able
/// to render any instant without a clock and without a network; and the solve
/// walks a `Calendar`, which is far too much to repeat sixty times a second for
/// a number that moves by a quarter of a degree a minute.
struct OfficeLighting: Sendable {
    let sun: SolarAngles
    let weather: Weather
    let light: SceneLight

    /// How far the room is turned against the world, in radians — the unit
    /// `SceneLight.make` wants, where the two angles beside it are degrees.
    ///
    /// Zero, and that is a decision rather than an omission: with no rotation
    /// world south maps onto -v, so in the northern hemisphere the noon sun
    /// comes in through the long back wall and the morning sun through the left
    /// one. Both walls carry windows, so the pools on the floor swing from one
    /// to the other across the day.
    static let mapRotation: Double = 0

    static func at(date: Date,
                   place: UserPlace.Coordinates,
                   weather: Weather) -> OfficeLighting {
        // Latitude and longitude in that order and with their own signs: a
        // hemisphere flipped here produces a completely plausible sun that is
        // completely wrong.
        let sun = SunPosition.at(latitude: place.latitude,
                                 longitude: place.longitude,
                                 date: date)
        return OfficeLighting(
            sun: sun,
            weather: weather,
            light: SceneLight.make(elevation: sun.elevation,
                                   azimuth: sun.azimuth,
                                   mapRotation: mapRotation,
                                   weather: weather)
        )
    }

    /// What the windows show: the sky, through the same exposure and tone curve
    /// as everything else in the picture, as sRGB 0…255.
    var windowSkySRGB: SIMD3<Double> { light.skySRGB }

    var windowSkyColor: Color { light.skyColor }

    /// A brighter band of the same sky, for the top of a pane — a window filled
    /// with one flat colour reads as a hole in the wall.
    var windowSkyHighlight: Color { light.encode(light.skyLinear * 1.5) }

    /// How much of the room the desk lamps and monitors are carrying.
    ///
    /// Never zero: the monitors are on at noon too, they are simply overwhelmed.
    /// At night they are the room.
    var interiorLampStrength: Double { 0.16 + 0.84 * light.night }

    /// The break room's own ceiling light, which does not follow the sun at all.
    /// That contrast — a cosy room against a cooling office — is the point.
    var breakRoomLampStrength: Double { 1 }

    /// The direction *towards* the key light in scene space, unit length.
    /// `SceneLight` carries the direction the light travels, which is the
    /// opposite, and its elevation in degrees.
    var sunDirection: (x: Double, y: Double, z: Double) {
        let elevation = max(0, light.keyElevation) * .pi / 180
        let horizontal = cos(elevation)
        return (-light.sunX * horizontal, -light.sunY * horizontal, sin(elevation))
    }
}

/// The office seen from above: floor, walls, desks and the break room.
///
/// A port of the approved reference sketch, but no longer lit by the sketch's
/// fixed lamp: the key light's angle and colour, the sky in the windows and the
/// pools on the floor all come from `OfficeLighting` — the real sun over the
/// user's own place, under the real weather there.
///
/// The people are here too: whoever is working sits at a desk with a green
/// crystal over its head, whoever is waiting on you has got up and gone to the
/// break room under an amber one, and whoever is off the clock is on the sofa
/// strip along the bottom under a grey one.
struct OfficeScene: View {
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    /// Tokens worked per session id, keyed the same way the sidebar keys it.
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int
    /// The sun and the sky, resolved by the window and passed in like the frame
    /// number, so the scene stays a pure function of its inputs.
    let lighting: OfficeLighting

    var body: some View {
        // Pulled out of the closure: `Canvas`'s renderer is `@Sendable`, so it
        // may only capture values, never the view.
        // The full title, not a character-clipped one: the renderer cuts it to
        // the measured width of the column it will actually be drawn in, and a
        // count clipped here would only ever be right at one window size.
        let desks = sessions.map { session in
            OfficeDesk(id: session.id,
                       name: session.displayTitle,
                       repository: session.repositoryName,
                       waiting: session.activity == .waitingForYou,
                       subagentCount: session.subagentCount,
                       workTokens: workTokens[session.id] ?? 0)
        }
        let offClock = parked.map { session in
            OfficeDesk(id: session.sessionID,
                       name: session.displayTitle,
                       repository: session.repositoryName,
                       waiting: false,
                       subagentCount: session.subagentCount,
                       workTokens: workTokens[session.sessionID] ?? 0)
        }
        let hovered = hovered
        let frame = frame
        let lighting = lighting

        Canvas(opaque: true) { context, size in
            OfficeRenderer(layout: IsoLayout.fit(sessionCount: desks.count, canvas: size),
                           frame: frame,
                           hovered: hovered,
                           lighting: lighting)
                .draw(in: context, size: size, desks: desks, offClock: offClock)
        }
    }
}

/// What the room needs to know about one session to give it a desk.
struct OfficeDesk: Equatable, Sendable {
    let id: String
    /// What the plate leads with: what this session is doing, in full. The
    /// renderer cuts it to the measured width of its label column.
    let name: String
    /// The second line's first field. Every desk in one checkout repeats it,
    /// which is exactly why it is no longer the name.
    let repository: String
    let waiting: Bool
    let subagentCount: Int
    let workTokens: Int64

    /// The shirt this session wears. Derived from the id and from nothing else,
    /// so it survives a restart and matches the sidebar's swatch.
    var shirt: SceneRGB { SessionPalette.forSession(id).shirt }

    /// A per-session offset into every wobble the figure has, so a room full of
    /// people does not breathe in unison.
    var seed: Double {
        Double(SessionPalette.fnv1a(id) % 6_283) / 1_000
    }

    /// "glyphline · 36.1M · +54" — the reference's numbers, with the repository
    /// in front of them now that the plate's first line is the title.
    var caption: String {
        var parts: [String] = []
        if !repository.isEmpty, repository != name { parts.append(repository) }
        parts.append(AgentRowModel.millions(workTokens))
        if subagentCount > 0 { parts.append("+\(subagentCount)") }
        return parts.joined(separator: " · ")
    }
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

    var color: Color { shaded(1) }

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
    /// The frame number, kept whole rather than reduced to seconds: the break
    /// room's wander is a function of it, and rounding it first would make two
    /// callers disagree about where a figure is.
    let frame: Int
    let hovered: String?
    /// The sun over the user's own place, and the weather there.
    let lighting: OfficeLighting

    var time: Double { Double(frame) / 60 }

    private var proj: IsoProjection { layout.projection }
    private var tw: Double { proj.tileWidth }
    private var th: Double { proj.tileHeight }
    /// Everything sized in the reference was sized at tile width 46.
    private var scale: Double { layout.zoom }

    private func p(_ u: Double, _ v: Double, _ h: Double = 0) -> CGPoint {
        proj.point(u: u, v: v, h: h)
    }

    /// How brightly a surface facing this way comes out, as a multiplier on its
    /// own colour. Three terms, and each of them is somebody in the room:
    /// the sky through the windows, the sun itself, and the lamps and monitors
    /// inside. By day the sun dominates and the pools swing round with it; at
    /// night it is down to the moon and the interior takes over.
    private func lit(_ nx: Double, _ ny: Double, _ nz: Double) -> Double {
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
    private static let lampWarm = SceneRGB(255, 186, 118)

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

    // MARK: - People

    /// One figure: legs, body, arms, head. Returns the top of its head in canvas
    /// coordinates, which is where the crystal is hung from.
    @discardableResult
    private func person(_ context: GraphicsContext,
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
    private func plumbob(_ context: GraphicsContext,
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

    // MARK: - The break room's people

    /// Everyone who is waiting on you, wherever the wander has put them.
    private func walkers(desks: [OfficeDesk])
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

    // MARK: - Labels

    /// What the plate says, kept beside the placement rather than inside it:
    /// `MarginLabelLayout` decides geometry and knows nothing about text.
    private struct LabelText {
        let name: String
        let caption: String
        let waiting: Bool
        let dim: Bool
        let fontSize: Double
    }

    private var labelZoom: Double { max(0.86, scale) }

    /// Where the *person* is, in canvas coordinates — roughly chest height on the
    /// figure, so the leader line lands on the body rather than at its feet.
    ///
    /// A waiting session is not at its desk at all: it has got up and gone to the
    /// break room, and the line follows it there. Pointing at the empty chair
    /// would name the one thing the reader cannot see.
    func workerAnchors(desks: [OfficeDesk]) -> [WorkerAnchor] {
        let room = BreakRoom(room: layout.breakRoom)
        var order = 0
        var anchors: [WorkerAnchor] = []
        for (slot, desk) in zip(layout.desks, desks) {
            if desk.waiting {
                // The same order the walkers are drawn in — an index taken over
                // all desks instead of over the waiting ones would put the line
                // on somebody else's figure.
                let walker = room.walker(for: order, seed: desk.id, frame: frame)
                order += 1
                let pos = walker.position
                let sitting = !walker.isMoving && walker.slot.sitting
                anchors.append(WorkerAnchor(
                    id: desk.id,
                    point: chest(p(pos.u, pos.v, sitting ? 9 * scale : 0), sitting: sitting)))
            } else {
                anchors.append(WorkerAnchor(
                    id: desk.id,
                    point: chest(p(slot.u, slot.v + 0.42, 10 * scale), sitting: true)))
            }
        }
        return anchors
    }

    /// The figure's torso, measured off the point its feet stand on. The two
    /// numbers are half of `person`'s own leg-plus-body heights.
    private func chest(_ base: CGPoint, sitting: Bool) -> CGPoint {
        CGPoint(x: base.x, y: base.y - (sitting ? 22 : 32) * scale)
    }

    /// The two lines of one plate, already cut to what the column can show.
    struct FittedLabelText: Equatable, Sendable {
        let name: String
        let caption: String
    }

    /// The air a plate keeps around its text: `drawLabels` sets the first
    /// character 9 pt in from the left edge, and the right side gets the same
    /// plus a little, which is where the 22 the plate's width adds comes from.
    static let plateTextInset: Double = 22

    /// How wide a line of text may measure before it would push the plate past
    /// its column. The column is `IsoLayout.labelColumnWidth`, the layout keeps
    /// `MarginLabelLayout.padding` on each side of the plate, and the plate keeps
    /// `plateTextInset` around the text — this is what is left.
    var labelTextWidth: Double {
        max(0, layout.labelColumnWidth - 2 * MarginLabelLayout.padding - Self.plateTextInset)
    }

    /// The width of a resolved string, measured against an unbounded proposal so
    /// a long title gives its true length rather than being wrapped into it.
    private func measure(_ context: GraphicsContext, _ text: Text) -> Double {
        let free = CGSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
        return context.resolve(text).measure(in: free).width
    }

    private func nameText(_ string: String) -> Text {
        Text(string).font(.system(size: 12.5 * labelZoom, weight: .medium))
    }

    private func captionText(_ string: String) -> Text {
        Text(string).font(.system(size: 10 * labelZoom).monospaced())
    }

    /// Cut every plate's two lines to the column, by the same measurement that
    /// then sizes the plate. A character count could not do this: the column is
    /// a fraction of the pane and the count is not.
    func fittedText(_ context: GraphicsContext,
                    desks: [OfficeDesk]) -> [String: FittedLabelText] {
        let limit = labelTextWidth
        var fitted: [String: FittedLabelText] = [:]
        for desk in desks {
            fitted[desk.id] = FittedLabelText(
                name: LabelFit.truncated(desk.name, to: limit) {
                    self.measure(context, self.nameText($0))
                },
                caption: LabelFit.truncated(desk.caption, to: limit) {
                    self.measure(context, self.captionText($0))
                })
        }
        return fitted
    }

    func labelRequests(_ context: GraphicsContext,
                       desks: [OfficeDesk],
                       anchors: [WorkerAnchor],
                       fitted: [String: FittedLabelText]) -> [MarginLabelRequest] {
        zip(desks, anchors).map { desk, anchor in
            let text = fitted[desk.id]
                ?? FittedLabelText(name: desk.name, caption: desk.caption)
            let width = max(measure(context, nameText(text.name)),
                            measure(context, captionText(text.caption)))
                + Self.plateTextInset
            return MarginLabelRequest(id: desk.id, worker: anchor.point,
                                      width: width, height: 34 * labelZoom)
        }
    }

    private func drawLabels(_ context: GraphicsContext,
                            labels: [MarginLabel],
                            texts: [String: LabelText]) {
        for label in labels {
            guard let text = texts[label.id] else { continue }
            var ctx = context
            ctx.opacity = text.dim ? 0.32 : 1

            // The leader line: margin to figure, always drawn, because a callout
            // in the margin says nothing at all without it.
            let tint = text.waiting
                ? Color(red: 1, green: 174 / 255, blue: 60 / 255)
                : Color.white
            ctx.stroke(line(label.leaderStart, label.worker),
                       with: .color(tint.opacity(text.waiting ? 0.40 : 0.16)),
                       lineWidth: 1)
            // A dot at the far end, so which figure is meant is unambiguous.
            ctx.fill(ellipse(at: label.worker, rx: 2.5, ry: 2.5),
                     with: .color(tint.opacity(text.waiting ? 0.75 : 0.38)))

            let plate = Path(roundedRect: label.rect, cornerRadius: 7)
            ctx.fill(plate, with: .color(Color(red: 10 / 255, green: 14 / 255,
                                               blue: 20 / 255).opacity(0.84)))
            ctx.stroke(plate,
                       with: .color(text.waiting
                                    ? Color(red: 1, green: 174 / 255, blue: 60 / 255)
                                        .opacity(0.55)
                                    : Color.white.opacity(0.09)),
                       lineWidth: 1)
            // Clipped to the plate: the layout may have narrowed it to the
            // column, and text running out of a callout would land on the room.
            ctx.clip(to: plate)
            ctx.draw(ctx.resolve(Text(text.name)
                        .font(.system(size: text.fontSize, weight: .medium))
                        .foregroundStyle(text.waiting
                                         ? Color(red: 1, green: 174 / 255, blue: 60 / 255)
                                         : Color(red: 221 / 255, green: 230 / 255,
                                                 blue: 240 / 255))),
                     at: CGPoint(x: label.rect.minX + 9, y: label.rect.minY + text.fontSize + 2),
                     anchor: .bottomLeading)
            ctx.draw(ctx.resolve(Text(text.caption)
                        .font(.system(size: 10 * labelZoom).monospaced())
                        .foregroundStyle(Color(red: 158 / 255, green: 174 / 255,
                                               blue: 194 / 255).opacity(0.80))),
                     at: CGPoint(x: label.rect.minX + 9, y: label.rect.maxY - 6),
                     anchor: .bottomLeading)
        }
    }

    // MARK: - Off the clock

    /// The sofa strip along the bottom: sessions that are done for the day, five
    /// at a time, asleep under a grey crystal.
    private func drawOffClock(_ context: GraphicsContext, size: CGSize,
                              offClock: [OfficeDesk]) {
        guard !offClock.isEmpty else { return }
        context.draw(context.resolve(Text("OFF THE CLOCK")
            .font(.system(size: 10))
            .foregroundStyle(Color(red: 107 / 255, green: 123 / 255, blue: 136 / 255)
                .opacity(0.75))),
                     at: CGPoint(x: 20, y: size.height - 58), anchor: .bottomLeading)

        for (i, session) in offClock.prefix(5).enumerated() {
            let dim = hovered != nil && hovered != session.id
            let al = dim ? 0.22 : 0.6
            let sx = 104 + Double(i) * 116, sy = size.height - 34
            var ctx = context
            ctx.opacity = al
            ctx.fill(Path(roundedRect: CGRect(x: sx - 30, y: sy - 14, width: 60, height: 22),
                          cornerRadius: 7),
                     with: .color(SceneRGB(51, 59, 71).color))
            ctx.fill(Path(roundedRect: CGRect(x: sx - 20, y: sy - 22, width: 34, height: 16),
                          cornerRadius: 6),
                     with: .color(session.shirt.shaded(0.8)))
            ctx.fill(ellipse(at: CGPoint(x: sx + 18, y: sy - 20), rx: 7, ry: 7),
                     with: .color(SceneRGB(226, 186, 150).color))

            // The crystal is smaller and flatter down here: a strip of sleepers
            // must not out-shout the room above it.
            let cy = sy - 44 + sin(time * 1.2 + Double(i)) * 2
            let hw = 3 + 3.4 * abs(cos(time * 1.2 + Double(i)))
            ctx.fill(path([CGPoint(x: sx, y: cy - 8), CGPoint(x: sx, y: cy + 8),
                           CGPoint(x: sx - hw, y: cy)]),
                     with: .color(Self.parkedCrystal.shaded(0.6)))
            ctx.fill(path([CGPoint(x: sx, y: cy - 8), CGPoint(x: sx, y: cy + 8),
                           CGPoint(x: sx + hw, y: cy)]),
                     with: .color(Self.parkedCrystal.shaded(1.05)))

            let zs = Int(time * 1.6) % 3
            for k in 0...zs {
                context.draw(context.resolve(Text("z")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Color(red: 150 / 255, green: 164 / 255, blue: 180 / 255)
                        .opacity(0.85))),
                             at: CGPoint(x: sx + 30 + Double(k) * 7,
                                         y: sy - 24 - Double(k) * 8),
                             anchor: .bottomLeading)
            }
            let name = session.name.count > 14
                ? String(session.name.prefix(13)) + "…"
                : session.name
            context.draw(context.resolve(Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 139 / 255, green: 155 / 255, blue: 176 / 255))),
                         at: CGPoint(x: sx, y: sy + 22), anchor: .center)
        }
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

    private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func drawWalls(_ context: GraphicsContext) {
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

    // MARK: - Break room

    private func drawBreakFloor(_ context: GraphicsContext) {
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
