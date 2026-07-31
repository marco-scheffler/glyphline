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
    /// Three states in one value: nil is still loading, and only `.failure` is a
    /// failure. A plain optional made the first frames of every opening show the
    /// pane a corrupt bundle shows.
    @State private var catalogLoad: Result<CircuitCatalog, Error>?
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
            ToolbarItem(placement: .automatic) {
                // Deliberately not persisted: whether the choice should survive
                // a reopening is still open, and storing it would settle it.
                Picker("Circuit", selection: $circuitKey) {
                    ForEach((try? catalogLoad?.get())?.entriesByName ?? [], id: \.key) { entry in
                        Text(entry.name).tag(entry.key)
                    }
                }
                .labelsHidden()
            }
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
            catalogLoad = Result { try CircuitCatalog.bundled() }
        }
    }

    @ViewBuilder private var scene: some View {
        if let message = coordinator.failureMessage {
            ContentUnavailableView("No map", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else {
            switch catalogLoad {
            case nil:
                // Nothing but the backdrop while the JSON is read: a notice that
                // appears and vanishes within a frame or two only flickers.
                Color(white: 0.07)
            case .failure(let error):
                ContentUnavailableView("No circuits", systemImage: "map",
                                       description: Text(error.localizedDescription))
            case .success(let catalog):
                if let circuit = catalog.circuit(circuitKey) {
                    track(circuit)
                } else {
                    ContentUnavailableView(
                        "No circuit", systemImage: "map",
                        description: Text("The bundle holds no circuit called \(circuitKey).")
                    )
                }
            }
        }
    }

    @ViewBuilder private func track(_ circuit: Circuit) -> some View {
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
