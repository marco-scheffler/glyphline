import AppKit

/// The app icon's crystal, reduced to what survives at menu bar size: the
/// hexagonal outline, the two girdle edges that make it read as a cut stone
/// rather than an eye, and the core as a solid dot.
///
/// Upright, where the icon leans. At 18 pt a tilted outline lands between
/// pixels and goes soft; upright, its sides fall on whole points and stay as
/// crisp as the system symbols beside it.
///
/// Drawn rather than shipped as an asset so it stays crisp at any scale, and a
/// template so the system tints it for light, dark and the pressed highlight.
enum MenuBarMark {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let center = NSPoint(x: 9, y: 9)
            let halfWidth = 3.4
            let shoulder = 3.2  // from the centre to where the facets start
            let tip = 7.4       // from the centre to either point
            func point(_ x: Double, _ y: Double) -> NSPoint {
                NSPoint(x: center.x + x, y: center.y + y)
            }

            let outline = NSBezierPath()
            outline.move(to: point(0, tip))
            outline.line(to: point(halfWidth, shoulder))
            outline.line(to: point(halfWidth, -shoulder))
            outline.line(to: point(0, -tip))
            outline.line(to: point(-halfWidth, -shoulder))
            outline.line(to: point(-halfWidth, shoulder))
            outline.close()
            outline.lineWidth = 1.4
            outline.lineJoinStyle = .miter
            outline.stroke()

            let girdle = NSBezierPath()
            girdle.move(to: point(-halfWidth, shoulder))
            girdle.line(to: point(halfWidth, shoulder))
            girdle.move(to: point(-halfWidth, -shoulder))
            girdle.line(to: point(halfWidth, -shoulder))
            girdle.lineWidth = 1.0
            girdle.stroke()

            NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
