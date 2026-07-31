import CoreGraphics

/// Maps a circuit's metre coordinates onto a canvas.
///
/// One scale for both axes, chosen by whichever runs out first, so the whole lap
/// is always visible and the circuit keeps its shape. Fitting each axis
/// separately would stretch Monza — 2 405 m by 1 003 m — into something it is
/// not, and normalising against a fixed aspect ratio rather than the real canvas
/// is what once pushed half of Las Vegas outside the frame.
///
/// What is framed is the terrain box, not the racing line. Terrain and scenery
/// reach 500 m past the circuit on every side, so fitting the lap alone
/// magnified the track into a grey worm and left Monaco's 951 buildings, its
/// harbour and its hillside outside the frame entirely.
struct CircuitFit: Equatable {
    /// Points per metre.
    let scale: CGFloat
    private let offset: CGPoint

    static let margin: CGFloat = 24

    init(circuit: Circuit, in size: CGSize) {
        let usableWidth = max(0, size.width - 2 * Self.margin)
        let usableHeight = max(0, size.height - 2 * Self.margin)
        // A terrain that failed to build carries a zero box; that circuit must
        // still render, so it falls back to the lap's own extent rather than
        // dividing by nothing.
        let terrain = circuit.terrain
        let terrainSpanX = terrain.maxX - terrain.minX
        let terrainSpanY = terrain.maxY - terrain.minY
        let usableTerrain = terrainSpanX > 0 && terrainSpanY > 0

        let minX = usableTerrain ? terrain.minX : circuit.minX
        let minY = usableTerrain ? terrain.minY : circuit.minY
        let spanX = CGFloat(max(usableTerrain ? terrainSpanX : circuit.spanX, 1))
        let spanY = CGFloat(max(usableTerrain ? terrainSpanY : circuit.spanY, 1))

        scale = min(usableWidth / spanX, usableHeight / spanY)
        offset = CGPoint(
            x: (size.width - spanX * scale) / 2 - CGFloat(minX) * scale,
            y: (size.height - spanY * scale) / 2 - CGFloat(minY) * scale
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
