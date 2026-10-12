import AppKit

/// The app icon's gauge, reduced to what survives at menu bar size: the open
/// arc, the needle and its hub. The three tick marks are left out — at 18 pt they
/// are a pixel each and read as noise.
///
/// Drawn rather than shipped as an asset so it stays crisp at any scale, and a
/// template so the system tints it for light, dark and the pressed highlight.
enum MenuBarMark {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let center = NSPoint(x: 9, y: 7)

            // Open at the bottom, like the icon: from lower left over the top to
            // lower right.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 7, startAngle: 200, endAngle: -20, clockwise: true)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            arc.stroke()

            // Up and to the right, where the icon's needle points.
            let angle = 35.0 * .pi / 180
            let needle = NSBezierPath()
            needle.move(to: center)
            needle.line(to: NSPoint(x: center.x + 5.5 * cos(angle), y: center.y + 5.5 * sin(angle)))
            needle.lineWidth = 1.6
            needle.lineCapStyle = .round
            needle.stroke()

            NSBezierPath(ovalIn: NSRect(x: center.x - 1.7, y: center.y - 1.7, width: 3.4, height: 3.4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
