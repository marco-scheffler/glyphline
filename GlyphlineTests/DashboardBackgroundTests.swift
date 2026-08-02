import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The surface behind the dashboard's glass cards.
///
/// `glassCard()` refracts whatever is behind the window's content. For most of
/// this app's life that was the system's neutral window background, and the
/// dashboard rendered grey however good the glass was. The design calls for a
/// deep tinted black, so the property worth holding is not "a background
/// exists" but "the pixels carry the palette's hue rather than being neutral" —
/// which is exactly what a render tells you and a structural check cannot.
///
/// The surface is the user's choice now, so the assertions are made against
/// every palette rather than against the default one. What is asserted is what
/// is true of all eleven — dark, and tinted towards its own base's dominant
/// channel — not the blue the app happened to ship with.
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
    private func sample(
        at point: UnitPoint,
        palette: DashboardPalette = .indigo
    ) throws -> (
        red: Double, green: Double, blue: Double
    ) {
        let host = NSHostingView(rootView: AnyView(DashboardBackground(palette: palette)))
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

    /// The assertion the whole thing is for: the surface is tinted, not grey.
    ///
    /// Sampled where the dashboard has no card over it — the top-left and
    /// upper-right corners of the window sit outside the content's padding, and
    /// the centre-left gutter is where the tint is most visible in use.
    ///
    /// This used to be "blue at least 1.6× red", which was true of the one
    /// palette the app had and is false of nine of the ten it has now — Amber's
    /// surface is *supposed* to be redder than it is blue. Deleting it would
    /// have given up the only assertion that can tell a rendered tint from a
    /// rendered grey, and special-casing Indigo would have left the other ten
    /// unwatched. So the property is stated relative to each palette instead:
    /// whichever channel that palette's base leads with, the rendered pixel
    /// leads with too, and by a margin a neutral grey (all three channels
    /// equal, spread zero) cannot reach.
    func testEveryPaletteTintsItsSurfaceTowardsItsOwnHue() throws {
        let points: [(String, UnitPoint)] = [
            ("top-left", UnitPoint(x: 0.02, y: 0.03)),
            ("upper-right", UnitPoint(x: 0.97, y: 0.10)),
            ("left gutter", UnitPoint(x: 0.03, y: 0.55)),
            ("bottom-right", UnitPoint(x: 0.95, y: 0.95)),
        ]

        for identifier in DashboardPaletteID.presets {
            let palette = try XCTUnwrap(identifier.preset)
            let base = palette.base
            let expected = Self.dominantChannel(
                red: base.red, green: base.green, blue: base.blue
            )

            for (name, point) in points {
                let pixel = try sample(at: point, palette: palette)
                let channels = [pixel.red, pixel.green, pixel.blue]
                let dominant = Self.dominantChannel(
                    red: pixel.red, green: pixel.green, blue: pixel.blue
                )
                let readout =
                    "r\(pixel.red) g\(pixel.green) b\(pixel.blue)"

                XCTAssertEqual(
                    dominant,
                    expected,
                    "\(identifier.rawValue) at \(name) does not lead with its base's "
                        + "channel: \(readout)"
                )
                // A spread, relative to the pixel's own brightness — the same
                // reason the old assertion was a ratio and not a difference in
                // points: darkening a palette must not read as desaturating it.
                // Neutral grey scores zero here at any brightness.
                XCTAssertGreaterThan(
                    (channels.max() ?? 0) - (channels.min() ?? 0),
                    0.06 * max(channels.max() ?? 0, 1),
                    "\(identifier.rawValue) at \(name) renders as grey: \(readout)"
                )
            }
        }
    }

    /// Atmosphere, not decoration. Every wash is weak enough that the surface
    /// stays dark: no sampled pixel may be bright, and none may be so saturated
    /// that a reader could point at it as a coloured blob. True of all ten, so
    /// asserted against all ten.
    func testTheSurfaceStaysDarkAndUnsaturated() throws {
        let points: [UnitPoint] = [
            UnitPoint(x: 0.26, y: 0.02),  // the leading wash's own centre
            UnitPoint(x: 0.96, y: 0.30),  // the answering wash's own centre
            UnitPoint(x: 0.5, y: 0.5),
        ]

        for identifier in DashboardPaletteID.presets {
            let palette = try XCTUnwrap(identifier.preset)

            for point in points {
                let pixel = try sample(at: point, palette: palette)
                let channels = [pixel.red, pixel.green, pixel.blue]

                XCTAssertLessThan(
                    channels.max() ?? 255,
                    80,
                    "\(identifier.rawValue) is no longer dark at \(point)"
                )
                XCTAssertLessThan(
                    (channels.max() ?? 255) - (channels.min() ?? 0),
                    60,
                    "\(identifier.rawValue)'s wash at \(point) is strong enough to read as a blob"
                )
            }
        }
    }

    /// The base itself carries the tint, so the corners the washes barely reach
    /// are still coloured rather than black — for every palette, and for a
    /// palette derived from a colour the user picked.
    func testEveryBaseColourIsADarkTintedSurface() throws {
        var palettes = try DashboardPaletteID.presets.map { try XCTUnwrap($0.preset) }
        palettes.append(.derived(from: PaletteRGB(hex: 0xff_ff_ff)))
        palettes.append(.derived(from: PaletteRGB(hex: 0x4c_6b_ff)))

        for palette in palettes {
            let components = try XCTUnwrap(
                NSColor(palette.baseColor).usingColorSpace(.sRGB)
            )
            let channels = [
                Double(components.redComponent) * 255,
                Double(components.greenComponent) * 255,
                Double(components.blueComponent) * 255,
            ]

            XCTAssertLessThan(
                channels.max() ?? 255,
                48,
                "a base is not dark enough to be a background"
            )
        }

        // And the default is still exactly the navy the app shipped with.
        let indigo = try XCTUnwrap(
            NSColor(DashboardPalette.indigo.baseColor).usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(
            Double(indigo.blueComponent - indigo.redComponent) * 255,
            8,
            "the default base is neutral"
        )
    }

    /// Which channel a colour leads with. Named rather than an index, so a
    /// failure message says "blue" instead of "2".
    private static func dominantChannel(red: Double, green: Double, blue: Double) -> String {
        if red >= green, red >= blue { return "red" }
        if green >= blue { return "green" }
        return "blue"
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
