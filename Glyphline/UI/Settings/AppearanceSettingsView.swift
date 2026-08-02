import AppKit
import SwiftUI

/// The appearance tab: which surface the dashboard is drawn on.
///
/// A grid of swatches rather than a menu of colour names, because the choice is
/// made by eye — a list reading "Aubergine, Slate, Espresso" asks the user to
/// imagine ten dark surfaces they have never seen. Each swatch is the actual
/// `DashboardBackground` at thumbnail size, so what is on offer is what will be
/// drawn, not an approximation of it.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    /// Wide enough for a swatch plus its name at the settings window's width.
    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 14)]

    var body: some View {
        Form {
            Section("Dashboard Background") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(DashboardPaletteID.presets) { identifier in
                        swatch(
                            for: identifier,
                            palette: identifier.preset ?? .indigo
                        )
                    }
                }
                .padding(.vertical, 4)

                Text("The dashboard's cards are glass: they take their colour from whatever is behind them, so this sets the whole window.")
                    .foregroundStyle(.secondary)
            }

            Section("Custom Colour") {
                LabeledContent {
                    // The system colour panel, which is the full picker — every
                    // colour the display can show, not a shortlist.
                    ColorPicker(
                        "Pick a colour",
                        selection: customColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                } label: {
                    Text("Pick a colour")
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    swatch(for: .custom, palette: customPalette)
                }
                .padding(.vertical, 4)

                Text("Glyphline builds the surface around the colour you pick: the hue is yours, the brightness is not. A dashboard has light text on it, so the background stays dark whatever you choose.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }

    /// One choice: the surface itself at thumbnail size, its name under it, and
    /// a ring when it is the one in use.
    private func swatch(for identifier: DashboardPaletteID, palette: DashboardPalette) -> some View {
        let isSelected = settings.dashboardPaletteID == identifier

        return Button {
            settings.dashboardPaletteID = identifier
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                DashboardBackground(palette: palette)
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }

                Text(identifier.displayName)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            // Without this the swatch is not clickable where anyone would click
            // it. `DashboardBackground` ends in `allowsHitTesting(false)`,
            // which is right for the window surface it was written for — it
            // must not swallow clicks meant for the dashboard — but here the
            // same view *is* the control, and it refused every hit on the
            // thumbnail. Only the name underneath responded. Declaring the
            // shape gives the button one hit region covering both.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The swatch is the whole control, so the name it announces is the
        // palette's — a button whose label is a picture announces nothing.
        .accessibilityLabel(Text(identifier.displayName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(identifier.displayName)
    }

    /// What the custom swatch shows: the palette derived from the stored colour,
    /// or from the default seed if nothing has been picked yet.
    private var customPalette: DashboardPalette {
        .derived(from: settings.dashboardCustomSeed ?? DashboardPalette.defaultCustomSeed)
    }

    /// Picking a colour also selects the custom palette. Choosing a colour and
    /// then having to click a second control to apply it is a trap: the
    /// dashboard would not change and nothing on screen would say why.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { (settings.dashboardCustomSeed ?? DashboardPalette.defaultCustomSeed).color },
            set: { color in
                guard let seed = PaletteRGB(color) else { return }
                settings.dashboardCustomColorHex = seed.hexString
                settings.dashboardPaletteID = .custom
            }
        )
    }
}

extension PaletteRGB {
    /// A picked `Color` as three sRGB channels.
    ///
    /// The conversion is explicit about the colour space. The panel can hand
    /// back a colour in a wide-gamut or device space, and reading its
    /// components without converting first stores numbers that mean something
    /// different from what was picked.
    ///
    /// Nil if the colour cannot be expressed in sRGB at all — a pattern or a
    /// catalog colour — which leaves the stored one alone rather than writing a
    /// black.
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}
