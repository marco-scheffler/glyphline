import SwiftUI

/// One session's colour.
///
/// Which one a session wears is decided by hashing its id, so the same session
/// always has the same colour — across sweeps, across restarts, across the
/// window being closed and reopened. A random choice would leave nothing to
/// recognise.
///
/// This is the old `CarLivery`, kept whole and renamed once the cars were gone:
/// the office scene needs it for shirts, the sidebar for its swatch, and the
/// datastream for its lanes. What changed is the palette itself — the reference
/// sketch's eight shirt colours instead of nine racing liveries.
struct SessionPalette: Equatable, Sendable {
    /// 0–255 components, because the scene shades colours by a lighting factor
    /// rather than by an opacity and needs the raw numbers to do it.
    let r: Double
    let g: Double
    let b: Double

    var color: Color { Color(red: r / 255, green: g / 255, blue: b / 255) }

    /// The same colour in the form the scene shades things with.
    var shirt: SceneRGB { SceneRGB(r, g, b) }

    static let all: [SessionPalette] = [
        SessionPalette(r: 240, g: 84, b: 72),
        SessionPalette(r: 58, g: 150, b: 242),
        SessionPalette(r: 64, g: 214, b: 124),
        SessionPalette(r: 255, g: 190, b: 54),
        SessionPalette(r: 168, g: 96, b: 246),
        SessionPalette(r: 46, g: 214, b: 206),
        SessionPalette(r: 255, g: 110, b: 168),
        SessionPalette(r: 130, g: 148, b: 170)
    ]

    /// FNV-1a over the id's bytes. Any stable hash would do; Swift's own
    /// `hashValue` would not, because it is seeded per process and the colour
    /// would change on every launch.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func forSession(_ sessionID: String) -> SessionPalette {
        all[Int(fnv1a(sessionID) % UInt64(all.count))]
    }
}
