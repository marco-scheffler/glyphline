import SwiftUI

/// One car's paint.
///
/// Which one a session wears is decided by hashing its id, so the same session
/// always has the same car — across sweeps, across restarts, across the window
/// being closed and reopened. A random choice would leave nothing to recognise.
struct CarLivery: Equatable, Sendable {
    let name: String
    let body: Color
    let accent: Color

    static let all: [CarLivery] = [
        CarLivery(name: "Gulf", body: Color(red: 0.37, green: 0.76, blue: 0.86),
                  accent: Color(red: 0.94, green: 0.51, blue: 0.12)),
        CarLivery(name: "Martini", body: Color(white: 0.95),
                  accent: Color(red: 0.78, green: 0.06, blue: 0.18)),
        CarLivery(name: "Rothmans", body: Color(white: 0.97),
                  accent: Color(red: 0.10, green: 0.25, blue: 0.63)),
        CarLivery(name: "Pink Pig", body: Color(red: 0.91, green: 0.61, blue: 0.72),
                  accent: Color(white: 0.14)),
        CarLivery(name: "Salzburg", body: Color(white: 0.96),
                  accent: Color(red: 0.84, green: 0.12, blue: 0.17)),
        CarLivery(name: "Midnight", body: Color(white: 0.09),
                  accent: Color(red: 0.22, green: 1.00, blue: 0.53)),
        CarLivery(name: "Signal", body: Color(red: 0.95, green: 0.72, blue: 0.02),
                  accent: Color(white: 0.11)),
        CarLivery(name: "Dazzle", body: Color(red: 0.16, green: 0.19, blue: 0.24),
                  accent: Color(white: 0.81)),
        CarLivery(name: "Carbon", body: Color(white: 0.11),
                  accent: Color(red: 0.69, green: 0.55, blue: 0.25)),
    ]

    /// FNV-1a over the id's bytes. Any stable hash would do; Swift's own
    /// `hashValue` would not, because it is seeded per process and the car would
    /// change on every launch.
    static func forSession(_ sessionID: String) -> CarLivery {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sessionID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return all[Int(hash % UInt64(all.count))]
    }
}
