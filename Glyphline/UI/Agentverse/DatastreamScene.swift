import SwiftUI

/// What a lane is doing. The office's two states plus the parked one, named here
/// rather than reused from `AgentActivity` because "parked" is not something a
/// transcript can say — it comes from the ledger.
enum DatastreamState: Equatable, Sendable {
    case working, waiting, parked
}

/// One session as the datastream shows it: a lane.
struct DatastreamLane: Equatable, Sendable {
    let id: String
    /// What the header leads with: what this session is doing, already clipped to
    /// `SessionLabel.laneLimit`.
    let name: String
    /// The second line's first field, and no longer the name: every lane in one
    /// checkout would otherwise read the same.
    let repository: String
    let state: DatastreamState
    let subagentCount: Int
    let workTokens: Int64

    /// The colour of the lane's state, from the reference's `COL` table.
    var tint: SceneRGB {
        switch state {
        case .working: SceneRGB(79, 227, 160)
        case .waiting: SceneRGB(255, 182, 60)
        case .parked: SceneRGB(90, 106, 118)
        }
    }

    /// "glyphline  36.1M  +54" — the reference's numbers, with the repository in
    /// front of them now that the header's first line is the title.
    var caption: String {
        var parts: [String] = []
        if !repository.isEmpty, repository != name { parts.append(repository) }
        parts.append(AgentRowModel.millions(workTokens))
        if subagentCount > 0 { parts.append("+\(subagentCount)") }
        return parts.joined(separator: "  ")
    }
}

/// Where the lanes sit on the canvas.
///
/// The lanes tile the canvas: no gutter, no margin, no lane left short of the
/// right edge. A gap would read as a missing session rather than as spacing.
struct DatastreamLayout: Equatable, Sendable {
    let canvas: CGSize
    let laneCount: Int

    var laneWidth: Double { canvas.width / Double(max(1, laneCount)) }

    func laneX(_ index: Int) -> Double { Double(index) * laneWidth }

    func laneCentre(_ index: Int) -> Double { laneX(index) + laneWidth / 2 }

    /// The collector rail, the reference's `FLOOR`.
    var floorY: Double { canvas.height - 46 }

    /// The reference's glyph size and the gap between two glyphs in a column.
    static let glyphSize: Double = 15
    static let glyphStep: Double = 18
}

/// One falling column of glyphs at one instant.
struct DatastreamColumn: Equatable, Sendable {
    let x: Double
    /// Where the head of the column is. Everything behind it is drawn upwards
    /// from here in `glyphStep`s.
    let y: Double
    /// 0 far, 1 middle, 2 near — the three depth layers, which run at different
    /// speeds and are drawn at different strengths.
    let layer: Int
    let length: Int
    /// How far this column moves in one frame, already carrying the lane's
    /// state. Zero for a waiting lane, which is frozen.
    let speed: Double
}

/// One subagent side-stream feeding into the lane.
struct DatastreamTributary: Equatable, Sendable {
    /// Where it meets the lane, in canvas coordinates.
    let y: Double
    /// -1 from the left, +1 from the right.
    let side: Double
    /// Its offset into the travel cycle, 0…1, so seven of them do not pulse
    /// in unison.
    let phase: Double
}

/// A data block on its way down a lane.
struct DatastreamBurst: Equatable, Sendable {
    let y: Double
}

/// One lane's motion, as a pure function of the session id and the frame number.
///
/// Both halves of that matter and neither is decoration:
///
/// * Everything random-looking is seeded with FNV-1a over the session id, the
///   same hash `SessionPalette` uses. Swift's `hashValue` is seeded per process,
///   so a snapshot taken in one run would not match one taken in the next, and
///   the failure would read as a rendering bug rather than as a hashing one.
/// * Nothing here accumulates. The window hands in an absolute frame number —
///   billions of frames since the reference date — so anything simulated from
///   frame zero would never finish computing. Instead each moving thing is a
///   closed cycle: a column's fall is one modulo over the distance from its
///   spawn point to below the canvas, and a burst is one modulo over travel
///   plus the gap that follows it. Both wrap where they began, so the seam is
///   not visible.
struct DatastreamStream: Equatable, Sendable {
    let lane: DatastreamLane
    let index: Int
    let layout: DatastreamLayout

