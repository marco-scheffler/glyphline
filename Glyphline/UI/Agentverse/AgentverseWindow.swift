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
            }
            .background(Color(white: 0.07))
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
