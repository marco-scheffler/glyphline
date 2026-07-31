import SwiftUI

/// The circuit's centreline and pit lane as drawable paths.
///
/// Rebuilt on every frame as things stand: the canvas sits under a
/// `TimelineView(.animation)` and calls these four times a frame, roughly 160
/// points each, sixty times a second. The geometry does not move, so that work
/// is redundant — an accepted cost for now, and a later stage's job to cache. Do
/// not read this as caching that already exists.
enum CircuitTrackShape {
    static func centreline(for circuit: Circuit, fit: CircuitFit) -> Path {
        path(through: circuit.points, fit: fit, closed: true)
    }

    static func pitLane(for circuit: Circuit, fit: CircuitFit) -> Path {
        path(through: circuit.pit, fit: fit, closed: false)
    }

    /// A line across the track at the circuit's measured start/finish.
    ///
    /// Laid perpendicular to the direction of travel there, taken from the two
    /// points either side of `startIdx` so it stays square to the track through
    /// a corner. Without it drawn, nothing on screen says where a lap begins and
    /// the cars' positions cannot be checked by eye.
    static func startFinish(for circuit: Circuit, fit: CircuitFit) -> Path {
        var path = Path()
        let count = circuit.points.count
        guard count > 1, circuit.points.indices.contains(circuit.startIdx) else { return path }

        let centre = fit.point(circuit.points[circuit.startIdx])
        let before = fit.point(circuit.points[(circuit.startIdx - 1 + count) % count])
        let after = fit.point(circuit.points[(circuit.startIdx + 1) % count])

        let tangent = CGPoint(x: after.x - before.x, y: after.y - before.y)
        let length = sqrt(tangent.x * tangent.x + tangent.y * tangent.y)
        // Two coincident neighbours leave no direction to be square to.
        guard length > 0 else { return path }
        let normal = CGPoint(x: -tangent.y / length, y: tangent.x / length)

        let half = fit.width(metres: 13, atLeast: 6) / 2
        path.move(to: CGPoint(x: centre.x - normal.x * half, y: centre.y - normal.y * half))
        path.addLine(to: CGPoint(x: centre.x + normal.x * half, y: centre.y + normal.y * half))
        return path
    }

    /// The rubbered-in line the cars actually drive on.
    ///
    /// The centreline's geometry — what makes it read as the racing line is the
    /// caller's narrower, darker band inset inside the road surface. It is its
    /// own entry point rather than a second call to `centreline` so the rubber
    /// and the road it is laid on cannot drift apart, and so a caller cannot
    /// reach for the verge geometry by mistake.
    static func racingLine(for circuit: Circuit, fit: CircuitFit) -> Path {
        path(through: circuit.points, fit: fit, closed: true)
    }

    // MARK: - Kerbs

    /// How sharply the centreline has to turn at a point before that point counts
    /// as a corner, in degrees between the segment arriving and the one leaving.
    ///
    /// The five circuits carry 99 to 171 points over 3.3 to 7.0 km, so
    /// consecutive points stand 20 to 70 m apart and a corner shows up as a
    /// handful of them rather than as one. Ten degrees is what separates Spa's
    /// Eau Rouge — 11.9° and 13.1° at its two steepest points — from Monza's
    /// main straight, whose worst point turns 2.2°. It yields 26 kerb runs at
    /// Monaco, 21 at Spa, 23 at Suzuka, 14 at Monza and 12 at Las Vegas, against
    /// 19, 19, 18, 11 and 17 numbered turns. Raising it to 15 loses Eau Rouge
    /// altogether; dropping it to 8 starts kerbing the Kemmel straight.
    static let kerbTurnThreshold = 10.0

    /// Alternating red and white blocks along the outside edge of every corner.
    ///
    /// - Returns: One entry per block in draw order, with `true` for the red
    ///   blocks and `false` for the white ones. Empty for a circuit that never
    ///   turns hard enough to have a corner.
    static func kerbs(for circuit: Circuit, fit: CircuitFit) -> [(Path, Bool)] {
        let points = circuit.points
        let count = points.count
        guard count > 2 else { return [] }

        let turns = (0..<count).map { turn(points: points, index: $0, fit: fit) }
        // Clear of the road surface, not on it: half the surface stroke plus
        // half the kerb's own width puts the band's centre against the edge.
        let offset = fit.width(metres: 13, atLeast: 6) / 2
            + fit.width(metres: 2.5, atLeast: 2) / 2
        let blockLength = fit.width(metres: 6, atLeast: 4)

        var result: [(Path, Bool)] = []
        // Carried across runs rather than restarted at each: a run short enough
        // to hold a single block would otherwise always be the same colour, and
        // every kerb on the circuit would come out red.
        var red = true
        for run in cornerRuns(turns: turns) {
            // A corner turns one way; summing over the run settles which, so a
            // single noisy point cannot flip a kerb to the inside of its own
            // corner. Positive turns toward the normal, so the outside — where
            // the kerb belongs — is the other way.
            let side: CGFloat = run.reduce(0.0) { $0 + turns[$1] } > 0 ? -1 : 1
            let edge = edge(of: run, points: points, fit: fit, offset: offset * side)
            result.append(contentsOf: blocks(along: edge, length: blockLength, red: &red))
        }
        return result
    }

