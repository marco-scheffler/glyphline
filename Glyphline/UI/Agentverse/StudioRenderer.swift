import AppKit
import SwiftUI

/// Draws the studio floor. Desks are drawn in the mockup's 200-unit station
/// coordinates and scaled to the layout; text is drawn unscaled so it stays
/// legible when the stations shrink.
struct StudioRenderer {
    let hovered: String?
    let frame: Int
    let now: Date

    private var seconds: Double { Double(frame) / AgentverseRefreshSchedule.framesPerSecond }

    // MARK: Palette — always the night scene, never `OfficeLighting`.

    private static let amber = SceneRGB(255, 176, 32)
    private static let ink = SceneRGB(27, 20, 48)
    private static let deskTop = SceneRGB(59, 47, 120)
    private static let deskFront = SceneRGB(33, 26, 73)
    private static let chair = SceneRGB(42, 34, 82)
    private static let screen = SceneRGB(11, 9, 24)
    private static let pot = SceneRGB(90, 74, 154)
    private static let leaf = SceneRGB(77, 255, 154)
    private static let bubbleFill = SceneRGB(13, 10, 32)

    // MARK: Text — measured with the font it is drawn with.

    /// Air between the bubble's text and its border, and between the bubble
    /// and the desk's edges.
    static let bubbleInset: Double = 9
    private static let typingWidth: Double = 16
    private static let bubbleHeight: Double = 20

    static var bubbleFont: NSFont { .monospacedSystemFont(ofSize: 10.5, weight: .medium) }
    private static var plateFont: NSFont { .systemFont(ofSize: 11, weight: .bold) }

    static func measureBubble(_ string: String) -> Double {
        measure(string, font: bubbleFont)
    }