    /// A column's fixed parameters. Only the phase moves with the frame.
    private struct ColumnSeed: Equatable, Sendable {
        let x: Double
        let layer: Int
        let length: Int
        let speed: Double
        /// How far above the canvas the column reappears after it has fallen
        /// off the bottom. Fixed per column rather than redrawn on every wrap,
        /// which is what turns the reference's open fall into a closed cycle.
        let respawn: Double
        /// Where in that cycle the column stands at frame zero.
        let offset: Double
        /// The ring of glyphs the column draws from.
        let glyphs: [Character]

        /// The length of one fall: from the respawn point down to where the
        /// whole tail has cleared the bottom edge.
        func span(canvasHeight: Double) -> Double {
            canvasHeight + Double(length) * DatastreamLayout.glyphStep + respawn
        }
    }

    private let seeds: [ColumnSeed]
    let tributaries: [DatastreamTributary]
    /// How far a data block travels in one frame.
    let burstSpeed: Double
    /// Travel plus the gap that follows, in frames — the burst's whole cycle.
    private let burstCycle: Double
    /// How many frames of that cycle the block is falling for.
    private let burstTravel: Double
    /// This lane's offset into the cycle, so twenty collectors do not flare
    /// on the same frame.
    private let burstOffset: Double

    /// The one flow rate every lane runs at, standing where the reference
    /// sketch had a hand-written per-agent `rate`. It is fixed, and deliberately.
    ///
    /// The app's only candidate for "how hard is this session going" is its
    /// cumulative worked tokens, and that is not the same quantity: a lane that
    /// has been open all day outranks one that is hammering away right now, so
    /// the fastest-looking lane would not be the one doing the most work. The
    /// speed was never the signal — the state is. Working flows, waiting freezes,
    /// parked crawls, and those three are unmistakable without a rate.
    ///
    /// The value is the midpoint of the sketch's 0…1 range, so the picture sits
    /// where the approved reference sat. What still varies per lane is the
    /// tributary count, which tracks `subagentCount` — real parallelism, and a
    /// proxy for nothing.
    static let flowRate: Double = 0.5

    static let glyphs = Array(
        "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホabcdef0123456789{}[]()<>/\\|=+-*&%$#@!?"
    )

    init(lane: DatastreamLane, index: Int, layout: DatastreamLayout) {
        self.lane = lane
        self.index = index
        self.layout = layout

        // The break room's generator, reused rather than copied: one linear
        // congruential sequence in the codebase, and one id hash under it.
        var rng = LinearGenerator(seed: lane.id)
        let laneWidth = layout.laneWidth
        let laneX = layout.laneX(index)
        let stateFactor: Double = {
            switch lane.state {
            case .working: 1
            case .parked: 0.20
            case .waiting: 0
            }
        }()

        // The reference's column count: as many as fit at 24 points apart,
        // never fewer than two and never more than six.
        let columnCount = max(2, min(6, Int(laneWidth / 24)))
        var seeds: [ColumnSeed] = []
        for k in 0..<columnCount {
            let layer = k % 3
            let speed = (0.55 + rng.next() * 1.1) * (0.55 + Double(layer) * 0.35)
            let respawn = rng.next() * 180
            let length = 8 + Int(rng.next() * 12)
            let offset = rng.next()
            let glyphs = (0..<24).map { _ in
                Self.glyphs[Int(rng.next() * Double(Self.glyphs.count))]
            }
            seeds.append(ColumnSeed(
                x: laneX + 10 + Double(k) * ((laneWidth - 20) / Double(max(1, columnCount - 1))),
                layer: layer,
                length: length,
                speed: speed * stateFactor * (0.55 + Self.flowRate),
                respawn: respawn,
                offset: offset,
                glyphs: glyphs
            ))
        }
        self.seeds = seeds

        // The subagents: one side-stream per eight helpers, capped at seven, so
        // +54 is a braided river and +3 is nothing at all.
        let tributaryCount = min(7, Int((Double(lane.subagentCount) / 8).rounded()))
        var tributaries: [DatastreamTributary] = []
        for k in 0..<tributaryCount {
            tributaries.append(DatastreamTributary(
                y: 90 + rng.next() * (layout.floorY - 200),
                side: k % 2 == 1 ? 1 : -1,
                phase: rng.next()
            ))
        }
        self.tributaries = tributaries

        burstSpeed = 5.5 + Self.flowRate * 5
        // The reference starts the block 30 points above the canvas and calls it
        // arrived eight points short of the rail.
        burstTravel = ((layout.floorY - 8) + 30) / burstSpeed
        let gap = (0.9 + rng.next() * 2.6) * 60
        burstCycle = burstTravel + gap
        burstOffset = rng.next() * burstCycle
    }

