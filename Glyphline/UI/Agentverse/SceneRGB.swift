import SwiftUI

/// A colour the way the reference keeps them: 0–255 components that get shaded
/// by a lighting factor rather than by an opacity.
struct SceneRGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color { shaded(1) }

    func shaded(_ f: Double) -> Color {
        Color(red: min(1, max(0, r * f / 255)),
              green: min(1, max(0, g * f / 255)),
              blue: min(1, max(0, b * f / 255)))
    }

    func alpha(_ a: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255).opacity(a)
    }
}
