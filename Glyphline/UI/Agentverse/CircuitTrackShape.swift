import SwiftUI

/// The circuit's centreline and pit lane as drawable paths.
///
/// Built once per circuit and canvas size rather than per frame: the geometry
/// does not move, only the cars on it do.
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
