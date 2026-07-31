import CoreGraphics

/// What the track is made of, as a table rather than as drawing code.
///
/// Two renderers lay down the same six strokes: `AgentverseScene` in SwiftUI
/// while the static picture is still being built, `StaticSceneImage` in Core
/// Graphics once it is. They target different graphics APIs and stay separate
/// for that reason — but they may not hold separate ideas of what the track
/// looks like. Before this table they did, and the two copies had already
/// drifted a count per channel apart in both kerb colours.
struct TrackStroke {
    /// Which of `CircuitTrackShape`'s paths the stroke is laid along. The table
    /// says what to draw and in which order; resolving the path is the
    /// renderer's job, because that is where the two APIs actually differ.
    enum Path {
        /// The verge and the road surface are the same line at two widths.
        case centreline
        case racingLine
        case kerbs
        case pitLane
        case startFinish
    }

    /// In the terms `CircuitFit.width(metres:atLeast:)` takes, except for the
    /// start/finish line, which is a marking rather than a piece of road and so
    /// has no width in metres to scale.
    enum Width {
        case metres(CGFloat, atLeast: CGFloat)
        case points(CGFloat)
    }

    /// sRGB 0…255, which is what both renderers' colour helpers want.
    enum Paint {
        case flat(SIMD3<Double>)
        /// The kerbs alternate along the block sequence.
        case alternating(red: SIMD3<Double>, pale: SIMD3<Double>)
    }

    let path: Path
    let width: Width
    let paint: Paint
    let alpha: Double

    /// In draw order: verge, surface, rubber, kerbs, pit lane, line. The rubber
    /// sits on the road, so it goes on after the surface and before anything
    /// that crosses it.
    static let all: [TrackStroke] = [
        TrackStroke(path: .centreline, width: .metres(19, atLeast: 9),
                    paint: .flat(grey(1)), alpha: 0.18),
        TrackStroke(path: .centreline, width: .metres(13, atLeast: 6),
                    paint: .flat(grey(0.20)), alpha: 1),
        TrackStroke(path: .racingLine, width: .metres(6, atLeast: 3),
                    paint: .flat(grey(0.13)), alpha: 0.85),
        TrackStroke(path: .kerbs, width: .metres(2.5, atLeast: 2),
                    paint: .alternating(red: SIMD3(196, 48, 44),
                                        pale: SIMD3(226, 226, 226)), alpha: 1),
        TrackStroke(path: .pitLane, width: .metres(12, atLeast: 5),
                    paint: .flat(grey(0.16)), alpha: 1),
        TrackStroke(path: .startFinish, width: .points(2),
                    paint: .flat(grey(0.85)), alpha: 1),
    ]

    /// A neutral grey written the way the drawing code used to write it — as a
    /// whiteness — so the table reads like the strokes it replaced.
    static func grey(_ white: Double) -> SIMD3<Double> {
        SIMD3(white * 255, white * 255, white * 255)
    }

    func points(fit: CircuitFit) -> CGFloat {
        switch width {
        case .metres(let metres, let floor): return fit.width(metres: metres, atLeast: floor)
        case .points(let points): return points
        }
    }
}