    // MARK: - The fall

    /// Where every column of this lane stands at this frame.
    func columns(at frame: Int) -> [DatastreamColumn] {
        seeds.map { seed in
            let span = seed.span(canvasHeight: layout.canvas.height)
            // A waiting lane is frozen mid-fall: the frame term drops out
            // entirely, so two adjacent frames are identical.
            let travelled = seed.speed == 0
                ? seed.offset * span
                : seed.offset * span + seed.speed * Double(frame)
            return DatastreamColumn(x: seed.x,
                                    y: -seed.respawn + Self.wrap(travelled, span),
                                    layer: seed.layer,
                                    length: seed.length,
                                    speed: seed.speed)
        }
    }

    /// Which glyph a column draws at this row, at this frame.
    ///
    /// The reference swapped a random character now and then; the swap here is a
    /// function of the frame instead, so it replays the same way twice. How
    /// often it turns over is the same fixed flow rate everything else runs at.
    func glyph(column: Int, row: Int, frame: Int) -> Character {
        guard seeds.indices.contains(column) else { return " " }
        let seed = seeds[column]
        guard lane.state == .working else {
            return seed.glyphs[row % seed.glyphs.count]
        }
        let tick = Int(Double(frame) * (0.15 + Self.flowRate * 0.6) / 4)
        let mixed = Self.mix(UInt64(bitPattern: Int64(tick &* 31 &+ row &* 7 &+ column)))
        // Only some rows turn over on any given tick; the rest hold, or the
        // whole column would boil rather than churn.
        if mixed % 16 == 0 {
            return Self.glyphs[Int(mixed >> 8) % Self.glyphs.count]
        }
        return seed.glyphs[row % seed.glyphs.count]
    }

    /// The reference's glitch: a waiting lane tears every so often, and the rows
    /// that tear are displaced sideways. Deterministic in the frame, so the same
    /// frame tears the same way.
    func glitchOffset(column: Int, row: Int, frame: Int) -> Double {
        guard lane.state == .waiting, (frame * 7 / 60) % 5 == 0 else { return 0 }
        let mixed = Self.mix(UInt64(bitPattern: Int64(frame / 9 &* 131 &+ row &* 17 &+ column)))
        guard mixed % 3 == 0 else { return 0 }
        return Double(mixed >> 8 & 0xFF) / 255 * 14 - 7
    }

    // MARK: - Bursts and the collector

    /// Where this lane's data block is, or `nil` when none is in flight.
    ///
    /// A waiting lane and a parked one never fire: the missing block, and the
    /// dark collector that follows from it, is what marks them out.
    func burst(at frame: Int) -> DatastreamBurst? {
        guard lane.state == .working else { return nil }
        let phase = burstPhase(at: frame)
        guard phase < burstTravel else { return nil }
        return DatastreamBurst(y: -30 + burstSpeed * phase)
    }

    /// How brightly the collector under this lane is flaring, 0…1.
    func collectorGlow(at frame: Int) -> Double {
        guard lane.state == .working else { return 0 }
        let phase = burstPhase(at: frame)
        guard phase >= burstTravel else { return 0 }
        // The reference fades the flare at 2.2 per second.
        return max(0, 1 - (phase - burstTravel) / (60 / 2.2))
    }

    private func burstPhase(at frame: Int) -> Double {
        Self.wrap(Double(frame) + burstOffset, burstCycle)
    }

