import AppKit
import SwiftUI
import XCTest
@testable import Glyphline

/// The one thing about the static picture that a test run at a single backing
/// store scale can never see: whether the drawing fills the bitmap it was
/// allocated. The bitmap is sized in pixels — points times scale — while every
/// piece of layout above it is in points, and a picture that filled a quarter of
/// its own bitmap would look perfect on a one-to-one display and be a 2x zoom of
/// one corner on a Retina one.
@MainActor
final class StaticSceneScaleTests: XCTestCase {
    private let size = CGSize(width: 900, height: 600)
    private let instant = Date(timeIntervalSince1970: 1_781_708_400)

    private func monaco() throws -> Circuit {
        try XCTUnwrap(CircuitCatalog.bundled().circuit("monaco"))
    }

    private func world(scale: Int) throws -> CGImage {
        let circuit = try monaco()
        let sun = SunPosition.at(latitude: circuit.lat, longitude: circuit.lon, date: instant)
        let light = SceneLight.make(elevation: sun.elevation, azimuth: sun.azimuth,
                                    mapRotation: circuit.rot, weather: .clear)
        return try XCTUnwrap(StaticSceneImage.build(circuit: circuit, size: size,
                                                    scale: scale, light: light))
    }

    func testTheBitmapIsAllocatedInPixels() throws {
        let one = try world(scale: 1), two = try world(scale: 2)
        XCTAssertEqual(one.width, 900)
        XCTAssertEqual(two.width, 1800)
        XCTAssertEqual(two.height, 1200)
    }

    /// The same piece of road has to land at the same *fractional* position in
    /// both bitmaps. A picture drawn in points into a pixel-sized bitmap would
    /// put it at half of that in the larger one.
    func testTheSameRoadLandsAtTheSameFractionalPositionAtEveryScale() throws {
        let circuit = try monaco()
        let fit = CircuitFit(circuit: circuit, in: size)
        let count = circuit.points.count
        let road = fit.point(circuit.points[(circuit.startIdx + count / 2) % count])

        for scale in [1, 2, 3] {
            let rep = NSBitmapImageRep(cgImage: try world(scale: scale))
            let colour = try XCTUnwrap(rep.colorAt(x: Int((road.x * CGFloat(scale)).rounded()),
                                                   y: Int((road.y * CGFloat(scale)).rounded())))
            let red = Int((colour.redComponent * 255).rounded())
            let green = Int((colour.greenComponent * 255).rounded())
            let blue = Int((colour.blueComponent * 255).rounded())
            XCTAssertEqual(red, green, "at scale \(scale) this pixel is not the road")
            XCTAssertEqual(green, blue, "at scale \(scale) this pixel is not the road")
            XCTAssertTrue((18...55).contains(red),
                          "at scale \(scale) the road pixel is \(red), so the drawing "
                          + "does not fill the bitmap it was given")
        }
    }

    /// And the drawing has to reach every edge of the bitmap, not just of its
    /// first quadrant: the terrain is centred with `CircuitFit.margin` around it,
    /// so a band just inside each edge is sky and everything further in is not.
    func testTheDrawingReachesEveryEdgeOfTheBitmap() throws {
        for scale in [1, 2] {
            let image = try world(scale: scale)
            let rep = NSBitmapImageRep(cgImage: image)
            // Well inside the terrain box on all four sides.
            let inset = Int(CircuitFit.margin) * scale + 8 * scale
            for (label, x, y) in [
                ("left", inset, image.height / 2),
                ("right", image.width - inset, image.height / 2),
                ("top", image.width / 2, inset),
                ("bottom", image.width / 2, image.height - inset),
            ] {
                let colour = try XCTUnwrap(rep.colorAt(x: x, y: y))
                XCTAssertGreaterThan(Double(colour.alphaComponent), 0.99,
                                     "at scale \(scale) the \(label) edge is unpainted")
            }
            // The far corner is the one a quarter-filled picture never touches.
            let corner = try XCTUnwrap(rep.colorAt(x: image.width - inset,
                                                   y: image.height - inset))
            XCTAssertGreaterThan(Double(corner.alphaComponent), 0.99,
                                 "at scale \(scale) the far corner is unpainted")
        }
    }
}

/// The other half of the same question: the built bitmap is handed to a `Canvas`
/// as an `Image` carrying its own scale, and that is where a pixel-sized picture
/// would be stretched across the view at 2x if the scale were dropped.
@MainActor
final class SceneImagePresentationTests: XCTestCase {
    private struct Presenter: View {
        let world: CGImage
        let scale: CGFloat

        var body: some View {
            Canvas { context, size in
                context.draw(Image(decorative: world, scale: scale),
                             in: CGRect(origin: .zero, size: size))
            }
        }
    }

    /// A bitmap whose own top-left quarter is marked has to arrive in the view's
    /// top-left quarter, at 2x as at 1x.
    func testAPixelSizedWorldFillsTheViewAtEveryScale() throws {
        let size = CGSize(width: 200, height: 100)
        for scale in [1, 2] {
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 0, 1, 1])))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            // Core Graphics is y-up, so the top half is the high half.
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 0, 1])))
            context.fill(CGRect(x: 0, y: context.height / 2,
                                width: context.width / 2, height: context.height / 2))
            let world = try XCTUnwrap(context.makeImage())

            let renderer = ImageRenderer(
                content: Presenter(world: world, scale: CGFloat(scale))
                    .frame(width: size.width, height: size.height))
            renderer.scale = CGFloat(scale)
            let data = try XCTUnwrap(try XCTUnwrap(renderer.nsImage).tiffRepresentation)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))

            func quadrant(_ x: Double, _ y: Double) throws -> Bool {
                let colour = try XCTUnwrap(rep.colorAt(x: Int(Double(rep.pixelsWide) * x),
                                                       y: Int(Double(rep.pixelsHigh) * y)))
                return colour.redComponent > 0.5
            }

            XCTAssertTrue(try quadrant(0.25, 0.25),
                          "at scale \(scale) the marked quarter is not where it belongs")
            XCTAssertFalse(try quadrant(0.75, 0.25),
                           "at scale \(scale) the marked quarter was stretched sideways")
            XCTAssertFalse(try quadrant(0.25, 0.75),
                           "at scale \(scale) the marked quarter was stretched downwards")
        }
    }
}
