import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The dashboard's palettes, as arithmetic.
///
/// `DashboardBackgroundTests` renders the surface and reads pixels back, which
/// is the only way to know the washes actually reach the window. This file is
/// the other half and needs no renderer at all: a palette is a base plus three
/// washes, and the custom one is a pure function from the colour the user
/// picked. Everything asserted here is a property rather than a pinned number,
/// because the numbers are a design's to change and the properties are not.
final class DashboardPaletteTests: XCTestCase {
    // MARK: - The presets

    /// Ten of them, and the identifiers are what gets persisted.
    func testThereAreTenPresetsAndEachHasAPalette() throws {
        XCTAssertEqual(DashboardPaletteID.presets.count, 10)
        XCTAssertEqual(DashboardPaletteID.allCases.count, 11)

        for identifier in DashboardPaletteID.presets {
            let palette = try XCTUnwrap(identifier.preset)
            XCTAssertEqual(palette.washes.count, 3, "\(identifier.rawValue) is not three washes")
        }
        XCTAssertNil(
            DashboardPaletteID.custom.preset,
            "the custom palette cannot be a constant — it depends on the stored colour"
        )
    }

    /// The identifiers are persisted, so they are lower-case ASCII names that
    /// nothing is tempted to translate or prettify.
    func testTheIdentifiersAreStableRawValues() {
        XCTAssertEqual(
            DashboardPaletteID.allCases.map(\.rawValue),
            [
                "indigo", "graphite", "amber", "teal", "burgundy", "olive",
                "slate", "espresso", "aubergine", "warmGrey", "custom",
            ]
        )
    }

    /// The default is the surface this app already shipped: nobody's dashboard
    /// changes colour without them asking for it.
    func testTheDefaultPaletteIsTheOneTheAppShippedWith() {
        let indigo = DashboardPalette.indigo
        XCTAssertEqual(indigo.base, PaletteRGB(hex: 0x07_09_11))
        XCTAssertEqual(indigo.washes.map(\.color), [
            PaletteRGB(hex: 0x4c_6b_ff),
            PaletteRGB(hex: 0x8a_5c_f6),
            PaletteRGB(hex: 0x2f_a8_c7),
        ])
        XCTAssertEqual(indigo.washes.map(\.opacity), [0.055, 0.040, 0.018])
    }

    /// Every preset's base is dark enough to be a background and carries its
    /// palette's hue rather than being a neutral the washes have to rescue.
    func testEveryPresetBaseIsDarkAndTinted() throws {
        for identifier in DashboardPaletteID.presets {
            let base = try XCTUnwrap(identifier.preset).base
            let channels = [base.red, base.green, base.blue]

            XCTAssertLessThan(
                channels.max() ?? 1,
                48.0 / 255,
                "\(identifier.rawValue)'s base is too light to be a background"
            )
            XCTAssertGreaterThan(
                (channels.max() ?? 0) - (channels.min() ?? 0),
                1.5 / 255,
                "\(identifier.rawValue)'s base is neutral"
            )
        }
    }

    // MARK: - The card tint

    /// The tint the glass cards are given is derived from the base, not stated
    /// per palette — which is what keeps a new palette to four colours.
    ///
    /// Pinned against the pair the app shipped with, because that pair is where
    /// the relationship came from: base `#070911`, tint `#0b0e18` at 62%.
    func testTheCardTintReproducesTheShippedPairFromTheBaseAlone() throws {
        let tint = try XCTUnwrap(NSColor(DashboardPalette.indigo.cardTint).usingColorSpace(.sRGB))

        XCTAssertEqual(Double(tint.redComponent) * 255, 11, accuracy: 0.5)
        XCTAssertEqual(Double(tint.greenComponent) * 255, 14, accuracy: 0.5)
        XCTAssertEqual(Double(tint.blueComponent) * 255, 24, accuracy: 0.5)
        XCTAssertEqual(Double(tint.alphaComponent), 0.62, accuracy: 0.005)
    }

    /// And it follows the base for every palette: lighter than the base it
    /// lifts, still dark, and still the same hue — a tint that drifted off the
    /// base's hue would put a card in one colour on a surface in another.
    func testTheCardTintLiftsEveryPaletteWithoutLeavingItsHue() throws {
        for identifier in DashboardPaletteID.presets {
            let palette = try XCTUnwrap(identifier.preset)
            let tint = try XCTUnwrap(NSColor(palette.cardTint).usingColorSpace(.sRGB))
            let base = palette.base

            XCTAssertGreaterThan(
                Double(tint.blueComponent) + Double(tint.redComponent)
                    + Double(tint.greenComponent),
                base.red + base.green + base.blue,
                "\(identifier.rawValue)'s card tint does not lift its base"
            )
            XCTAssertLessThan(
                max(
                    Double(tint.redComponent),
                    Double(tint.greenComponent),
                    Double(tint.blueComponent)
                ),
                64.0 / 255,
                "\(identifier.rawValue)'s card tint is bright enough to float above the surface"
            )

            let lifted = PaletteRGB(
                red: Double(tint.redComponent),
                green: Double(tint.greenComponent),
                blue: Double(tint.blueComponent)
            )
            XCTAssertEqual(
                hueDistance(lifted.hsb.hue, base.hsb.hue),
                0,
                accuracy: 0.02,
                "\(identifier.rawValue)'s card tint left the base's hue"
            )
        }
    }

