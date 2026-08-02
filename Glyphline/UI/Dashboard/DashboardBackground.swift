import SwiftUI

/// What the dashboard's Liquid Glass refracts.
///
/// `glassCard()` does not invent a colour: it samples what is behind it. With
/// the default system window background behind the cards that is neutral grey,
/// so the whole surface read as grey no matter how good the glass was. This
/// view is the thing the glass was always meant to have underneath — a very
/// dark base with three washes over it.
///
/// Which base and which washes is the user's choice now: ten presets plus a
/// colour they mix themselves, all of them `DashboardPalette`. The view holds
/// no colours of its own, so a palette can be swapped at runtime and nothing
/// here has to know that happened.
///
/// The washes are deliberately weak. They are atmosphere: the surface should
/// read as "dark and slightly tinted", and no single wash should be pointable
/// at as a coloured blob. Peak opacity is at the centre of each wash and falls
/// to nothing at its edge, so the numbers in the palette are upper bounds that
/// almost no pixel actually reaches.
struct DashboardBackground: View {
    /// Defaulted, so a preview or a test that just wants "the surface" gets the
    /// one this app shipped with.
    var palette: DashboardPalette = .indigo

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let extent = max(size.width, size.height)

            ZStack {
                palette.baseColor

                ForEach(0..<palette.washes.count, id: \.self) { index in
                    let wash = palette.washes[index]

                    // `.clear` as the outer stop, not a darker colour: a wash
                    // has to disappear into whatever it lies on, otherwise its
                    // edge becomes the visible ring the design must not have.
                    RadialGradient(
                        gradient: Gradient(colors: [
                            wash.color.color.opacity(wash.opacity),
                            wash.color.color.opacity(0),
                        ]),
                        center: wash.center,
                        startRadius: 0,
                        endRadius: extent * wash.radius
                    )
                }
            }
            .frame(width: size.width, height: size.height)
        }
        // Drawing only. The dashboard's own controls sit above this.
        .allowsHitTesting(false)
    }
}

extension View {
    /// Puts `DashboardBackground` behind the whole dashboard window.
    ///
    /// `containerBackground(for: .window)` rather than a plain `.background`:
    /// the latter stops at the content view, leaving the title bar area drawn
    /// in the system's neutral chrome — a grey band above a tinted surface. The
    /// container placement reaches under the title bar, so the window reads as
    /// one surface.
    ///
    /// The palette also goes into the environment here rather than only into
    /// the background view, because the cards on top of it are tinted with the
    /// same surface — one call, so the two cannot end up on different palettes.
    func dashboardWindowBackground(palette: DashboardPalette) -> some View {
        environment(\.dashboardPalette, palette)
            .containerBackground(for: .window) {
                DashboardBackground(palette: palette)
            }
    }
}
