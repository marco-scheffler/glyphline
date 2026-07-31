import CoreGraphics

/// Maps a circuit's metre coordinates onto a canvas.
///
/// One scale for both axes, chosen by whichever runs out first, so the whole lap
/// is always visible and the circuit keeps its shape. Fitting each axis
/// separately would stretch Monza — 2 405 m by 1 003 m — into something it is
/// not, and normalising against a fixed aspect ratio rather than the real canvas
/// is what once pushed half of Las Vegas outside the frame.
struct CircuitFit: Equatable {
    /// Points per metre.
    let scale: CGFloat
    private let offset: CGPoint

    static let margin: CGFloat = 24

    init(circuit: Circuit, in size: CGSize) {
        let usableWidth = max(0, size.width - 2 * Self.margin)
        let usableHeight = max(0, size.height - 2 * Self.margin)
        let spanX = CGFloat(max(circuit.spanX, 1))
        let spanY = CGFloat(max(circuit.spanY, 1))

        scale = min(usableWidth / spanX, usableHeight / spanY)
        offset = CGPoint(
            x: (size.width - spanX * scale) / 2 - CGFloat(circuit.minX) * scale,
            y: (size.height - spanY * scale) / 2 - CGFloat(circuit.minY) * scale
        )
    }

    func point(_ metre: [Double]) -> CGPoint {
        CGPoint(x: CGFloat(metre[0]) * scale + offset.x,
                y: CGFloat(metre[1]) * scale + offset.y)
    }

    /// A width in metres as a width on the canvas, with a floor so a long circuit
    /// on a small canvas stays a road rather than becoming a hairline.
    func width(metres: CGFloat, atLeast points: CGFloat) -> CGFloat {
        max(points, metres * scale)
    }
}