    // MARK: - The derived custom palette

    /// A spread of seeds that covers the cases a colour panel can actually
    /// produce: the extremes, the primaries, and a few mid-bright hues.
    private let seeds: [(name: String, seed: PaletteRGB)] = [
        ("white", PaletteRGB(hex: 0xff_ff_ff)),
        ("black", PaletteRGB(hex: 0x00_00_00)),
        ("mid grey", PaletteRGB(hex: 0x80_80_80)),
        ("saturated yellow", PaletteRGB(hex: 0xff_ff_00)),
        ("saturated red", PaletteRGB(hex: 0xff_00_00)),
        ("saturated green", PaletteRGB(hex: 0x00_ff_00)),
        ("saturated cyan", PaletteRGB(hex: 0x00_ff_ff)),
        ("mid blue", PaletteRGB(hex: 0x4c_6b_ff)),
        ("pale pink", PaletteRGB(hex: 0xff_c0_cb)),
        ("dark olive", PaletteRGB(hex: 0x2a_33_10)),
    ]

    /// The one that matters most: a dashboard has light text on it, so the
    /// derived base must be dark for *every* input. `#FFFFFF` is the input a
    /// user will actually try, and a derivation that carried the seed's
    /// brightness through gives them white text on white.
    func testTheDerivedBaseIsDarkForEverySeed() {
        for (name, seed) in seeds {
            let base = DashboardPalette.derived(from: seed).base
            let channels = [base.red, base.green, base.blue]

            XCTAssertLessThan(
                channels.max() ?? 1,
                0.10,
                "the base derived from \(name) is too light to put light text on"
            )
            // Relative luminance, the measure that decides whether text on it
            // is readable — a hue can be dark in one channel and blinding in
            // another.
            let luminance = 0.2126 * base.red + 0.7152 * base.green + 0.0722 * base.blue
            XCTAssertLessThan(luminance, 0.08, "the base derived from \(name) is not a dark surface")
        }
    }

    /// The hue is the part of the seed that survives. A derivation that clamped
    /// saturation to zero would pass the darkness test above and hand every
    /// user the same grey dashboard whatever they picked.
    func testTheDerivedBaseKeepsTheHueOfASaturatedSeed() {
        for (name, seed) in seeds where seed.hsb.saturation >= 0.5 {
            let base = DashboardPalette.derived(from: seed).base

            XCTAssertGreaterThan(
                max(base.red, base.green, base.blue) - min(base.red, base.green, base.blue),
                1.5 / 255,
                "the base derived from \(name) collapsed to grey"
            )
            XCTAssertEqual(
                hueDistance(base.hsb.hue, seed.hsb.hue),
                0,
                accuracy: 0.01,
                "the base derived from \(name) is not that seed's hue any more"
            )

            // …and the washes carry it too, which is where the hue is actually
            // visible: the base is dark enough that a tint in it alone would be
            // hard to see.
            for (index, wash) in DashboardPalette.derived(from: seed).washes.enumerated() {
                XCTAssertGreaterThan(
                    max(wash.color.red, wash.color.green, wash.color.blue)
                        - min(wash.color.red, wash.color.green, wash.color.blue),
                    0.05,
                    "wash \(index) derived from \(name) has no hue in it"
                )
            }
        }
    }

    /// A grey seed has no hue, and the conversion that would find one divides
    /// by a chroma of zero. The palette has to come out neutral, and no channel
    /// anywhere in it may be NaN.
    func testAGreySeedProducesANeutralPaletteWithoutDividingByZero() {
        for hex in [UInt32(0x00_00_00), 0x40_40_40, 0x80_80_80, 0xff_ff_ff] {
            let palette = DashboardPalette.derived(from: PaletteRGB(hex: hex))

            for channel in channels(of: palette) {
                XCTAssertFalse(channel.isNaN, "a grey seed produced NaN in the palette")
            }

            XCTAssertEqual(palette.base.red, palette.base.green, accuracy: 0.001)
            XCTAssertEqual(palette.base.green, palette.base.blue, accuracy: 0.001)
            for wash in palette.washes {
                XCTAssertEqual(wash.color.red, wash.color.green, accuracy: 0.001)
                XCTAssertEqual(wash.color.green, wash.color.blue, accuracy: 0.001)
            }
        }
    }

