import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The surface behind the dashboard's glass cards.
///
/// `glassCard()` refracts whatever is behind the window's content. For most of
/// this app's life that was the system's neutral window background, and the
/// dashboard rendered grey however good the glass was. The design calls for a
/// deep blue-black, so the property worth holding is not "a background exists"
/// but "the pixels are blue-tinted rather than neutral" — which is exactly what
/// a render tells you and a structural check cannot.
///
/// Rendered off-screen through `NSHostingView`, the same technique
/// `MenuBarFooterTests` and `AccountQuotaGridTests` use for layout, taken one
/// step further to pixels.
@MainActor
final class DashboardBackgroundTests: XCTestCase {
    private let size = NSSize(width: 900, height: 600)

    /// Renders the background and reads one pixel back, in sRGB.
    ///
    /// `at` is in unit coordinates with the origin top-left, so the points a
    /// test names line up with the way the washes are specified.
    private func sample(at point: UnitPoint) throws -> (
        red: Double, green: Double, blue: Double
    ) {
        let host = NSHostingView(rootView: AnyView(DashboardBackground()))
        host.frame = NSRect(origin: .zero, size: size)
        // The background is drawn from fixed hex values, but pinning the
        // appearance keeps the render independent of whatever the machine
        // running the suite is set to.
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "the hosting view gave no bitmap to render into"
        )
        host.cacheDisplay(in: host.bounds, to: rep)

        let x = Int((Double(rep.pixelsWide) - 1) * Double(point.x))
        // `NSBitmapImageRep.colorAt` counts rows from the top.
        let y = Int((Double(rep.pixelsHigh) - 1) * Double(point.y))
        let raw = try XCTUnwrap(rep.colorAt(x: x, y: y), "no pixel at \(x)/\(y)")
        let color = try XCTUnwrap(
            raw.usingColorSpace(.sRGB),
            "the sampled pixel could not be expressed in sRGB"
        )

        return (
            red: Double(color.redComponent) * 255,
            green: Double(color.greenComponent) * 255,
            blue: Double(color.blueComponent) * 255
        )
    }

    /// The assertion the whole thing is for: the surface is blue, not grey.
    ///
    /// Sampled where the dashboard has no card over it — the top-left and
    /// upper-right corners of the window sit outside the content's padding, and
    /// the centre-left gutter is where the tint is most visible in use.
    ///
    /// The threshold is what separates the two failure modes that matter. A
    /// neutral grey background has all three channels within a point or two of
    /// each other; the specified surface has blue at least ~12 points above red
    /// everywhere. Anything in between is not a look anybody asked for.
    func testTheBackgroundIsBlueTintedEverywhereItIsSampled() throws {
        let points: [(String, UnitPoint)] = [
            ("top-left", UnitPoint(x: 0.02, y: 0.03)),
            ("upper-right", UnitPoint(x: 0.97, y: 0.10)),
            ("left gutter", UnitPoint(x: 0.03, y: 0.55)),
            ("bottom-right", UnitPoint(x: 0.95, y: 0.95)),
        ]

        for (name, point) in points {
            let pixel = try sample(at: point)

            XCTAssertGreaterThan(
                pixel.blue - pixel.red,
                12,
                "\(name) is not blue-tinted: r\(pixel.red) g\(pixel.green) b\(pixel.blue)"
            )
            XCTAssertGreaterThan(
                pixel.blue - pixel.green,
                6,
                "\(name) reads as a grey-blue haze rather than a tint: "
                    + "r\(pixel.red) g\(pixel.green) b\(pixel.blue)"
            )
        }
    }

    /// Atmosphere, not decoration. Every wash is weak enough that the surface
    /// stays a dark navy: no sampled pixel may be bright, and none may be so
    /// saturated that a reader could point at it as a coloured blob.
    func testTheSurfaceStaysDarkAndUnsaturated() throws {
        let points: [UnitPoint] = [
            UnitPoint(x: 0.26, y: 0.02),  // the indigo wash's own centre
            UnitPoint(x: 0.96, y: 0.30),  // the violet wash's own centre
            UnitPoint(x: 0.5, y: 0.5),
        ]

        for point in points {
            let pixel = try sample(at: point)

            XCTAssertLessThan(
                max(pixel.red, pixel.green, pixel.blue),
                80,
                "the surface is no longer dark at \(point)"
            )
            XCTAssertLessThan(
                pixel.blue - pixel.red,
                60,
                "the wash at \(point) is strong enough to read as a blob"
            )
        }
    }

    /// The base itself carries the tint, so the corners the washes barely reach
    /// are still blue rather than black.
    func testTheBaseColourIsADesaturatedNavy() throws {
        let components = try XCTUnwrap(
            NSColor(DashboardBackground.baseColor).usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThan(
            Double(components.blueComponent - components.redComponent) * 255,
            8,
            "the base is neutral"
        )
        XCTAssertLessThan(
            Double(components.blueComponent) * 255,
            48,
            "the base is not dark enough to be a background"
        )
    }

    /// Chart bars are drawn in per-model colours, several of which are blue or
    /// purple — the two hues the background is made of. They have to stay
    /// distinguishable from it, which for a bar on a flat field means a real
    /// lightness gap, not a hue difference.
    func testTheModelColoursStillReadAgainstTheSurface() throws {
        let brightest = try sample(at: UnitPoint(x: 0.26, y: 0.02))
        let backgroundLuminance =
            0.2126 * brightest.red + 0.7152 * brightest.green + 0.0722 * brightest.blue

        for model in [
            "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
            "claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6",
        ] {
            let color = try XCTUnwrap(
                NSColor(DashboardPresentation.modelColor(model)).usingColorSpace(.sRGB)
            )
            let luminance =
                (0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)) * 255

            XCTAssertGreaterThan(
                luminance - backgroundLuminance,
                40,
                "\(model) sinks into the background"
            )
        }
    }
}
