import Foundation

/// Where a car sits on its lap, and how many it has completed.
///
/// Both come from one number, so the odometer and the place on the circuit can
/// never tell different stories.
enum CarPosition {
    /// Measured rather than chosen. Across 309 sessions on the reference machine
    /// the median held 2.46 M work tokens and the largest 413 M; among the nine
    /// that were on screen at the time, a million per lap spread them from zero
    /// to eighty-two. A quarter of that would have printed three-digit counts,
    /// which nobody compares at a glance.
    static let tokensPerLap: Int64 = 1_000_000

    static func lapCount(workTokens: Int64, tokensPerLap: Int64 = tokensPerLap) -> Int64 {
        guard tokensPerLap > 0 else { return 0 }
        return max(0, workTokens) / tokensPerLap
    }

    /// 0 at the start/finish line, approaching 1 at the end of the lap. Which
    /// stored point that is depends on the circuit — see `pointIndex`.
    static func lapFraction(workTokens: Int64, tokensPerLap: Int64 = tokensPerLap) -> Double {
        guard tokensPerLap > 0 else { return 0 }
        let remainder = max(0, workTokens) % tokensPerLap
        return Double(remainder) / Double(tokensPerLap)
    }

    /// Which centreline point a car at `fraction` of a lap stands on.
    ///
    /// The geometry does not start at the line: `startIdx` is 118 of 159 on
    /// Monaco and 167 of 171 at Suzuka. Counting from `points[0]` would put a
    /// car with no completed lap most of a lap from where its odometer says it
    /// is, and would wrap the lap at an arbitrary corner instead of at the line.
    static func pointIndex(fraction: Double, startIdx: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let step = min(count - 1, max(0, Int(fraction * Double(count))))
        return (startIdx + step) % count
    }

    /// Where the nth of `count` parked cars stands along the pit lane, as a
    /// fraction of its length.
    ///
    /// Half-step inset at both ends: a car exactly on the entry would read as
    /// joining the lane rather than standing in it, and one on the exit as
    /// leaving.
    static func pitSlot(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0.5 }
        return (Double(index) + 0.5) / Double(count)
    }

    /// Which pit-lane point a car at `slot` of the lane's length stands on.
    ///
    /// The centreline's counterpart, and tested for the same reason. Optional
    /// rather than clamped: a circuit with no stored pit lane has no point to
    /// offer, and returning 0 there would hand the caller an index into an empty
    /// array. The lane does not wrap — it has an entry and an exit — so the last
    /// point is as far as a slot can reach.
    static func pitPointIndex(slot: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, Int(slot * Double(count))))
    }

    /// Which way a car at `index` is travelling, as a screen-space angle.
    ///
    /// Measured after the fit rather than on the raw metres, so the car turns
    /// with whatever `CircuitFit` does to the geometry. `closed` is the
    /// difference between the centreline, whose first point follows its last,
    /// and the pit lane, which has an entry and an exit.
    ///
    /// The same before-and-after construction `CircuitTrackShape.startFinish`
    /// uses for its perpendicular. It lives here rather than in the canvas
    /// because the centreline index lived in the canvas once, was wrong, and
    /// had to be extracted to be pinned.
    static func heading(points: [[Double]], index: Int,
                        closed: Bool, fit: CircuitFit) -> Double? {
        let count = points.count
        guard count > 1, points.indices.contains(index) else { return nil }

        let beforeIdx = closed ? (index - 1 + count) % count : max(0, index - 1)
        let afterIdx = closed ? (index + 1) % count : min(count - 1, index + 1)
        let before = fit.point(points[beforeIdx])
        let after = fit.point(points[afterIdx])

        let dx = after.x - before.x
        let dy = after.y - before.y
        // Two coincident neighbours leave no direction to point in.
        guard dx != 0 || dy != 0 else { return nil }
        return atan2(dy, dx)
    }
}