    /// Black is a colour the panel will hand over, and a surface derived from
    /// it must still be a surface. A base scaled straight off the seed's
    /// brightness would be `#000000`, and the glass cards would then be
    /// refracting nothing — the exact failure the background view exists to
    /// prevent.
    func testABlackSeedStillProducesAVisibleSurface() {
        let palette = DashboardPalette.derived(from: PaletteRGB(hex: 0x00_00_00))

        XCTAssertGreaterThan(
            max(palette.base.red, palette.base.green, palette.base.blue),
            6.0 / 255,
            "a black seed produced a black base"
        )
        // The washes are what lift it off the base at all, so their brightness
        // cannot be taken from the seed either.
        XCTAssertGreaterThan(
            palette.washes.map { max($0.color.red, $0.color.green, $0.color.blue) }.max() ?? 0,
            0.5,
            "a black seed produced washes too dark to lift anything"
        )
    }

    /// Whatever the seed, the result is still a *dashboard* surface: three
    /// washes, weak, in the geometry the presets use.
    func testADerivedPaletteHasTheSameShapeAsAPreset() {
        for (name, seed) in seeds {
            let palette = DashboardPalette.derived(from: seed)

            XCTAssertEqual(palette.washes.count, 3, "\(name) did not produce three washes")
            XCTAssertEqual(palette.washes.map(\.center), [
                DashboardPalette.firstCenter,
                DashboardPalette.secondCenter,
                DashboardPalette.thirdCenter,
            ])
            for wash in palette.washes {
                XCTAssertLessThanOrEqual(wash.opacity, 0.06, "\(name) has a wash that is a blob")
            }
        }
    }

    // MARK: - Persistence

    /// The chosen palette and the custom colour both have to survive a
    /// relaunch: an appearance that resets on every launch is worse than no
    /// setting at all.
    func testThePaletteChoiceAndTheCustomColourSurviveARelaunch() {
        let suiteName = "palette-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppSettingsStore(defaults: defaults).dashboardPaletteID, .indigo)

        for identifier in DashboardPaletteID.allCases {
            AppSettingsStore(defaults: defaults).dashboardPaletteID = identifier
            XCTAssertEqual(AppSettingsStore(defaults: defaults).dashboardPaletteID, identifier)
        }

        let store = AppSettingsStore(defaults: defaults)
        store.dashboardCustomColorHex = PaletteRGB(hex: 0x3f_a9_2c).hexString
        store.dashboardPaletteID = .custom

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dashboardCustomSeed, PaletteRGB(hex: 0x3f_a9_2c))
        XCTAssertEqual(
            reloaded.dashboardPalette,
            DashboardPalette.derived(from: PaletteRGB(hex: 0x3f_a9_2c))
        )
    }

    /// A stored value that no longer parses — a hand-edited preference, a
    /// truncated write — must not become black.
    func testAnUnreadableStoredColourFallsBackRatherThanGoingBlack() {
        let suiteName = "palette-broken-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        store.dashboardPaletteID = .custom
        store.dashboardCustomColorHex = "not a colour"

        XCTAssertNil(store.dashboardCustomSeed)
        XCTAssertEqual(
            store.dashboardPalette,
            DashboardPalette.derived(from: DashboardPalette.defaultCustomSeed)
        )
    }

    /// The hex round-trip itself, in both directions, because it is the format
    /// the setting is stored in.
    func testTheHexRepresentationRoundTrips() {
        for hex in [UInt32(0x00_00_00), 0xff_ff_ff, 0x4c_6b_ff, 0x0c_07_0d] {
            let colour = PaletteRGB(hex: hex)
            XCTAssertEqual(PaletteRGB(hexString: colour.hexString), colour)
        }

        XCTAssertEqual(PaletteRGB(hexString: "#4C6BFF"), PaletteRGB(hex: 0x4c_6b_ff))
        XCTAssertNil(PaletteRGB(hexString: ""))
        XCTAssertNil(PaletteRGB(hexString: "4C6BF"))
        XCTAssertNil(PaletteRGB(hexString: "ZZZZZZ"))
    }

    // MARK: - Helpers

    /// Hue is a circle: 0.99 and 0.01 are two hundredths apart, not ninety-
    /// eight.
    private func hueDistance(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 1)
        return min(raw, 1 - raw)
    }

    private func channels(of palette: DashboardPalette) -> [Double] {
        [palette.base.red, palette.base.green, palette.base.blue]
            + palette.washes.flatMap { [$0.color.red, $0.color.green, $0.color.blue] }
    }
}
