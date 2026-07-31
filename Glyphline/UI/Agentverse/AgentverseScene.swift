import SwiftUI

/// The drawing, separated from where its inputs come from.
///
/// `frame` replaces the clock: the window passes the running frame number, a test
/// passes a fixed one. Without that the picture depends on when it was taken and
/// no two renders could be compared.
struct AgentverseScene: View {
    let circuit: Circuit
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int

    var body: some View {
        Canvas { context, size in
            let fit = CircuitFit(circuit: circuit, in: size)
            // Verge first, then surface: one stroke over another is cheaper
            // than building two outlines, and the difference is invisible.
            context.stroke(
                CircuitTrackShape.centreline(for: circuit, fit: fit),
                with: .color(.white.opacity(0.18)),
                style: StrokeStyle(lineWidth: fit.width(metres: 19, atLeast: 9),
                                   lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                CircuitTrackShape.centreline(for: circuit, fit: fit),
                with: .color(Color(white: 0.20)),
                style: StrokeStyle(lineWidth: fit.width(metres: 13, atLeast: 6),
                                   lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                CircuitTrackShape.pitLane(for: circuit, fit: fit),
                with: .color(Color(white: 0.16)),
                style: StrokeStyle(lineWidth: fit.width(metres: 12, atLeast: 5),
                                   lineCap: .round, lineJoin: .round)
            )

            context.stroke(
                CircuitTrackShape.startFinish(for: circuit, fit: fit),
                with: .color(Color(white: 0.85)),
                lineWidth: 2
            )

            let radius = max(3.5, fit.width(metres: 5, atLeast: 7) / 2)

            func drawCar(at point: CGPoint, livery: CarLivery,
                         ring: Color, ringWidth: CGFloat, opacity: Double) {
                let box = CGRect(x: point.x - radius, y: point.y - radius,
                                 width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: box),
                             with: .color(livery.body.opacity(opacity)))
                context.stroke(Path(ellipseIn: box),
                               with: .color(ring.opacity(opacity)),
                               lineWidth: ringWidth)
            }

            // A function rather than a mutation of `context.opacity`: a
            // reset missed on one path would silently fade everything
            // drawn after it.
            func spotlight(_ id: String) -> Double {
                guard let hovered else { return 1 }
                return hovered == id ? 1 : 0.18
            }

            // The pit lane first, so a car rejoining never appears to sit
            // on top of the field it is behind.
            for (index, session) in parked.enumerated() {
                let slot = CarPosition.pitSlot(index: index, count: parked.count)
                guard let along = CarPosition.pitPointIndex(slot: slot,
                                                            count: circuit.pit.count)
                else { continue }
                let livery = CarLivery.forSession(session.sessionID)
                drawCar(at: fit.point(circuit.pit[along]), livery: livery,
                        ring: livery.accent, ringWidth: 1.5,
                        opacity: 0.45 * spotlight(session.sessionID))
            }

            // Half a second on, half a second off at the window's 60 frames a
            // second — the rate the clock-derived blink had.
            let blinkOn = frame / 30 % 2 == 0
            for session in sessions {
                let tokens = workTokens[session.id] ?? 0
                let fraction = CarPosition.lapFraction(workTokens: tokens)
                let index = CarPosition.pointIndex(fraction: fraction,
                                                   startIdx: circuit.startIdx,
                                                   count: circuit.points.count)
                let livery = CarLivery.forSession(session.id)
                let waiting = session.activity == .waitingForYou

                drawCar(at: fit.point(circuit.points[index]), livery: livery,
                        ring: waiting && blinkOn ? .orange : livery.accent,
                        ringWidth: waiting ? 3 : 1.5,
                        opacity: spotlight(session.id))
            }
        }
        .background(Color(white: 0.07))
    }
}
