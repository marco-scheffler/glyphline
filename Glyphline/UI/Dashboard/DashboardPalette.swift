import SwiftUI

/// A colour the way this app's design speaks about one: three sRGB channels in
/// `0…1`, and nothing else.
///
/// Deliberately not `Color`. `Color` is opaque — it cannot be taken apart again
/// without going through `NSColor` and a colour-space conversion, which is
/// `AppKit` work that a pure derivation must not need. Every palette decision
/// here is arithmetic on numbers, so it is testable without rendering anything.
struct PaletteRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The design's own `#rrggbb`, the same notation `Color(rgbHex:)` takes.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// Six hex digits, upper case, no `#`.
    ///
    /// This is what gets persisted. It is stable in a way an archived `NSColor`
    /// is not: it names three integers in a colour space this file states,
    /// rather than an object graph whose shape belongs to AppKit and whose
    /// colour space may be a catalog name that resolves differently later.
    var hexString: String {
        func channel(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    /// Nil for anything that is not six hex digits, so a hand-edited or
    /// truncated preference falls back to the default rather than to black.
    init?(hexString: String) {
        let trimmed = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        self.init(hex: value)
    }

    // MARK: - Hue, saturation, brightness

    /// Hue in `0…1`, saturation and brightness in `0…1`.
    struct HSB: Equatable, Sendable {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    /// The HSB reading of this colour.
    ///
    /// Both divisions are guarded. A grey has zero chroma and a black has zero
    /// brightness, and both are inputs a user can actually pick — an unguarded
    /// conversion returns NaN for them, which then travels silently into every
    /// derived channel and renders as nothing at all.
    var hsb: HSB {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum

        guard chroma > 0 else {
            return HSB(hue: 0, saturation: 0, brightness: maximum)
        }

        let hue: Double
        switch maximum {
        case red: hue = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / chroma + 2
        default: hue = (red - green) / chroma + 4
        }

        return HSB(
            hue: (hue / 6 + 1).truncatingRemainder(dividingBy: 1),
            // `maximum` is at least `chroma`, which is positive here.
            saturation: chroma / maximum,
            brightness: maximum
        )
    }

    /// The inverse, for the washes and the base the derivation builds by hue.
    init(hsb: HSB) {
        let hue = (hsb.hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        let saturation = min(max(hsb.saturation, 0), 1)
        let brightness = min(max(hsb.brightness, 0), 1)

        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch index {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }
}

/// One dashboard surface: the base the washes sit on, and the washes.
///
/// A palette is defined by its base and its washes alone. Everything else the
/// surface needs — in particular the tint the glass cards are given — is
/// derived from those, so adding an eleventh palette is four colours and no
/// further decisions.
struct DashboardPalette: Equatable, Sendable {
    /// One radial wash, in unit coordinates so it scales with any window size.
    struct Wash: Equatable, Sendable {
        let color: PaletteRGB
        /// Peak opacity, at the centre.
        let opacity: Double
        /// Centre, as a fraction of the container's width and height. Values
        /// outside 0…1 push a wash's centre off-screen on purpose — only its
        /// falloff reaches the window.
        let center: UnitPoint
        /// Radius as a fraction of the container's larger edge.
        let radius: Double
    }

    /// The base: a very dark, low-chroma version of the palette's hue.
    ///
    /// Not black. Black would leave the glass sampling something neutral again;
    /// the hue has to be in the base, because the washes are too weak to carry
    /// the tint on their own out at the corners.
    let base: PaletteRGB

    /// Three washes, in draw order.
    let washes: [Wash]

    var baseColor: Color { base.color }

    /// What `glassCard()` tints its glass with, so the cards sit close to the
    /// base instead of floating above it.
    ///
    /// Derived rather than stated per palette. The relationship comes from the
    /// pair the design shipped with — base `#070911`, tint `#0b0e18` at 62% —
    /// and is `channel * 1.35 + 1.5/255`: a proportional lift, so a palette
    /// with a heavier base gets a heavier card, plus a small constant so a
    /// near-black base still lifts at all (a purely proportional rule leaves a
    /// black base tinting with black, which is the "untinted glass on nothing"
    /// case the tint exists to avoid). Rounded to eight bits that formula
    /// reproduces `#0b0e18` exactly, so the default palette's cards are the
    /// cards this app already had.
    var cardTint: Color {
        func lift(_ value: Double) -> Double {
            min(value * 1.35 + 1.5 / 255, 1)
        }
        return PaletteRGB(
            red: lift(base.red),
            green: lift(base.green),
            blue: lift(base.blue)
        ).color.opacity(Self.cardTintOpacity)
    }

    static let cardTintOpacity = 0.62
}

// MARK: - The presets

extension DashboardPalette {
    /// The geometry every preset shares.
    ///
    /// The washes have to stay off most of the window, not merely be faint. A
    /// radius near 1.0 blankets the whole surface, and three blankets stack
    /// into a lift everywhere — which turns the near-black base into slate and
    /// lifts the glass with it. These radii keep the corners and the lower half
    /// at the base colour, which is what makes the chart's colours look lit
    /// rather than washed.
    static let firstCenter = UnitPoint(x: 0.26, y: 0.02)
    static let secondCenter = UnitPoint(x: 0.99, y: 0.24)
    static let thirdCenter = UnitPoint(x: 0.58, y: 1.10)
    static let radii = [0.62, 0.48, 0.42]

    /// A palette from four hex values, so a preset reads as the table it was
    /// copied out of rather than as twenty lines of struct literals.
    static func make(
        base: PaletteRGB,
        washes trio: [(color: PaletteRGB, opacity: Double)],
        firstCenter: UnitPoint = DashboardPalette.firstCenter,
        secondCenter: UnitPoint = DashboardPalette.secondCenter
    ) -> DashboardPalette {
        let centers = [firstCenter, secondCenter, thirdCenter]
        return DashboardPalette(
            base: base,
            washes: trio.enumerated().map { index, wash in
                Wash(
                    color: wash.color,
                    opacity: wash.opacity,
                    center: centers[index],
                    radius: radii[index]
                )
            }
        )
    }

    private static func make(
        base: UInt32,
        _ first: (UInt32, Double),
        _ second: (UInt32, Double),
        _ third: (UInt32, Double),
        firstCenter: UnitPoint = DashboardPalette.firstCenter,
        secondCenter: UnitPoint = DashboardPalette.secondCenter
    ) -> DashboardPalette {
        make(
            base: PaletteRGB(hex: base),
            washes: [first, second, third].map {
                (color: PaletteRGB(hex: $0.0), opacity: $0.1)
            },
            firstCenter: firstCenter,
            secondCenter: secondCenter
        )
    }

    /// The default, and the surface this app shipped with: indigo upper-left
    /// carries the main tint, violet answers it on the right, and a cool teal
    /// at the bottom keeps the lower half from closing into flat black.
    static let indigo = make(
        base: 0x07_09_11,
        (0x4c_6b_ff, 0.055),
        (0x8a_5c_f6, 0.040),
        (0x2f_a8_c7, 0.018)
    )

    /// The two neutral palettes carry a slightly different geometry, from the
    /// design: with no hue to place, the upper-left wash starts flush with the
    /// top edge instead of just below it.
    static let graphite = make(
        base: 0x0a_0a_0c,
        (0x8e_8e_a0, 0.050),
        (0x6f_6f_80, 0.035),
        (0x5a_5a_68, 0.015),
        firstCenter: UnitPoint(x: 0.30, y: 0.00),
        secondCenter: UnitPoint(x: 0.98, y: 0.26)
    )

    static let amber = make(
        base: 0x0e_0a_06,
        (0xff_9d_3c, 0.050),
        (0xe0_63_2a, 0.034),
        (0xc9_8a_2f, 0.016)
    )

    static let teal = make(
        base: 0x04_0d_0e,
        (0x22_c7_d6, 0.050),
        (0x1f_8f_a8, 0.034),
        (0x2f_c7_9a, 0.016)
    )

    static let burgundy = make(
        base: 0x0f_05_09,
        (0xd6_33_6c, 0.045),
        (0x8a_23_50, 0.032),
        (0xb0_40_5f, 0.015)
    )

    static let olive = make(
        base: 0x07_0c_07,
        (0x5f_bf_5f, 0.045),
        (0x3f_8f_5a, 0.032),
        (0x7f_ae_4a, 0.015)
    )

    static let slate = make(
        base: 0x0a_0c_10,
        (0x80_98_b8, 0.046),
        (0x64_78_a0, 0.030),
        (0x70_88_9c, 0.014)
    )

    static let espresso = make(
        base: 0x0c_09_08,
        (0xb8_84_5a, 0.046),
        (0x8f_5f_3c, 0.030),
        (0xa0_70_50, 0.014)
    )

    static let aubergine = make(
        base: 0x0c_07_0d,
        (0x9b_5f_b0, 0.046),
        (0x6d_3d_80, 0.030),
        (0x82_50_8f, 0.014)
    )

    static let warmGrey = make(
        base: 0x0c_0b_0a,
        (0xa8_9a_8c, 0.046),
        (0x8a_7f_74, 0.030),
        (0x94_8a_80, 0.014),
        firstCenter: UnitPoint(x: 0.30, y: 0.00),
        secondCenter: UnitPoint(x: 0.98, y: 0.26)
    )
}

// MARK: - The custom palette

extension DashboardPalette {
    /// The seed a custom palette starts from before the user has picked
    /// anything: the default palette's own leading wash, so the picker opens on
    /// the colour the dashboard is already made of.
    static let defaultCustomSeed = PaletteRGB(hex: 0x4c_6b_ff)

    /// A whole palette from the one colour the user picked.
    ///
    /// Asking anyone to choose a base plus three washes by hand is homework, so
    /// the picker takes a single colour and this builds the surface around it.
    ///
    /// The shape of it: the *hue* comes from the seed, almost nothing else
    /// does. Brightness is thrown away and replaced — the base gets a fixed
    /// dark range and the washes fixed bright ones — because the dashboard's
    /// labels are drawn light on this surface and a user picking `#FFFFFF` must
    /// not end up with white text on white. Saturation is bounded rather than
    /// copied for the same reason in reverse: a seed with no chroma still has
    /// to produce a neutral palette, and a fully saturated seed must not push
    /// the base into a colour cast strong enough to read as a blob.
    ///
    /// Pure, and the only genuinely testable piece of this feature: colour in,
    /// palette out, no rendering and no environment.
    static func derived(from seed: PaletteRGB) -> DashboardPalette {
        let hsb = seed.hsb
        let hue = hsb.hue
        let isNeutral = hsb.saturation <= 0

        /// Saturation for a derived colour, or zero if the seed had none —
        /// which is what keeps a grey seed producing a grey palette instead of
        /// a palette in whatever hue the guard in `hsb` happened to return.
        func saturation(floor: Double, ceiling: Double) -> Double {
            isNeutral ? 0 : min(max(hsb.saturation, floor), ceiling)
        }

        // Dark for every seed, and never fully black: the range is bounded at
        // both ends, so `#FFFFFF` lands at the top of it (still a background)
        // and `#000000` lands at the bottom of it (still a surface rather than
        // a hole).
        let base = PaletteRGB(
            hsb: PaletteRGB.HSB(
                hue: hue,
                saturation: saturation(floor: 0.45, ceiling: 0.85),
                brightness: 0.043 + 0.030 * hsb.brightness
            )
        )

        // The washes carry the hue. Their brightness is fixed rather than taken
        // from the seed, which is what makes a black seed still produce a
        // visible surface: the base goes as dark as it is allowed to, and the
        // washes lift it anyway.
        let washColors: [(PaletteRGB, Double)] = [
            (
                PaletteRGB(
                    hsb: .init(
                        hue: hue,
                        saturation: saturation(floor: 0.55, ceiling: 0.95),
                        brightness: 0.86
                    )
                ),
                0.050
            ),
            (
                // Shifted a little around the wheel, the way the presets answer
                // their leading wash with a neighbouring hue rather than with a
                // second shade of the same one — three shades of one hue read
                // as a single banded gradient.
                PaletteRGB(
                    hsb: .init(
                        hue: hue + 0.06,
                        saturation: saturation(floor: 0.50, ceiling: 0.90) * 0.9,
                        brightness: 0.66
                    )
                ),
                0.034
            ),
            (
                PaletteRGB(
                    hsb: .init(
                        hue: hue - 0.06,
                        saturation: saturation(floor: 0.45, ceiling: 0.85) * 0.75,
                        brightness: 0.72
                    )
                ),
                0.016
            ),
        ]

        return make(
            base: base,
            washes: washColors.map { (color: $0.0, opacity: $0.1) }
        )
    }
}

// MARK: - Which palette the user chose

/// The palettes the user can pick, by identifier.
///
/// The raw values are persisted and are deliberately not localised: a
/// translated identifier would change a user's saved setting the moment they
/// changed the app's language.
enum DashboardPaletteID: String, CaseIterable, Identifiable, Sendable {
    case indigo
    case graphite
    case amber
    case teal
    case burgundy
    case olive
    case slate
    case espresso
    case aubergine
    case warmGrey
    case custom

    var id: String { rawValue }

    /// The ten presets, in the design's order. `custom` is separate because it
    /// is not a palette until the user has picked a colour for it.
    static var presets: [DashboardPaletteID] {
        allCases.filter { $0 != .custom }
    }

    /// Nil for `.custom`, whose palette depends on the stored seed.
    var preset: DashboardPalette? {
        switch self {
        case .indigo: DashboardPalette.indigo
        case .graphite: DashboardPalette.graphite
        case .amber: DashboardPalette.amber
        case .teal: DashboardPalette.teal
        case .burgundy: DashboardPalette.burgundy
        case .olive: DashboardPalette.olive
        case .slate: DashboardPalette.slate
        case .espresso: DashboardPalette.espresso
        case .aubergine: DashboardPalette.aubergine
        case .warmGrey: DashboardPalette.warmGrey
        case .custom: nil
        }
    }

    var displayName: String {
        switch self {
        case .indigo:
            String(localized: "Indigo", comment: "Name of a dashboard background palette: a deep blue-violet. A colour name; keep it as the colour is called in your language.")
        case .graphite:
            String(localized: "Graphite", comment: "Name of a dashboard background palette: neutral dark grey. A colour name; keep it as the colour is called in your language.")
        case .amber:
            String(localized: "Amber", comment: "Name of a dashboard background palette: warm orange. A colour name; keep it as the colour is called in your language.")
        case .teal:
            String(localized: "Teal", comment: "Name of a dashboard background palette: blue-green. A colour name; keep it as the colour is called in your language.")
        case .burgundy:
            String(localized: "Burgundy", comment: "Name of a dashboard background palette: deep wine red. A colour name, from the French wine region; keep it as the colour is called in your language.")
        case .olive:
            String(localized: "Olive", comment: "Name of a dashboard background palette: muted green. A colour name; keep it as the colour is called in your language.")
        case .slate:
            String(localized: "Slate", comment: "Name of a dashboard background palette: cool blue-grey. A colour name, from the stone; keep it as the colour is called in your language.")
        case .espresso:
            String(localized: "Espresso", comment: "Name of a dashboard background palette: dark coffee brown. A colour name, from the coffee; the word is a loanword in most languages and usually stays.")
        case .aubergine:
            String(localized: "Aubergine", comment: "Name of a dashboard background palette: dark purple. A colour name, from the vegetable; keep it as the colour is called in your language.")
        case .warmGrey:
            String(localized: "Warm Grey", comment: "Name of a dashboard background palette: a grey with a brown cast. A colour name; keep it as the colour is called in your language.")
        case .custom:
            String(localized: "Custom", comment: "The dashboard background palette the user mixed themselves with the colour picker, beside the ten named ones.")
        }
    }
}

// MARK: - The palette in the environment

private struct DashboardPaletteKey: EnvironmentKey {
    /// The default palette, so any view rendered outside the dashboard window —
    /// a preview, a test that hosts one card on its own — still gets the
    /// surface this app shipped with rather than an untinted one.
    static let defaultValue = DashboardPalette.indigo
}

extension EnvironmentValues {
    /// The surface the dashboard's glass is sitting on.
    ///
    /// In the environment rather than passed down: `glassCard()` is called from
    /// a dozen views several levels deep, and threading a palette through all
    /// of them would put a parameter on every one of those views for a value
    /// none of them has an opinion about.
    var dashboardPalette: DashboardPalette {
        get { self[DashboardPaletteKey.self] }
        set { self[DashboardPaletteKey.self] = newValue }
    }
}

extension AppSettingsStore {
    /// The palette the dashboard should draw right now.
    ///
    /// An unreadable or absent custom colour falls back to the default seed
    /// rather than to black — the stored string outlives the code that wrote
    /// it, and a user who has picked `.custom` should not get a black window
    /// because one preference went missing.
    var dashboardPalette: DashboardPalette {
        guard dashboardPaletteID == .custom else {
            return dashboardPaletteID.preset ?? .indigo
        }
        return .derived(from: dashboardCustomSeed ?? DashboardPalette.defaultCustomSeed)
    }

    /// The stored custom colour, if there is a readable one.
    var dashboardCustomSeed: PaletteRGB? {
        dashboardCustomColorHex.flatMap(PaletteRGB.init(hexString:))
    }
}