    private static func measure(_ string: String, font: NSFont) -> Double {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// The bubble text cut to the desk it floats over, leaving room for the
    /// typing dots when they are drawn.
    static func fittedBubble(_ text: String, deskWidth: Double, typing: Bool) -> String {
        let width = deskWidth - 2 * bubbleInset - (typing ? typingWidth : 0)
        return LabelFit.truncated(text, to: width, measure: measureBubble)
    }

    /// A "… · N min" sentence cut to `width` with the minutes kept whole.
    ///
    /// The minutes are the news, so the sentence is split at its last "·" and
    /// only the lead gives way, as on the sidebar card. A sentence without a
    /// "·" is cut at the end like any other bubble.
    static func fittedKeepingMinutes(_ text: String, to width: Double) -> String {
        guard measureBubble(text) > width,
              let split = text.range(of: "·", options: .backwards) else {
            return LabelFit.truncated(text, to: width, measure: measureBubble)
        }
        let tail = String(text[split.lowerBound...])
        let lead = String(text[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
        let leadWidth = width - measureBubble(" " + tail)
        let fittedLead = LabelFit.truncated(lead, to: leadWidth, measure: measureBubble)
        return fittedLead.isEmpty ? tail : fittedLead + " " + tail
    }

    /// The empty-desk label, fitted to the desk without losing its minutes.
    static func emptyDeskBubble(for desk: StudioDesk, now: Date, deskWidth: Double) -> String {
        fittedKeepingMinutes(StudioBubble.emptyDeskText(for: desk, now: now),
                             to: deskWidth - 2 * bubbleInset)
    }

    /// A waiting figure's bubble in the break room, fitted the same way.
    static func breakRoomBubble(for desk: StudioDesk, now: Date, roomWidth: Double) -> String {
        fittedKeepingMinutes(StudioBubble.text(for: desk, now: now), to: roomWidth - 4 * bubbleInset)
    }

    /// The highest the bubble's bob lifts it.
    static let maximumBob: Double = 3

    /// Where a desk's bubble starts at rest: near the top of the station, but
    /// low enough that its highest bob still stays inside the desk.
    static func deskBubbleTop(rect: CGRect, scale: Double) -> Double {
        max(rect.minY + 4 * scale, rect.minY + 3 + maximumBob)
    }

    /// The bubble's box for `text`, kept inside `bounds` across, lifted by `bob`.
    static func bubbleRect(text: String, typing: Bool, centreX: Double, top: Double,
                           bounds: CGRect, bob: Double) -> CGRect {
        let width = measureBubble(text) + 2 * bubbleInset + (typing ? typingWidth : 0)
        let x = min(max(centreX - width / 2, bounds.minX), max(bounds.minX, bounds.maxX - width))
        return CGRect(x: x, y: top - bob, width: width, height: bubbleHeight)
    }

    private static let plateHeight: Double = 18

    /// The name plate under a station: below the desk's front at full size,
    /// and never past the station's bottom edge when the stations shrink, so it
    /// cannot hang into the row below.
    static func plateRect(name: String, rect: CGRect, scale: Double) -> (text: String, rect: CGRect)? {
        let font = plateFont
        let fitted = LabelFit.truncated(name, to: rect.width - 40) { measure($0, font: font) }
        guard !fitted.isEmpty else { return nil }
        let width = measure(fitted, font: font) + 20
        let y = min(rect.minY + 172 * scale, rect.maxY - plateHeight)
        return (fitted, CGRect(x: rect.midX - width / 2, y: y, width: width, height: plateHeight))
    }

    // MARK: Drawing

    func draw(in context: GraphicsContext, size: CGSize, desks: [StudioDesk]) {
        let layout = StudioLayout(canvas: size, deskCount: desks.count)
        drawBackground(context, size: size)
        drawBreakRoom(context, room: layout.breakRoom)
        for (index, desk) in desks.enumerated() {
            var deskContext = context
            deskContext.opacity = dim(desk.id)
            drawStation(deskContext, desk: desk, index: index,
                        rect: layout.deskRect(index), scale: layout.deskScale)
        }
        let room = BreakRoom(room: StudioLayout.breakRoomFloor)
        let waiting = desks.filter(\.waiting)
        let s = breakRoomScale(layout.breakRoom)
        // Every figure first, then every bubble, so no figure covers a bubble.
        let walkers = waiting.enumerated().map { order, desk in
            (desk, layout.breakRoomPoint(room.walker(for: order, seed: desk.id, frame: frame)))
        }
        for (desk, p) in walkers {
            var body = context
            body.opacity = dim(desk.id)
            body.translateBy(x: p.x, y: p.y - 40 * s)
            body.scaleBy(x: s, y: s)
            drawFigure(body, figure: desk.figure, cup: true)
        }
        for (desk, p) in walkers {
            var bubble = context
            bubble.opacity = dim(desk.id)
            let text = Self.breakRoomBubble(for: desk, now: now, roomWidth: layout.breakRoom.width)
            drawBubble(bubble, text: text, tint: Self.amber, typing: false,
                       centreX: p.x, top: p.y - 92 * s - Self.bubbleHeight,
                       bounds: layout.breakRoom.insetBy(dx: 6, dy: 0))
        }
    }

    private func dim(_ id: String) -> Double {
        hovered != nil && hovered != id ? 0.16 : 1
    }

    private func drawBackground(_ context: GraphicsContext, size: CGSize) {
        let full = CGRect(origin: .zero, size: size)
        context.fill(Path(full), with: .linearGradient(
            Gradient(stops: [.init(color: SceneRGB(28, 20, 70).color, location: 0),
                             .init(color: SceneRGB(18, 13, 46).color, location: 0.55),
                             .init(color: SceneRGB(14, 10, 36).color, location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.fill(Path(full), with: .radialGradient(
            Gradient(colors: [SceneRGB(58, 31, 138).alpha(0.33), .clear]),
            center: CGPoint(x: size.width * 0.4, y: 0), startRadius: 0,
            endRadius: max(size.width, 1) * 0.6))
        var grid = Path()
        let top = size.height * 0.54
        var x = 0.0
        while x < size.width { grid.addRect(CGRect(x: x, y: top, width: 1, height: size.height - top)); x += 64 }
        var y = top
        while y < size.height { grid.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)); y += 32 }
        context.fill(grid, with: .color(.white.opacity(0.03)))
    }

    // MARK: Station

    private func drawStation(_ context: GraphicsContext, desk: StudioDesk, index: Int,
                             rect: CGRect, scale: Double) {
        let tint = desk.waiting ? Self.amber : desk.figure.hoodie
        var local = context
        local.translateBy(x: rect.minX, y: rect.minY)
        local.scaleBy(x: scale, y: scale)

        // Floor glow; amber and pulsing under an empty desk.
        let pulse = desk.waiting ? 0.55 + 0.45 * abs(sin(seconds * .pi / 1.6)) : 1
        let glow = CGRect(x: 10, y: 152, width: 180, height: 26)
        local.fill(Path(ellipseIn: glow), with: .radialGradient(
            Gradient(colors: [tint.alpha((desk.waiting ? 0.53 : 0.45) * pulse), tint.alpha(0)]),
            center: CGPoint(x: glow.midX, y: glow.midY), startRadius: 0, endRadius: 90))

        // The scene sits 30 units down so the bubble has the top of the station.
        var scene = local
        scene.translateBy(x: 0, y: 30)
        drawMonitor(scene, desk: desk, index: index, tint: tint)
        let chair = desk.waiting ? CGRect(x: 34, y: 58, width: 48, height: 40)
                                 : CGRect(x: 34, y: 58, width: 48, height: 48)
        scene.fill(Path(roundedRect: chair, cornerRadius: 12),
                   with: .color(Self.chair.alpha(desk.waiting ? 0.7 : 1)))
        if !desk.waiting {
            var figure = scene
            figure.translateBy(x: 58, y: 66)
            drawFigure(figure, figure: desk.figure, cup: false)
        }
        drawDesk(scene, tint: tint, waiting: desk.waiting)

        let typing = !desk.waiting
        let text = desk.waiting
            ? Self.emptyDeskBubble(for: desk, now: now, deskWidth: rect.width)
            : Self.fittedBubble(StudioBubble.text(for: desk, now: now), deskWidth: rect.width, typing: typing)
        drawBubble(context, text: text, tint: tint, typing: typing,
                   centreX: rect.midX, top: Self.deskBubbleTop(rect: rect, scale: scale), bounds: rect)
        drawPlate(context, name: desk.name, tint: tint, rect: rect, scale: scale)
    }

    private func drawMonitor(_ scene: GraphicsContext, desk: StudioDesk, index: Int, tint: SceneRGB) {
        let frameRect = CGRect(x: 100, y: 24, width: 88, height: 58)
        let border = desk.waiting ? SceneRGB(58, 51, 95) : tint
        if !desk.waiting {
            scene.stroke(Path(roundedRect: frameRect.insetBy(dx: -2, dy: -2), cornerRadius: 9),
                         with: .color(tint.alpha(0.25)), lineWidth: 4)
        }
        scene.fill(Path(roundedRect: frameRect, cornerRadius: 7), with: .color(Self.screen.color))
        scene.stroke(Path(roundedRect: frameRect, cornerRadius: 7), with: .color(border.color), lineWidth: 2.5)
        scene.fill(Path(CGRect(x: 138, y: 82, width: 12, height: 12)), with: .color(Self.chair.color))
        if desk.waiting {
            scene.fill(Path(roundedRect: CGRect(x: 106, y: 30, width: 76, height: 46), cornerRadius: 4),
                       with: .color(SceneRGB(18, 15, 34).color))
            return
        }
        // Code lines that grow in six steps over 2.4 s, each on its own delay.
        for k in 0..<5 {
            let full = Double(30 + (index * 7 + k * 13) % 30)
            let t = (seconds + Double(k) * 0.3 + Double(index) * 0.2)
                .truncatingRemainder(dividingBy: 2.4) / 2.4
            let width = 4 + (full - 4) * (t * 6).rounded(.down) / 6
            scene.fill(Path(roundedRect: CGRect(x: 110, y: 30 + Double(k) * 9, width: width, height: 4),
                            cornerRadius: 2),
                       with: .color(tint.alpha(0.9 - Double(k) * 0.12)))
        }
    }

    private func drawDesk(_ scene: GraphicsContext, tint: SceneRGB, waiting: Bool) {
        scene.fill(Path(roundedRect: CGRect(x: 14, y: 94, width: 172, height: 12), cornerRadius: 5),
                   with: .color(Self.deskTop.color))
        scene.fill(Path(CGRect(x: 14, y: 101, width: 172, height: 9)), with: .color(tint.alpha(0.18)))
        scene.fill(Path(CGRect(x: 14, y: 104, width: 172, height: 3)), with: .color(tint.alpha(0.85)))
        scene.fill(Path(roundedRect: CGRect(x: 24, y: 107, width: 152, height: 30), cornerRadius: 4),
                   with: .color(Self.deskFront.color))
        for x in [40.0, 120] {
            scene.fill(Path(roundedRect: CGRect(x: x, y: 118, width: 40, height: 3), cornerRadius: 1.5),
                       with: .color(tint.alpha(0.55)))
        }
        drawPlant(scene, at: CGPoint(x: 24, y: 80), size: 1)
        if !waiting {
            scene.fill(Path(roundedRect: CGRect(x: 171, y: 82, width: 10, height: 11), cornerRadius: 2),
                       with: .color(.white))
        }
    }

    private func drawPlant(_ context: GraphicsContext, at p: CGPoint, size s: Double) {
        context.fill(Path(roundedRect: CGRect(x: p.x - 6 * s, y: p.y + 4 * s, width: 12 * s, height: 10 * s),
                          cornerRadius: 2 * s), with: .color(Self.pot.color))
        var leaf = Path()
        leaf.move(to: CGPoint(x: p.x, y: p.y + 4 * s))
        leaf.addCurve(to: CGPoint(x: p.x, y: p.y - 4 * s),
                      control1: CGPoint(x: p.x - 8 * s, y: p.y - 6 * s), control2: CGPoint(x: p.x - 2 * s, y: p.y - 12 * s))
        leaf.addCurve(to: CGPoint(x: p.x, y: p.y + 4 * s),
                      control1: CGPoint(x: p.x + 2 * s, y: p.y - 12 * s), control2: CGPoint(x: p.x + 8 * s, y: p.y - 6 * s))
        context.fill(leaf, with: .color(Self.leaf.alpha(0.9)))
    }

    // MARK: Figure — the mockup's chibi, origin at the centre of the head.

    func drawFigure(_ c: GraphicsContext, figure f: StudioFigure, cup: Bool) {
        let ink = Self.ink.color
        c.fill(Path(ellipseIn: CGRect(x: -30, y: 18, width: 60, height: 44)), with: .color(f.hoodie.alpha(0.95)))
        c.fill(Path(roundedRect: CGRect(x: -30, y: 34, width: 60, height: 26), cornerRadius: 10),
               with: .color(f.hoodie.color))
        var collar = Path()
        collar.addLines([CGPoint(x: -8, y: 22), CGPoint(x: 0, y: 32), CGPoint(x: 8, y: 22)])
        c.fill(collar, with: .color(.white.opacity(0.33)))
        c.fill(Path(ellipseIn: CGRect(x: -25, y: -25, width: 50, height: 50)), with: .color(f.skin.color))
        var hair = Path()
        hair.move(to: CGPoint(x: -26, y: -2))
        hair.addCurve(to: CGPoint(x: 26, y: -2), control1: CGPoint(x: -28, y: -30), control2: CGPoint(x: 28, y: -32))
        hair.addCurve(to: CGPoint(x: -4, y: -16), control1: CGPoint(x: 20, y: -14), control2: CGPoint(x: 8, y: -18))
        hair.addCurve(to: CGPoint(x: -26, y: -2), control1: CGPoint(x: -14, y: -15), control2: CGPoint(x: -22, y: -10))
        c.fill(hair, with: .color(f.hair.color))
        if f.accessory == .cap {
            var cap = Path()
            cap.move(to: CGPoint(x: -24, y: -8))
            cap.addCurve(to: CGPoint(x: 24, y: -8), control1: CGPoint(x: -22, y: -32), control2: CGPoint(x: 22, y: -32))
            cap.closeSubpath()
            c.fill(cap, with: .color(f.hoodie.color))
            c.fill(Path(roundedRect: CGRect(x: 2, y: -12, width: 30, height: 6), cornerRadius: 3),
                   with: .color(f.hoodie.color))
        }
        for x in [-9.0, 9] {
            c.fill(Path(ellipseIn: CGRect(x: x - 3.2, y: -1, width: 6.4, height: 8)), with: .color(ink))
            c.fill(Path(ellipseIn: CGRect(x: x - 0.1, y: 0.5, width: 2.2, height: 2.2)), with: .color(.white))
            c.fill(Path(ellipseIn: CGRect(x: x * 15 / 9 - 4, y: 8.6, width: 8, height: 4.8)),
                   with: .color(SceneRGB(255, 127, 159).alpha(0.55)))
        }
        if f.accessory == .glasses {
            var glasses = Path()
            glasses.addEllipse(in: CGRect(x: -16, y: -4, width: 14, height: 14))
            glasses.addEllipse(in: CGRect(x: 2, y: -4, width: 14, height: 14))
            glasses.move(to: CGPoint(x: -2, y: 3)); glasses.addLine(to: CGPoint(x: 2, y: 3))
            c.stroke(glasses, with: .color(ink), lineWidth: 2)
        }
        var mouth = Path()
        mouth.move(to: CGPoint(x: -4, y: 13))
        mouth.addQuadCurve(to: CGPoint(x: 4, y: 13), control: CGPoint(x: 0, y: 16))
        c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        if f.accessory == .headphones {
            var band = Path()
            band.move(to: CGPoint(x: -27, y: 2))
            band.addCurve(to: CGPoint(x: 27, y: 2), control1: CGPoint(x: -28, y: -34), control2: CGPoint(x: 28, y: -34))
            c.stroke(band, with: .color(ink), lineWidth: 4)
            for x in [-32.0, 23] {
                let cup = Path(roundedRect: CGRect(x: x, y: -6, width: 9, height: 15), cornerRadius: 4)
                c.fill(cup, with: .color(f.hoodie.color))
                c.stroke(cup, with: .color(ink), lineWidth: 2)
            }
        }
        if cup {
            c.fill(Path(roundedRect: CGRect(x: 20, y: 32, width: 13, height: 14), cornerRadius: 3), with: .color(.white))
            var handle = Path()
            handle.move(to: CGPoint(x: 33, y: 36))
            handle.addQuadCurve(to: CGPoint(x: 33, y: 43), control: CGPoint(x: 39, y: 38))
            c.stroke(handle, with: .color(.white), lineWidth: 2)
            let rise = (seconds.truncatingRemainder(dividingBy: 2)) * 2
            var steam = Path()
            for x in [24.0, 29] {
                steam.move(to: CGPoint(x: x, y: 28 - rise))
                steam.addQuadCurve(to: CGPoint(x: x, y: 21 - rise), control: CGPoint(x: x + 2, y: 24 - rise))
            }
            c.stroke(steam, with: .color(.white.opacity(0.5)), lineWidth: 1.5)
        }
    }

    // MARK: Bubble and plate

    private func drawBubble(_ context: GraphicsContext, text: String, tint: SceneRGB, typing: Bool,
                            centreX: Double, top: Double, bounds: CGRect) {
        guard !text.isEmpty else { return }
        // Up to 3 pt on a 3.2 s cycle.
        let bob = Self.maximumBob * (0.5 - 0.5 * cos(seconds / 3.2 * 2 * .pi))
        let textWidth = Self.measureBubble(text)
        let rect = Self.bubbleRect(text: text, typing: typing, centreX: centreX, top: top,
                                   bounds: bounds, bob: bob)
        var shape = Path(roundedRect: rect, cornerRadius: 8)
        shape.move(to: CGPoint(x: centreX - 5, y: rect.maxY))
        shape.addLine(to: CGPoint(x: centreX, y: rect.maxY + 5))
        shape.addLine(to: CGPoint(x: centreX + 5, y: rect.maxY))
        context.stroke(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 10),
                       with: .color(tint.alpha(0.2)), lineWidth: 4)
        context.fill(shape, with: .color(Self.bubbleFill.alpha(0.91)))
        context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(tint.color), lineWidth: 1.5)
        context.draw(Text(text).font(Font(Self.bubbleFont as CTFont)).foregroundColor(.white),
                     at: CGPoint(x: rect.minX + Self.bubbleInset, y: rect.midY), anchor: .leading)
        guard typing else { return }
        for i in 0..<3 {
            let phase = (seconds / 1.2 - Double(i) * 0.2 / 1.2).truncatingRemainder(dividingBy: 1)
            let lit = phase < 0 ? 0.2 : (phase < 0.6 ? 0.2 + 0.8 * max(0, 1 - abs(phase - 0.3) / 0.3) : 0.2)
            let dot = CGRect(x: rect.minX + Self.bubbleInset + textWidth + 4 + Double(i) * 5,
                             y: rect.midY + 1, width: 3, height: 3)
            context.fill(Path(ellipseIn: dot), with: .color(tint.alpha(lit)))
        }
    }

    private func drawPlate(_ context: GraphicsContext, name: String, tint: SceneRGB,
                           rect: CGRect, scale: Double) {
        let font = Self.plateFont
        guard let (fitted, plate) = Self.plateRect(name: name, rect: rect, scale: scale) else { return }
        context.fill(Path(roundedRect: plate, cornerRadius: 9), with: .color(SceneRGB(11, 9, 25).color))
        context.stroke(Path(roundedRect: plate, cornerRadius: 9), with: .color(tint.color), lineWidth: 1.5)
        context.draw(Text(fitted).font(Font(font as CTFont)).foregroundColor(tint.color),
                     at: CGPoint(x: plate.midX, y: plate.midY))
    }

    // MARK: Break room

    private func breakRoomScale(_ room: CGRect) -> Double {
        max(0.2, min((room.width - 20) / 230, (room.height - 20) / 360))
    }

    private func drawBreakRoom(_ context: GraphicsContext, room: CGRect) {
        let box = room.insetBy(dx: 6, dy: 6)
        context.fill(Path(roundedRect: box, cornerRadius: 14), with: .linearGradient(
            Gradient(colors: [SceneRGB(42, 26, 16).alpha(0.67), SceneRGB(23, 15, 42).color]),
            startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY)))
        context.stroke(Path(roundedRect: box, cornerRadius: 14), with: .color(Self.amber.alpha(0.4)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        let s = breakRoomScale(room)
        var c = context
        c.translateBy(x: box.minX + 4, y: box.minY + 10)
        c.scaleBy(x: s, y: s)
        // Coffee machine and counter.
        let machine = CGRect(x: 160, y: 30, width: 52, height: 74)
        c.stroke(Path(roundedRect: machine.insetBy(dx: -2, dy: -2), cornerRadius: 8),
                 with: .color(Self.amber.alpha(0.3)), lineWidth: 4)
        c.fill(Path(roundedRect: machine, cornerRadius: 6), with: .color(SceneRGB(45, 35, 80).color))
        c.stroke(Path(roundedRect: machine, cornerRadius: 6), with: .color(Self.amber.color), lineWidth: 2)
        c.fill(Path(roundedRect: CGRect(x: 170, y: 42, width: 32, height: 14), cornerRadius: 3),
               with: .color(Self.amber.alpha(0.8)))
        c.fill(Path(roundedRect: CGRect(x: 178, y: 72, width: 16, height: 22), cornerRadius: 2),
               with: .color(SceneRGB(18, 15, 34).color))
        c.fill(Path(roundedRect: CGRect(x: 140, y: 104, width: 86, height: 12), cornerRadius: 4),
               with: .color(Self.deskTop.color))
        // Sofa.
        c.fill(Path(roundedRect: CGRect(x: 14, y: 270, width: 150, height: 44), cornerRadius: 14),
               with: .color(SceneRGB(91, 45, 122).color))
        c.fill(Path(roundedRect: CGRect(x: 14, y: 250, width: 150, height: 34), cornerRadius: 14),
               with: .color(SceneRGB(110, 58, 146).color))
        for x in [8.0, 150] {
            c.fill(Path(roundedRect: CGRect(x: x, y: 268, width: 20, height: 46), cornerRadius: 8),
                   with: .color(SceneRGB(74, 36, 100).color))
        }
        drawPlant(c, at: CGPoint(x: 200, y: 300), size: 1.8)
    }
}
