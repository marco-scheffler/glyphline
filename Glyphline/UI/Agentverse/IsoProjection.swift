import CoreGraphics
import Foundation

/// The isometric projection: a tile grid seen from above at a fixed angle.
///
/// `u` and `v` run along the two floor axes, `h` is height in screen points and
/// is subtracted, so taller things reach up the screen. Two tiles decide the
/// look: `tileWidth` is half the screen width of one tile, `tilt` is how much of
/// that width survives vertically — a smaller tilt is a flatter, more distant
/// view. Keeping the two as a ratio rather than as two independent lengths is
/// what makes the projection a similarity: scaling `tileWidth` scales the whole
/// picture and nothing else.
struct IsoProjection: Equatable, Sendable {
    let tileWidth: Double
    let tilt: Double
    let origin: CGPoint

    var tileHeight: Double { tileWidth * tilt }

    func point(u: Double, v: Double, h: Double = 0) -> CGPoint {
        CGPoint(x: origin.x + (u - v) * tileWidth,
                y: origin.y + (u + v) * tileHeight - h)
    }
}

/// A rectangle in floor coordinates. Not a `CGRect`: `u`/`v` are not `x`/`y`,
/// and letting them be mistaken for each other is how a room ends up drawn
/// ninety degrees out.
struct RoomRect: Equatable, Sendable {
    var u0: Double
    var u1: Double
    var v0: Double
    var v1: Double

    var midU: Double { (u0 + u1) / 2 }
    var midV: Double { (v0 + v1) / 2 }
}

/// Where one desk stands on the floor.
struct DeskSlot: Equatable, Sendable {
    let index: Int
    let u: Double
    let v: Double
}

/// The room: how big it is, where the desks stand, and the projection that maps
/// all of it into the canvas.
///
/// The scale is computed from the true bounding box of the whole scene — office
/// floor *and* break room together. Computing it from the desk grid alone is
/// the mistake that has cropped a view in this project before: the grid fits,
/// everything placed beside it does not, and the result reads as a drawing bug.
struct IsoLayout: Equatable, Sendable {
    let projection: IsoProjection
    let desks: [DeskSlot]
    let breakRoom: RoomRect
    /// The office floor runs from `-floorMargin` to `span` on both axes.
    let span: Double
    let grid: Int
    let zoom: Double
    /// Height of the two back walls, in screen points.
    let wallHeight: Double
    /// Everything drawn, in canvas coordinates. What the fit is asserted on.
    let bounds: CGRect

    /// The tile width at zoom 1. Every hard-coded size in the scene is
    /// expressed against this, so one number changes the whole room's scale.
    static let baseTileWidth: Double = 46
    /// Distance between two desks on either axis.
    static let deskStep: Double = 3.15
    /// How far a desk's furniture reaches from its centre — its rug is the
    /// widest part of it.
    static let deskFootprint: Double = 1.05
    /// How far the floor extends past the first desk row, towards the walls.
    static let floorMargin: Double = 0.8
    static let defaultTilt: Double = 0.52
    /// How much of the pane the projected bounding box is allowed to take on
    /// its tighter axis. Just short of 1 so the scene never touches the edges.
    static let fillFactor: Double = 0.95

