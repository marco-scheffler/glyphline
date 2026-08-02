import SwiftUI

/// What the dashboard's Liquid Glass refracts.
///
/// `glassCard()` does not invent a colour: it samples what is behind it. With
/// the default system window background behind the cards that is neutral grey,
/// so the whole surface read as grey no matter how good the glass was. This
/// view is the thing the glass was always meant to have underneath — a deep
/// blue-black with three washes over it.
///
/// The washes are deliberately weak. They are atmosphere: the surface should
/// read as "dark and slightly blue", and no single wash should be pointable at
/// as a coloured blob. Peak opacity is at the centre of each wash and falls to
/// nothing at its edge, so the numbers below are upper bounds that almost no
/// pixel actually reaches.
struct DashboardBackground: View {
    /// The base the washes sit on: a very dark, desaturated navy.
    ///
    /// Not black. Black would leave the glass sampling something neutral again;
    /// the blue has to be in the base, because the washes are too weak to carry
    /// the tint on their own out at the corners.
    static let baseColor = Color(rgbHex: 0x0a_0e_18)

    /// One radial wash, in unit coordinates so it scales with any window size.
    struct Wash {
        let color: Color
        /// Peak opacity, at the centre.
        let opacity: Double
        /// Centre, as a fraction of the container's width and height. Values
        /// outside 0…1 push a wash's centre off-screen on purpose — only its
        /// falloff reaches the window.
        let center: UnitPoint
        /// Radius as a fraction of the container's larger edge.
        let radius: Double
    }

    /// Three washes, in draw order.
    ///
    /// Indigo upper-left carries the main tint, violet answers it on the right,
    /// and a cool teal at the bottom keeps the lower half from closing into
    /// flat black. Teal rather than a fourth blue: three shades of the same hue
    /// would read as one gradient with banding.
    static let washes: [Wash] = [
        Wash(
            color: Color(rgbHex: 0x4c_6b_ff),
            opacity: 0.13,
            center: UnitPoint(x: 0.26, y: 0.02),
            radius: 0.95
        ),
        Wash(
            color: Color(rgbHex: 0x8a_5c_f6),
            opacity: 0.10,
            center: UnitPoint(x: 0.96, y: 0.30),
            radius: 0.80
        ),
        Wash(
            color: Color(rgbHex: 0x2f_a8_c7),
            opacity: 0.05,
            center: UnitPoint(x: 0.58, y: 1.04),
            radius: 0.70
        ),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let extent = max(size.width, size.height)

            ZStack {
                DashboardBackground.baseColor

                ForEach(0..<DashboardBackground.washes.count, id: \.self) { index in
                    let wash = DashboardBackground.washes[index]

                    // `.clear` as the outer stop, not a darker colour: a wash
                    // has to disappear into whatever it lies on, otherwise its
                    // edge becomes the visible ring the design must not have.
                    RadialGradient(
                        gradient: Gradient(colors: [
                            wash.color.opacity(wash.opacity),
                            wash.color.opacity(0),
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
    /// in the system's neutral chrome — a grey band above a blue surface. The
    /// container placement reaches under the title bar, so the window reads as
    /// one surface.
    func dashboardWindowBackground() -> some View {
        containerBackground(for: .window) {
            DashboardBackground()
        }
    }
}
