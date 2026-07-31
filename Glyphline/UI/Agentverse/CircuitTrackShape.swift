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
