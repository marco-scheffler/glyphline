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
    }

    @ViewBuilder private var scene: some View {
        if let message = coordinator.failureMessage {
            ContentUnavailableView("No map", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else if coordinator.onTrack.isEmpty && coordinator.parked.isEmpty {
            ContentUnavailableView("No agent is running", systemImage: "flag.checkered",
                                   description: Text("Sessions appear here while they are working."))
        } else {
            Color.clear
        }
    }

    private func refresh() async {
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