    /// The kerb's own polyline, one point per centreline point, pushed sideways
    /// off the road.
    ///
    /// Run by one point at each end: a corner's kerb starts before its apex and
    /// ends after it, and a run of a single point would otherwise be a polyline
    /// with no length at all and no kerb would be drawn there.
    private static func edge(of run: [Int], points: [[Double]],
                             fit: CircuitFit, offset: CGFloat) -> [CGPoint] {
        let count = points.count
        guard let first = run.first, let last = run.last else { return [] }
        let indices = [(first - 1 + count) % count] + run + [(last + 1) % count]

        return indices.compactMap { index in
            guard let heading = CarPosition.heading(points: points, index: index,
                                                    closed: true, fit: fit)
            else { return nil }
            let normal = CGPoint(x: -sin(heading), y: cos(heading))
            let centre = fit.point(points[index])
            return CGPoint(x: centre.x + normal.x * offset,
                           y: centre.y + normal.y * offset)
        }
    }

    /// The stretches of centreline that turn hard enough to be a corner, each as
    /// its run of consecutive point indices.
    private static func cornerRuns(turns: [Double]) -> [[Int]] {
        let count = turns.count
        let corner = turns.map { abs($0) >= kerbTurnThreshold }
        guard corner.contains(true) else { return [] }
        // A circuit that turns at every point is one run, closed on itself.
        guard let start = corner.firstIndex(of: false) else { return [Array(0..<count)] }

        var result: [[Int]] = []
        var current: [Int] = []
        // Walked from a point that is not in a corner, so a run straddling
        // `points[0]` comes out as one kerb rather than as two.
        for step in 0..<count {
            let index = (start + step) % count
            if corner[index] {
                current.append(index)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Cuts a polyline into blocks of a fixed length, alternating the flag.
    private static func blocks(along edge: [CGPoint], length: CGFloat,
                               red: inout Bool) -> [(Path, Bool)] {
        guard edge.count > 1, length > 0 else { return [] }

        var result: [(Path, Bool)] = []
        var path = Path()
        path.move(to: edge[0])
        var used: CGFloat = 0
        var cursor = edge[0]

        for next in edge.dropFirst() {
            var from = cursor
            var remaining = hypot(next.x - from.x, next.y - from.y)
            // A centreline segment is longer than one block, so a segment is
            // split as many times as it takes rather than once.
            while remaining > 0 {
                let step = min(remaining, length - used)
                let ratio = step / remaining
                let to = CGPoint(x: from.x + (next.x - from.x) * ratio,
                                 y: from.y + (next.y - from.y) * ratio)
                path.addLine(to: to)
                used += step
                remaining -= step
                from = to
                guard used >= length else { continue }
                result.append((path, red))
                red.toggle()
                path = Path()
                path.move(to: to)
                used = 0
            }
            cursor = next
        }
        // The tail of the last block: a kerb that stopped at the last whole
        // block would end short of its own corner.
        if used > 0 {
            result.append((path, red))
            red.toggle()
        }
        return result
    }

    /// The signed angle the centreline turns through at `index`, in degrees.
    ///
    /// Measured after the fit, like every other angle in the scene, so the sign
    /// agrees with the normal `CarPosition.heading` implies. `CircuitFit` scales
    /// both axes alike, so the number is the same one the metres would give.
    private static func turn(points: [[Double]], index: Int, fit: CircuitFit) -> Double {
        let count = points.count
        guard count > 2, points.indices.contains(index) else { return 0 }

        let before = fit.point(points[(index - 1 + count) % count])
        let here = fit.point(points[index])
        let after = fit.point(points[(index + 1) % count])

        let incoming = CGPoint(x: here.x - before.x, y: here.y - before.y)
        let outgoing = CGPoint(x: after.x - here.x, y: after.y - here.y)
        let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
        let dot = incoming.x * outgoing.x + incoming.y * outgoing.y
        // Coincident points leave no direction to measure a turn between.
        guard cross != 0 || dot != 0 else { return 0 }
        return atan2(cross, dot) * 180 / .pi
    }

    private static func path(through metres: [[Double]], fit: CircuitFit, closed: Bool) -> Path {
        var path = Path()
        guard let first = metres.first else { return path }
        path.move(to: fit.point(first))
        for metre in metres.dropFirst() {
            path.addLine(to: fit.point(metre))
        }
        if closed { path.closeSubpath() }
        return path
    }
}
