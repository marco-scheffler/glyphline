import SwiftUI

/// A GT3 seen from above, drawn in a unit space and left to the caller to place.
///
/// Nose at `x = 0.5`, tail at `x = -0.5`, so a car at heading 0 faces along +x
/// and one transform rotates, scales and positions every part at once. Built as
/// separate paths rather than one, because the body, the stripe, the wing and the
/// hazards each take a different colour and two of them come and go.
///
/// Deliberately not to scale. At Monaco's fit a real 4.57 m car is 1.8 pt long,
/// so this is a map symbol; only the proportion is real.
enum CarShape {
    /// 4.57 m by 1.90 m — a real 992 GT3 RS.
    static let aspectRatio: CGFloat = 4.57 / 1.90

    private static let halfWidth: CGFloat = 0.5 / aspectRatio

    /// Nose, front arches, a waist at the cockpit, rear arches, tail.
    static let body: Path = {
        var path = Path()
        let w = halfWidth
        path.move(to: CGPoint(x: 0.50, y: -0.28 * w))
        path.addLine(to: CGPoint(x: 0.50, y: 0.28 * w))
        path.addLine(to: CGPoint(x: 0.36, y: 0.94 * w))
        path.addLine(to: CGPoint(x: 0.10, y: 0.77 * w))
        path.addLine(to: CGPoint(x: -0.22, y: 1.00 * w))
        path.addLine(to: CGPoint(x: -0.50, y: 0.82 * w))
        path.addLine(to: CGPoint(x: -0.50, y: -0.82 * w))
        path.addLine(to: CGPoint(x: -0.22, y: -1.00 * w))
        path.addLine(to: CGPoint(x: 0.10, y: -0.77 * w))
        path.addLine(to: CGPoint(x: 0.36, y: -0.94 * w))
        path.closeSubpath()
        return path
    }()

    /// The centre stripe. Gulf, Martini and Rothmans are stripe liveries — that
    /// is what those names mean, and on a circle there was nowhere to put one.
    static let stripe = Path(CGRect(x: -0.46, y: -0.22 * halfWidth,
                                    width: 0.96, height: 0.44 * halfWidth))

    /// Standing proud of the tail, which is what makes it an RS from above. It
    /// shares the tail's rear edge and overhangs it sideways: the tail is
    /// `0.82 * halfWidth` from the centre there, the wing the full width.
    static let wing = Path(CGRect(x: -0.50, y: -halfWidth,
                                  width: 0.08, height: 2 * halfWidth))

    /// Four corner markers, blinking together. Hazards, not an outline.
    static let hazards: Path = {
        var path = Path()
        let side: CGFloat = 0.09
        for x in [0.34, -0.44] as [CGFloat] {
            for y in [0.62 * halfWidth, -0.62 * halfWidth - side] {
                path.addRect(CGRect(x: x, y: y, width: side, height: side))
            }
        }
        return path
    }()
}