    /// Where a tributary's spark sits on its run into the lane, 0…1. A waiting
    /// lane's sparks are frozen with everything else.
    func tributaryPhase(_ tributary: DatastreamTributary, at frame: Int) -> Double {
        guard lane.state != .waiting else { return tributary.phase }
        return Self.wrap(tributary.phase + Double(frame) / 60 * 0.22, 1)
    }

    // MARK: - Helpers

    private static func wrap(_ value: Double, _ span: Double) -> Double {
        guard span > 0 else { return 0 }
        let r = value.truncatingRemainder(dividingBy: span)
        return r < 0 ? r + span : r
    }

    /// SplitMix64's finaliser. Not a third copy of the id hash — the id is
    /// hashed once, with `SessionPalette.fnv1a` — but a cheap way to turn an
    /// integer triple of frame, row and column into something that looks random
    /// without allocating a string per glyph per frame.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The datastream: one lane per session, glyphs falling, subagents feeding in
/// from the side, and a collector at the bottom that flares when a data block
/// lands on it.
///
/// A port of the approved reference sketch. It has no sun, no weather and no
/// place, and that is the point: the office is where the sessions are, this is
/// an instrument that reads them.
struct DatastreamScene: View {
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    /// Tokens worked per session id, keyed the same way the sidebar keys it.
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int

    var body: some View {
        // Pulled out of the closure: `Canvas`'s renderer is `@Sendable`, so it
        // may only capture values, never the view.
        let lanes = sessions.map { session in
            DatastreamLane(id: session.id,
                           name: SessionLabel.truncated(session.displayTitle,
                                                        to: SessionLabel.laneLimit),
                           repository: session.repositoryName,
                           state: session.activity == .waitingForYou ? .waiting : .working,
                           subagentCount: session.subagentCount,
                           workTokens: workTokens[session.id] ?? 0)
        } + parked.map { session in
            DatastreamLane(id: session.sessionID,
                           name: SessionLabel.repositoryName(cwd: session.cwd),
                           repository: SessionLabel.repositoryName(cwd: session.cwd),
                           state: .parked,
                           subagentCount: session.subagentCount,
                           workTokens: workTokens[session.sessionID] ?? 0)
        }
        let hovered = hovered
        let frame = frame

        Canvas(opaque: true) { context, size in
            DatastreamRenderer(layout: DatastreamLayout(canvas: size, laneCount: lanes.count),
                               frame: frame,
                               hovered: hovered)
                .draw(in: context, size: size, lanes: lanes)
        }
    }
}

/// The drawing itself, split from the view so that the picture is a function of
/// a layout, a frame and the lanes, and of nothing else.
struct DatastreamRenderer {
    let layout: DatastreamLayout
    let frame: Int
    let hovered: String?

    private var seconds: Double { Double(frame) / 60 }

    private static let background = Color(red: 4 / 255, green: 7 / 255, blue: 10 / 255)

