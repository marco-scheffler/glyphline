import XCTest
@testable import Glyphline

/// The fit is the part of an isometric scene that has gone wrong here before:
/// twice the scale was computed from something other than the true extent of
/// what gets drawn, and both times it looked like a drawing bug rather than a
/// framing one. So the fit is a pure function and it is walked exhaustively.
final class IsoProjectionTests: XCTestCase {

    /// The reference canvas, plus two smaller ones — a window can be resized
    /// and the fit has to hold at every size, not just the one it was tuned on.
    private let canvases: [CGSize] = [
        CGSize(width: 1300, height: 740),
        CGSize(width: 900, height: 560),
        CGSize(width: 640, height: 420)
    ]

    /// A spread of real window shapes, crossing the aspect ratio: wide and
    /// short, the old reference canvas, the user's window, and taller than wide.
    private let panes: [CGSize] = [
        CGSize(width: 800, height: 500),
        CGSize(width: 1300, height: 740),
        CGSize(width: 1720, height: 1020),
        CGSize(width: 900, height: 1200)
    ]

    /// Fitting is not enough — a scene occupying a quarter of the pane fits too,
    /// and that is exactly the bug this replaced. So the box must also fill one
    /// axis nearly completely and sit centred on both.
    func testTheSceneFillsAndCentresInEveryPaneShape() throws {
        for pane in panes {
            for count in [4, 12, 20] {
                let layout = IsoLayout.fit(sessionCount: count, canvas: pane)
                let b = layout.bounds
                let what = "count \(count) pane \(pane)"

                XCTAssertGreaterThanOrEqual(b.minX, -0.5, "\(what): left edge")
                XCTAssertLessThanOrEqual(b.maxX, pane.width + 0.5, "\(what): right edge")
                XCTAssertGreaterThanOrEqual(b.minY, -0.5, "\(what): top edge")
                XCTAssertLessThanOrEqual(b.maxY, pane.height + 0.5, "\(what): bottom edge")

                // The room now gets the space *between* the two label columns,
                // and it has to fill that — a room that fits the strip while
                // occupying a quarter of it is the bug this assertion replaced,
                // and reserving a margin must not quietly reintroduce it.
                let area = layout.roomArea
                XCTAssertGreaterThanOrEqual(b.minX, area.minX - 0.5, "\(what): left column")
                XCTAssertLessThanOrEqual(b.maxX, area.maxX + 0.5, "\(what): right column")

                let fill = max(b.width / area.width, b.height / area.height)
                XCTAssertGreaterThanOrEqual(fill, 0.85, "\(what): fills only \(fill)")

                XCTAssertEqual(b.midX, pane.width / 2, accuracy: 2, "\(what): centre x")
                XCTAssertEqual(b.midY, pane.height / 2, accuracy: 2, "\(what): centre y")
            }
        }
    }

    /// The scale is not capped: a bigger window makes a bigger scene, which the
    /// old `min(1.0, …)` clamp prevented and is why the scene floated in a
    /// corner of a large pane.
    func testALargerPaneYieldsALargerScene() throws {
        let small = IsoLayout.fit(sessionCount: 12, canvas: CGSize(width: 860, height: 510))
        let large = IsoLayout.fit(sessionCount: 12, canvas: CGSize(width: 1720, height: 1020))
        // At least double, no longer exactly double: the label columns stop
        // growing at `labelColumnMax`, so a pane twice the size hands the room
        // more than twice the width. The clamp this guards against — the old
        // `min(1.0, …)` — would still show up as less than double.
        XCTAssertGreaterThanOrEqual(large.zoom, small.zoom * 2)
        // A small room on a large window passes the scale the old clamp stopped
        // at. The window is bigger than it was: the two label columns are paid
        // for out of the room's width, so the same scale needs more pane.
        let roomy = IsoLayout.fit(sessionCount: 4, canvas: CGSize(width: 2000, height: 1200))
        XCTAssertGreaterThan(roomy.zoom, 1.0)
    }

