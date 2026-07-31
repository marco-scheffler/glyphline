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

            // Tied to the road it drives on rather than to a nominal length in
            // metres: measured against the track surface stroke, a car that
            // came out shorter than the road is wide could not read as a car at
            // all. 1.6 road widths is deliberately over-scaled — to scale a GT3
            // would be a third of the road's width long, which is a speck — and
            // the floor keeps it legible on a small window.
            let carLength = max(14, fit.width(metres: 13, atLeast: 6) * 1.6)

            func drawCar(at point: CGPoint, heading: Double, livery: CarLivery,
                         hazardsOn: Bool, opacity: Double) {
                let placement = CGAffineTransform(translationX: point.x, y: point.y)
                    .rotated(by: heading)
                    .scaledBy(x: carLength, y: carLength)

                context.fill(CarShape.body.applying(placement),
                             with: .color(livery.body.opacity(opacity)))
                context.fill(CarShape.stripe.applying(placement),
                             with: .color(livery.accent.opacity(opacity)))
                context.fill(CarShape.wing.applying(placement),
                             with: .color(livery.accent.opacity(opacity)))
                if hazardsOn {
                    context.fill(CarShape.hazards.applying(placement),
                                 with: .color(Color.orange.opacity(opacity)))
                }
            }

            // A function rather than a mutation of `context.opacity`: a
            // reset missed on one path would silently fade everything
            // drawn after it.
            //
            // Dimmed rather than nearly gone: the ask was "slightly greyed", and
            // 0.18 read as switched off.
            func spotlight(_ id: String) -> Double {
                guard let hovered else { return 1 }
                return hovered == id ? 1 : 0.35
            }

            // The pit lane first, so a car rejoining never appears to sit
            // on top of the field it is behind.
            for (index, session) in parked.enumerated() {
                let slot = CarPosition.pitSlot(index: index, count: parked.count)
                guard let along = CarPosition.pitPointIndex(slot: slot,
                                                            count: circuit.pit.count)
                else { continue }
                // The lane is not a loop: its first point has no predecessor.
                let heading = CarPosition.heading(points: circuit.pit, index: along,
                                                  closed: false, fit: fit) ?? 0
                let livery = CarLivery.forSession(session.sessionID)
                drawCar(at: fit.point(circuit.pit[along]), heading: heading,
                        livery: livery, hazardsOn: false,
                        opacity: 0.55 * spotlight(session.sessionID))
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
                guard circuit.points.indices.contains(index) else { continue }
                let heading = CarPosition.heading(points: circuit.points, index: index,
                                                  closed: true, fit: fit) ?? 0
                let livery = CarLivery.forSession(session.id)
                let waiting = session.activity == .waitingForYou

                drawCar(at: fit.point(circuit.points[index]), heading: heading,
                        livery: livery, hazardsOn: waiting && blinkOn,
                        opacity: spotlight(session.id))
            }
        }
        .background(Color(white: 0.07))
    }
}
