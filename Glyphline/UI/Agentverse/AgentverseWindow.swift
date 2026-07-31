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
    /// One id for both sections: hovering a parked row must fade the field on
    /// track exactly as hovering an on-track row fades the pit lane.
    @State private var hoveredSessionID: String?

    var body: some View {
        HSplitView {
            AgentverseSidebar(hovered: $hoveredSessionID)
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
            // Read out here rather than inside the canvas: the drawing closure is
            // nonisolated, and reaching into the view's state from it would be an
            // actor-isolation violation.
            let hovered = hoveredSessionID
            TimelineView(.animation) { timeline in
                AgentverseScene(
                    circuit: circuit,
                    sessions: coordinator.onTrack,
                    parked: coordinator.parked,
                    workTokens: coordinator.workTokens,
                    hovered: hovered,
                    // The clock enters here and nowhere below: the scene itself is
                    // a pure function of its inputs, so a test can pin the frame.
                    frame: Int(timeline.date.timeIntervalSinceReferenceDate * 60)
                )
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
            if !circuit.pit.isEmpty {
                for (index, session) in parked.enumerated() {
                    let slot = CarPosition.pitSlot(index: index, count: parked.count)
                    let along = min(circuit.pit.count - 1,
                                    Int(slot * Double(circuit.pit.count)))
                    let livery = CarLivery.forSession(session.sessionID)
                    drawCar(at: fit.point(circuit.pit[along]), livery: livery,
                            ring: livery.accent, ringWidth: 1.5,
                            opacity: 0.45 * spotlight(session.sessionID))
                }
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

/// The list beside the scene: which agent each car on the circuit is, and which
/// of them is waiting for an answer.
struct AgentverseSidebar: View {
    @EnvironmentObject private var coordinator: AgentverseCoordinator
    @Binding var hovered: String?

    var body: some View {
        List {
            Section("On track") {
                ForEach(coordinator.onTrack) { session in
                    AgentRow(model: AgentRowModel(session: session,
                                                  workTokens: coordinator.workTokens[session.id] ?? 0),
                             livery: CarLivery.forSession(session.id))
                        .onHover { inside in
                            hovered = inside ? session.id : (hovered == session.id ? nil : hovered)
                        }
                }
            }
            Section("Pit lane") {
                ForEach(coordinator.parked) { session in
                    HStack(spacing: 6) {
                        AgentRow(model: AgentRowModel(parked: session,
                                                      workTokens: coordinator.workTokens[session.sessionID] ?? 0),
                                 livery: CarLivery.forSession(session.sessionID))
                        // Only while pointed at, so a column of crosses does not
                        // compete with the rows themselves.
                        if hovered == session.id {
                            Button {
                                coordinator.dismiss(sessionID: session.sessionID)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Remove this session from the Agentverse")
                        }
                    }
                    .onHover { inside in
                        hovered = inside ? session.id : (hovered == session.id ? nil : hovered)
                    }
                }
            }
        }
    }
}