    static func fit(sessionCount: Int,
                    canvas: CGSize,
                    tilt: Double = defaultTilt) -> IsoLayout {
        let count = max(0, sessionCount)
        // A little wider than square, so the grid grows sideways before it
        // grows towards the viewer — depth costs more screen than width does.
        let grid = max(2, Int(ceil((Double(count) * 1.1).squareRoot())))
        let span = Double(grid) * deskStep + 1.0

        // The break room sits to the right of the office, past its wall.
        let breakRoom = RoomRect(u0: span + 1.4, u1: span + 6.6, v0: -0.4, v1: 4.2)

        let width = max(0, canvas.width)
        let height = max(0, canvas.height)
        let safeTilt = max(tilt, 0.01)

        // The scale comes from the projected bounding box of everything that
        // gets drawn, measured once at zoom 1. The projection is a similarity,
        // so that box scales with the zoom and nothing else does — which is why
        // the ratio below is the exact scale that makes the box fill the pane.
        // Deriving it from `spanU`/`spanV` plus fixed pixel margins is what
        // pinned the scene to one canvas size and left half the pane empty.
        let unit = IsoProjection(tileWidth: baseTileWidth, tilt: safeTilt, origin: .zero)
        let unitCorners = sceneCorners(span: span, breakRoom: breakRoom, wallHeight: 54)
            .map { unit.point(u: $0.u, v: $0.v, h: $0.h) }
        let unitWidth = (unitCorners.map(\.x).max() ?? 0) - (unitCorners.map(\.x).min() ?? 0)
        let unitHeight = (unitCorners.map(\.y).max() ?? 0) - (unitCorners.map(\.y).min() ?? 0)

        // Not flush with the edges: the labels and the shadows the corner
        // sampling does not model need a little air around the box.
        var zoom = min(width / unitWidth, height / unitHeight) * fillFactor
        // A canvas of zero must not put a NaN or a negative scale into the
        // projection, because from there it would reach every drawn point.
        // There is no upper clamp: on a large window the scene grows with it.
        if !zoom.isFinite { zoom = 0 }
        zoom = max(0, zoom)

        let tileWidth = baseTileWidth * zoom
        let wallHeight = 54 * zoom

        // The bounding box is measured off a trial projection at the origin and
        // off the corners of the things that actually get drawn, so it is what
        // says so instead of the picture quietly getting cropped should the
        // drawn scene ever outgrow what `sceneCorners` reports.
        let trial = IsoProjection(tileWidth: tileWidth, tilt: safeTilt, origin: .zero)
        let corners = sceneCorners(span: span, breakRoom: breakRoom, wallHeight: wallHeight)
            .map { trial.point(u: $0.u, v: $0.v, h: $0.h) }
        let rawMinX = corners.map(\.x).min() ?? 0
        let rawMaxX = corners.map(\.x).max() ?? 0
        let rawMinY = corners.map(\.y).min() ?? 0
        let rawMaxY = corners.map(\.y).max() ?? 0

        // Centre the box in the pane on both axes. The vertical offset used to
        // be a clamped constant, which pinned the scene near the top whatever
        // the window did.
        let originX = width / 2 - (rawMinX + rawMaxX) / 2
        let originY = height / 2 - (rawMinY + rawMaxY) / 2

        let origin = CGPoint(x: originX, y: originY)
        let projection = IsoProjection(tileWidth: tileWidth, tilt: safeTilt, origin: origin)

        let desks = (0..<count).map { i in
            DeskSlot(index: i,
                     u: 1.0 + Double(i % grid) * deskStep,
                     v: 1.0 + Double(i / grid) * deskStep)
        }

        let minX = rawMinX + originX
        let maxX = rawMaxX + originX
        let minY = rawMinY + originY
        let maxY = rawMaxY + originY

        return IsoLayout(projection: projection,
                         desks: desks,
                         breakRoom: breakRoom,
                         span: span,
                         grid: grid,
                         zoom: zoom,
                         wallHeight: wallHeight,
                         bounds: CGRect(x: minX, y: minY,
                                        width: maxX - minX, height: maxY - minY))
    }

    /// The extreme points of everything the scene draws: the office floor and
    /// its two back walls, and the break room floor and its two back walls.
    private static func sceneCorners(
        span: Double, breakRoom: RoomRect, wallHeight: Double
    ) -> [(u: Double, v: Double, h: Double)] {
        let lo = -floorMargin
        let b0u = breakRoom.u0 - 0.4, b1u = breakRoom.u1 + 0.4
        let b0v = breakRoom.v0 - 0.4, b1v = breakRoom.v1 + 0.4
        return [
            (lo, lo, 0), (span, lo, 0), (span, span, 0), (lo, span, 0),
            (lo, lo, wallHeight), (span, lo, wallHeight), (lo, span, wallHeight),
            (b0u, b0v, 0), (b1u, b0v, 0), (b1u, b1v, 0), (b0u, b1v, 0),
            (b0u, b0v, wallHeight), (b1u, b0v, wallHeight), (b0u, b1v, wallHeight)
        ]
    }
}