    func testEverySessionCountFitsInsideTheCanvasOnBothAxes() throws {
        for canvas in canvases {
            for count in 4...20 {
                let layout = IsoLayout.fit(sessionCount: count, canvas: canvas)
                let b = layout.bounds
                XCTAssertTrue(b.minX >= -0.5,
                              "count \(count) canvas \(canvas): left edge \(b.minX)")
                XCTAssertTrue(b.maxX <= canvas.width + 0.5,
                              "count \(count) canvas \(canvas): right edge \(b.maxX)")
                XCTAssertTrue(b.minY >= -0.5,
                              "count \(count) canvas \(canvas): top edge \(b.minY)")
                XCTAssertTrue(b.maxY <= canvas.height + 0.5,
                              "count \(count) canvas \(canvas): bottom edge \(b.maxY)")
                XCTAssertTrue(b.width.isFinite && b.height.isFinite)
                XCTAssertGreaterThan(b.width, 0)
            }
        }
    }

    /// Every desk, with its rug and its chair, has to land on the floor the
    /// scale was computed from — otherwise the fit is right and the room is
    /// still cropped.
    func testEveryDeskLiesInsideTheFloorItWasMeasuredFor() throws {
        for count in 4...20 {
            let layout = IsoLayout.fit(sessionCount: count, canvas: canvases[0])
            XCTAssertEqual(layout.desks.count, count)
            for desk in layout.desks {
                XCTAssertGreaterThan(desk.u - IsoLayout.deskFootprint, -0.8)
                XCTAssertGreaterThan(desk.v - IsoLayout.deskFootprint, -0.8)
                XCTAssertLessThan(desk.u + IsoLayout.deskFootprint, layout.span)
                XCTAssertLessThan(desk.v + IsoLayout.deskFootprint, layout.span)
            }
        }
    }

    func testDoublingTheTileWidthDoublesTheScreenDistance() throws {
        let a = IsoProjection(tileWidth: 46, tilt: 0.52, origin: CGPoint(x: 120, y: 80))
        let b = IsoProjection(tileWidth: 92, tilt: 0.52, origin: CGPoint(x: 120, y: 80))
        let pairs: [((Double, Double), (Double, Double))] = [
            ((0, 0), (1, 0)), ((0, 0), (0, 1)), ((-0.8, 3.2), (7.4, -1.1)),
            ((2.5, 2.5), (2.5, 2.5)), ((12, 0.25), (0.25, 12))
        ]
        for (p, q) in pairs {
            let da = distance(a.point(u: p.0, v: p.1, h: 0), a.point(u: q.0, v: q.1, h: 0))
            let db = distance(b.point(u: p.0, v: p.1, h: 0), b.point(u: q.0, v: q.1, h: 0))
            XCTAssertEqual(db, 2 * da, accuracy: 1e-9, "\(p) -> \(q)")
        }
    }

    func testTheBreakRoomNeverOverlapsTheDeskGrid() throws {
        for count in 4...20 {
            let layout = IsoLayout.fit(sessionCount: count, canvas: canvases[0])
            let rightmostDesk = layout.desks.map(\.u).max() ?? 0
            XCTAssertGreaterThan(layout.breakRoom.u0,
                                 rightmostDesk + IsoLayout.deskFootprint,
                                 "count \(count)")
            // The break room sits beyond the office floor as well, not merely
            // beyond the last desk — its wall is what separates the two.
            XCTAssertGreaterThan(layout.breakRoom.u0, layout.span, "count \(count)")
        }
    }

    func testAZeroSizedCanvasYieldsAFiniteNonNegativeScale() throws {
        for canvas in [CGSize.zero, CGSize(width: 0, height: 740),
                       CGSize(width: 1300, height: 0), CGSize(width: 4, height: 4)] {
            let layout = IsoLayout.fit(sessionCount: 8, canvas: canvas)
            XCTAssertTrue(layout.zoom.isFinite, "\(canvas)")
            XCTAssertGreaterThanOrEqual(layout.zoom, 0, "\(canvas)")
            XCTAssertTrue(layout.projection.tileWidth.isFinite)
            XCTAssertGreaterThanOrEqual(layout.projection.tileWidth, 0)
            let p = layout.projection.point(u: 3, v: 4, h: 12)
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "\(canvas)")
        }
    }

    /// The scale comes from the whole scene, office plus break room. Measuring
    /// only the desk grid is the exact mistake that cropped a previous view.
    func testTheScaleShrinksWhenTheSceneGrows() throws {
        let small = IsoLayout.fit(sessionCount: 4, canvas: canvases[0])
        let large = IsoLayout.fit(sessionCount: 20, canvas: canvases[0])
        XCTAssertLessThan(large.zoom, small.zoom)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
