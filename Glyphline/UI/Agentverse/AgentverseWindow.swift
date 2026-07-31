import SwiftUI

/// The map's window.
///
/// Everything happens on opening: one sweep when the view appears, and a toolbar
/// button to run another. No timer, no filesystem watch, nothing in the
/// background — a full sweep costs a 374 ms directory walk over roughly three
/// thousand transcripts, which is cheap once per opening and wasteful on a tick.
struct AgentverseWindow: View {
    @EnvironmentObject private var coordinator: AgentverseCoordinator
    @State private var isRefreshing = false
    @State private var catalog: CircuitCatalog?
    @State private var circuitKey = "monaco"

    var body: some View {
        HSplitView {
            AgentverseSidebar()
                .frame(minWidth: 240, idealWidth: 264, maxWidth: 340)
            scene
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle("Agentverse")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isRefreshing)
            }
        }
        .task { await refresh() }
        .task {
            // Decoded once per window rather than at launch: 683 KB of JSON is
            // not worth paying for on a launch that may never open this window.
            catalog = try? CircuitCatalog.bundled()
        }
    }

    @ViewBuilder private var scene: some View {
        if let message = coordinator.failureMessage {
            ContentUnavailableView("No map", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else if let circuit = catalog?.circuit(circuitKey) {
            TimelineView(.animation) { timeline in
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

                    // The pit lane first, so a car rejoining never appears to sit
                    // on top of the field it is behind.
                    if !circuit.pit.isEmpty {
                        for (index, session) in coordinator.parked.enumerated() {
                            let slot = CarPosition.pitSlot(index: index,
                                                           count: coordinator.parked.count)
                            let along = min(circuit.pit.count - 1,
                                            Int(slot * Double(circuit.pit.count)))
                            let livery = CarLivery.forSession(session.sessionID)
                            drawCar(at: fit.point(circuit.pit[along]), livery: livery,
                                    ring: livery.accent, ringWidth: 1.5, opacity: 0.45)
                        }
                    }

                    let blinkOn = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    for session in coordinator.onTrack {
                        let tokens = coordinator.workTokens[session.id] ?? 0
                        let fraction = CarPosition.lapFraction(workTokens: tokens)
                        let index = min(circuit.points.count - 1,
                                        Int(fraction * Double(circuit.points.count)))
                        let livery = CarLivery.forSession(session.id)
                        let waiting = session.activity == .waitingForYou

                        drawCar(at: fit.point(circuit.points[index]), livery: livery,
                                ring: waiting && blinkOn ? .orange : livery.accent,
                                ringWidth: waiting ? 3 : 1.5, opacity: 1)
                    }
                }
                .background(Color(white: 0.07))
            }
            .overlay {
                // An idle machine is an ordinary Tuesday, not a failure: a pane
                // that replaces the circuit with this notice reads as the
                // circuit having failed to draw.
                if coordinator.onTrack.isEmpty && coordinator.parked.isEmpty {
                    Text("No agent is running")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            }
        } else {
            ContentUnavailableView("No circuits", systemImage: "map",
                                   description: Text("The bundled circuit data could not be read."))
        }
    }

    private func refresh() async {
        // The toolbar button is disabled while a sweep runs, but the opening
        // sweep from `.task` is not, so a fast reopen can start a second one
        // whose completion clears the flag out from under the first.
        guard !isRefreshing else { return }
        isRefreshing = true
        await coordinator.refresh()
        isRefreshing = false
    }
}

/// The list beside the scene. Filled in a later task; present now so the window
/// has its shape.
struct AgentverseSidebar: View {
    @EnvironmentObject private var coordinator: AgentverseCoordinator

    var body: some View {
        List {
            Section("On track") {
                ForEach(coordinator.onTrack) { session in
                    Text(session.cwd)
                }
            }
            Section("Pit lane") {
                ForEach(coordinator.parked) { session in
                    Text(session.cwd)
                }
            }
        }
    }
}
