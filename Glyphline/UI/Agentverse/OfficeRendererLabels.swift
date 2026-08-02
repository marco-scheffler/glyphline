import SwiftUI

/// Everything written on the picture: the plates in the margins with their
/// leader lines, and the sofa strip's heading and sleepers' names. They share
/// one problem — text measured against the room it has and cut to fit — so
/// they share a file.
extension OfficeRenderer {
    // MARK: - Labels

    /// What the plate says, kept beside the placement rather than inside it:
    /// `MarginLabelLayout` decides geometry and knows nothing about text.
    struct LabelText {
        let name: String
        let caption: String
        let waiting: Bool
        let dim: Bool
        let fontSize: Double
    }

    var labelZoom: Double { max(0.86, scale) }

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
    func measure(_ context: GraphicsContext, _ text: Text) -> Double {
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

    func drawLabels(_ context: GraphicsContext,
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

    /// How far apart two sleepers stand along the strip.
    static let offClockSlotPitch: Double = 116
    /// What a sleeper's name may measure: its slot, less the air that keeps two
    /// names from reading as one.
    static let offClockTextWidth: Double = offClockSlotPitch - 12

    /// Where the strip's first sleeper stands, and where the heading starts.
    /// Both were inline constants; the heading's fit is measured against them,
    /// so they have to be one number each.
    static let offClockFirstSlotX: Double = 104
    static let offClockHeadingX: Double = 20

    /// What the "OFF THE CLOCK" heading may measure.
    ///
    /// The heading sits on its own line to the left of the strip, and the only
    /// thing drawn in its vertical band is the first sleeper's head — a circle
    /// of radius 7 centred 18 points right of the slot. So the heading has to
    /// stop short of that head, with a little air, and it has the whole left of
    /// the pane up to there.
    ///
    /// English measures 81 against the 89 this allows. Spanish "FUERA DE
    /// HORARIO" is 99 and Portuguese "FORA DE EXPEDIENTE" is 109, both of which
    /// would be drawn across a sleeper's face.
    static let offClockHeadingWidth: Double =
        (offClockFirstSlotX + 18 - 7) - 6 - offClockHeadingX

    /// The sleeper's name, in one place, so it is measured with the font it is
    /// drawn with.
    private static func offClockText(_ string: String) -> Text {
        Text(string).font(.system(size: 10))
    }

    /// The strip's heading, in one place, for the same reason.
    static func offClockHeadingText(_ string: String) -> Text {
        Text(string).font(.system(size: 10))
    }

    /// The heading cut to the room it has. Split out of the drawing for the same
    /// reason as the sleeper's name below it: the rule can then be asserted
    /// without rendering the strip.
    static func fittedOffClockHeading(_ heading: String, measure: (String) -> Double) -> String {
        LabelFit.truncated(heading, to: offClockHeadingWidth, measure: measure)
    }

    /// A sleeper's name cut to its slot. Split out of the drawing for the same
    /// reason as the plates' fit: the measurement is injected, so the rule can be
    /// asserted without rendering the strip.
    static func fittedOffClockName(_ name: String, measure: (String) -> Double) -> String {
        LabelFit.truncated(name, to: offClockTextWidth, measure: measure)
    }

    /// The sofa strip along the bottom: sessions that are done for the day, five
    /// at a time, asleep under a grey crystal.
    func drawOffClock(_ context: GraphicsContext, size: CGSize,
                              offClock: [OfficeDesk]) {
        guard !offClock.isEmpty else { return }
        let heading = Self.fittedOffClockHeading(
            String(
                localized: "OFF THE CLOCK",
                comment: "Sign painted into Agentverse scene, over area where idle agents rest. Drawn in capitals into fixed-width sign — keep it at most long as English."
            )
        ) { self.measure(context, Self.offClockHeadingText($0)) }
        context.draw(context.resolve(Self.offClockHeadingText(heading)
            .foregroundStyle(Color(red: 107 / 255, green: 123 / 255, blue: 136 / 255)
                .opacity(0.75))),
                     at: CGPoint(x: Self.offClockHeadingX, y: size.height - 58),
                     anchor: .bottomLeading)

        for (i, session) in offClock.prefix(5).enumerated() {
            let dim = hovered != nil && hovered != session.id
            let al = dim ? 0.22 : 0.6
            let sx = Self.offClockFirstSlotX + Double(i) * Self.offClockSlotPitch
            let sy = size.height - 34
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
            // Cut to the slot's width by the same measurement it is drawn with,
            // like the plates above. A character count read the same way here as
            // it did in the plates: it happened to look right in one font at one
            // size and ran into the neighbouring sleeper otherwise.
            let name = Self.fittedOffClockName(session.name) {
                self.measure(context, Self.offClockText($0))
            }
            context.draw(context.resolve(Self.offClockText(name)
                .foregroundStyle(Color(red: 139 / 255, green: 155 / 255, blue: 176 / 255))),
                         at: CGPoint(x: sx, y: sy + 22), anchor: .center)
        }
    }
}
