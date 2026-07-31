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

    /// 0 at the start/finish line, approaching 1 at the end of the lap.
    static func lapFraction(workTokens: Int64, tokensPerLap: Int64 = tokensPerLap) -> Double {
        guard tokensPerLap > 0 else { return 0 }
        let remainder = max(0, workTokens) % tokensPerLap
        return Double(remainder) / Double(tokensPerLap)
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
}