    func draw(in context: GraphicsContext, size: CGSize, lanes: [DatastreamLane]) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.background))
        guard !lanes.isEmpty else { return }

        for (index, lane) in lanes.enumerated() {
            let stream = DatastreamStream(lane: lane, index: index, layout: layout)
            let dim = (hovered != nil && hovered != lane.id) ? 0.14 : 1.0
            draw(stream: stream, lane: lane, index: index, dim: dim,
                 in: context, size: size)
        }

        // The collector rail, and its label.
        context.fill(Path(CGRect(x: 0, y: layout.floorY + 8, width: size.width, height: 1)),
                     with: .color(.white.opacity(0.05)))
        context.draw(Text("COLLECTORS")
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundColor(Color(red: 90 / 255, green: 140 / 255, blue: 120 / 255).opacity(0.55)),
                     at: CGPoint(x: 10, y: size.height - 14), anchor: .leading)
    }

    private func draw(stream: DatastreamStream,
                      lane: DatastreamLane,
                      index: Int,
                      dim: Double,
                      in context: GraphicsContext,
                      size: CGSize) {
        let laneX = layout.laneX(index)
        let laneWidth = layout.laneWidth
        let centre = layout.laneCentre(index)
        let waiting = lane.state == .waiting

        // A waiting lane breathes amber behind everything else, so it is visible
        // from the far side of a room.
        if waiting {
            let pulse = 0.30 + 0.70 * abs(sin(seconds * 2))
            context.fill(Path(CGRect(x: laneX, y: 0, width: laneWidth, height: size.height)),
                         with: .color(lane.tint.alpha(0.075 * pulse * dim)))
        }

        drawTributaries(stream: stream, lane: lane, centre: centre,
                        laneWidth: laneWidth, dim: dim, in: context)
        drawColumns(stream: stream, lane: lane, dim: dim, in: context, size: size)

        if let burst = stream.burst(at: frame) {
            var block = context
            block.opacity = dim
            block.fill(Path(CGRect(x: centre - 15, y: burst.y - 30, width: 30, height: 44)),
                       with: .linearGradient(
                        Gradient(colors: [Color(red: 140 / 255, green: 1, blue: 205 / 255).opacity(0),
                                          Color(red: 190 / 255, green: 1, blue: 225 / 255).opacity(0.95)]),
                        startPoint: CGPoint(x: centre, y: burst.y - 30),
                        endPoint: CGPoint(x: centre, y: burst.y + 14)))
            block.fill(Path(CGRect(x: centre - 15, y: burst.y + 9, width: 30, height: 5)),
                       with: .color(Color(red: 235 / 255, green: 1, blue: 245 / 255).opacity(0.95)))
        }

        drawCollector(stream: stream, lane: lane, index: index, centre: centre, dim: dim,
                      in: context)

        // The lane divider and the header plate.
        context.fill(Path(CGRect(x: laneX, y: 0, width: 1, height: size.height)),
                     with: .color(.white.opacity(0.04 * dim)))
        context.fill(Path(CGRect(x: laneX + 1, y: 0, width: laneWidth - 1, height: 36)),
                     with: .color(Self.background.opacity(0.76)))
        // Clipped once, where the lane is built. A second, tighter limit here
        // would silently override `SessionLabel.laneLimit` and put the two
        // numbers out of step.
        let name = SessionLabel.truncated(lane.name, to: SessionLabel.laneLimit)
        context.draw(Text(name)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(lane.tint.alpha(dim)),
                     at: CGPoint(x: centre, y: 15))
        context.draw(Text(lane.caption)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundColor(Color(red: 140 / 255, green: 170 / 255, blue: 158 / 255)
                .opacity(dim * 0.72)),
                     at: CGPoint(x: centre, y: 28))

        if waiting {
            drawWaitingBanner(lane: lane, centre: centre, laneWidth: laneWidth,
                              dim: dim, in: context)
        }
    }

    private func drawTributaries(stream: DatastreamStream,
                                 lane: DatastreamLane,
                                 centre: Double,
                                 laneWidth: Double,
                                 dim: Double,
                                 in context: GraphicsContext) {
        guard lane.state != .parked else { return }
        let waiting = lane.state == .waiting
        for (k, tributary) in stream.tributaries.enumerated() {
            let phase = stream.tributaryPhase(tributary, at: frame)
            let y = tributary.y + (waiting ? 0 : sin(seconds * 0.6 + Double(k)) * 10)
            let x0 = centre + tributary.side * (laneWidth * 0.46)
            let x1 = centre + tributary.side * 6
            var line = Path()
            line.move(to: CGPoint(x: x0, y: y))
            line.addLine(to: CGPoint(x: x1, y: y + 26))
            context.stroke(line,
                           with: .color(lane.tint.alpha(dim * (waiting ? 0.11 : 0.25))),
                           lineWidth: 1)
            let spark = CGPoint(x: x0 + (x1 - x0) * phase, y: y + phase * 26)
            context.fill(Path(ellipseIn: CGRect(x: spark.x - 1.9, y: spark.y - 1.9,
                                                width: 3.8, height: 3.8)),
                         with: .color(lane.tint.alpha(dim * (waiting ? 0.3 : 0.95))))
        }
    }

    private func drawColumns(stream: DatastreamStream,
                             lane: DatastreamLane,
                             dim: Double,
                             in context: GraphicsContext,
                             size: CGSize) {
        let parked = lane.state == .parked
        let font = Font.system(size: DatastreamLayout.glyphSize, design: .monospaced)
        for (ci, column) in stream.columns(at: frame).enumerated() {
            let depth = 0.45 + Double(column.layer) * 0.28
            for k in 0..<column.length {
                let y = column.y - Double(k) * DatastreamLayout.glyphStep
                guard y > -DatastreamLayout.glyphStep,
                      y < size.height + DatastreamLayout.glyphStep else { continue }
                let fade = 1 - Double(k) / Double(column.length)
                let x = column.x + stream.glitchOffset(column: ci, row: k, frame: frame)
                let head = k == 0
                var alpha = fade * fade * 0.92 * dim * depth
                if parked { alpha *= 0.40 }
                let colour = head && !parked
                    ? lane.tint.mixedWithWhite(0.75).alpha(dim * depth)
                    : lane.tint.alpha(alpha)
                context.draw(Text(String(stream.glyph(column: ci, row: k, frame: frame)))
                    .font(font)
                    .foregroundColor(colour),
                             at: CGPoint(x: x, y: y))
            }
        }
    }

    private func drawCollector(stream: DatastreamStream,
                               lane: DatastreamLane,
                               index: Int,
                               centre: Double,
                               dim: Double,
                               in context: GraphicsContext) {
        let laneX = layout.laneX(index)
        let width = layout.laneWidth - 8
        let plate = CGRect(x: laneX + 4, y: layout.floorY, width: width, height: 8)
        let base: Color = switch lane.state {
        case .parked: Color(red: 40 / 255, green: 50 / 255, blue: 56 / 255).opacity(0.6)
        case .waiting: Color(red: 70 / 255, green: 44 / 255, blue: 12 / 255).opacity(0.75)
        case .working: Color(red: 16 / 255, green: 44 / 255, blue: 34 / 255).opacity(0.8)
        }
        var plateContext = context
        plateContext.opacity = dim
        plateContext.fill(Path(plate), with: .color(base))

        let lit = stream.collectorGlow(at: frame)
        guard lit > 0 else { return }
        let glow = Color(red: 150 / 255, green: 1, blue: 210 / 255)
        plateContext.fill(
            Path(ellipseIn: CGRect(x: centre - 54, y: layout.floorY + 4 - 54,
                                   width: 108, height: 108)),
            with: .radialGradient(Gradient(colors: [glow.opacity(0.55 * lit), glow.opacity(0)]),
                                  center: CGPoint(x: centre, y: layout.floorY + 4),
                                  startRadius: 0, endRadius: 54))
        plateContext.fill(Path(plate),
                          with: .color(Color(red: 220 / 255, green: 1, blue: 240 / 255)
                            .opacity(0.9 * lit)))
    }

    private func drawWaitingBanner(lane: DatastreamLane,
                                   centre: Double,
                                   laneWidth: Double,
                                   dim: Double,
                                   in context: GraphicsContext) {
        let pulse = 0.5 + 0.5 * abs(sin(seconds * 3))
        var banner = context
        banner.opacity = dim * pulse
        let bw = min(laneWidth - 16, 150)
        let rect = CGRect(x: centre - bw / 2, y: layout.floorY - 52, width: bw, height: 26)
        banner.fill(Path(rect),
                    with: .color(Color(red: 60 / 255, green: 30 / 255, blue: 4 / 255).opacity(0.92)))
        banner.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                      with: .color(lane.tint.alpha(0.85)), lineWidth: 1.2)
        banner.draw(Text("▲ WAITING ON YOU")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(lane.tint.color),
                    at: CGPoint(x: centre, y: layout.floorY - 39))
    }
}

extension SceneRGB {
    /// The same hue washed towards white, for the bright head of a column.
    func mixedWithWhite(_ amount: Double) -> SceneRGB {
        SceneRGB(r + (255 - r) * amount,
                 g + (255 - g) * amount,
                 b + (255 - b) * amount)
    }
}
