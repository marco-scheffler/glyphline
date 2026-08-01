import SwiftUI

/// When the map sweeps again on its own.
///
/// A sweep is not free — a 374 ms directory walk over roughly three thousand
/// transcripts — so the map only sweeps while someone is actually looking at it.
/// Both halves of that live here so a test can pin them.
enum AgentverseRefreshSchedule {
    /// Fifteen seconds between sweeps.
    ///
    /// The floor: a session working hard writes on the order of 50 000 tokens a
    /// minute, and a lap is a million, so a car moves about 1.25 % of a lap in
    /// fifteen seconds — visible, where a five-second tick would redraw the same
    /// position. The ceiling: half a minute of a car standing still on a screen
    /// the user is watching reads as the old bug. In between, 374 ms of work
    /// every 15 s is a 2.5 % duty cycle on one background thread.
    static let interval: TimeInterval = 15

    /// Sweeping is for a window that is on screen — not for a window in the
    /// frontmost app.
    ///
    /// This used to be `scenePhase == .active`, which is a claim about keyboard
    /// focus: on macOS a fully visible window whose app is not frontmost reports
    /// `.inactive`, so the map froze the moment the user clicked into their
    /// editor. Leaving it open beside the work is what it is for, so the gate is
    /// the window's occlusion instead — see `WindowVisibility`.
    static func shouldRun(onScreen isOnScreen: Bool) -> Bool { isOnScreen }
}

/// The map's window.
///
/// The window sweeps on a repeating interval, but only while it is on screen:
/// the loop lives in a `.task` keyed on the window's occlusion, so minimising,
/// hiding or fully covering the window cancels it and the machine goes quiet
/// again — while a visible window in a background app keeps running, which is
/// how the map is meant to be used. Closing the window ends the `.task` outright.
struct AgentverseWindow: View {
    @EnvironmentObject private var coordinator: AgentverseCoordinator
    /// Starts false and is corrected by the probe as soon as the view has a
    /// window: a true default would run one sweep for a window that turns out to
    /// be opening behind something else.
    @State private var isOnScreen = false
    @State private var isRefreshing = false
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
            // The one control left in the toolbar. It is a window-level action
            // rather than a setting for the scene, so it reads as a toolbar
            // button — and alone it cannot collide with anything.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isRefreshing)
            }
        }
        // Zero-sized and behind everything: it draws nothing, it is only how the
        // view reaches the `NSWindow` it lives in.
        .background(WindowOcclusionReader(isOnScreen: $isOnScreen))
        // Keyed on the occlusion so that going off screen cancels the loop
        // outright rather than letting it tick on behind a covered window;
        // coming back starts a fresh one, whose first pass is the opening sweep.
        .task(id: isOnScreen) {
            guard AgentverseRefreshSchedule.shouldRun(onScreen: isOnScreen) else { return }
            while !Task.isCancelled {
                await refresh()
                // Nothing is interpolated between two sweeps: a car's place is a
                // claim about tokens read from the ledger, and gliding it along
                // between readings would make that claim up.
                try? await Task.sleep(
                    nanoseconds: UInt64(AgentverseRefreshSchedule.interval * Double(NSEC_PER_SEC))
                )
            }
        }
    }

    @ViewBuilder private var scene: some View {
        if let message = coordinator.failureMessage {
            ContentUnavailableView("No map", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else {
            stage
        }
    }

    @ViewBuilder private var stage: some View {
        // Read out here rather than inside the timeline's closure: the closure
        // is rebuilt per frame, and pulling the view's state into it each time
        // would tie the picture to when it was drawn.
        let hovered = hoveredSessionID
        TimelineView(.animation) { timeline in
            AgentverseScene(
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

/// The list beside the scene: which agents are running, and which of them is
/// waiting for an answer.
struct AgentverseSidebar: View {
    @EnvironmentObject private var coordinator: AgentverseCoordinator
    @Binding var hovered: String?

    var body: some View {
        List {
            Section("On track") {
                ForEach(coordinator.onTrack) { session in
                    AgentRow(model: AgentRowModel(session: session,
                                                  workTokens: coordinator.workTokens[session.id] ?? 0))
                        // A `List` row is wider and taller than the content it
                        // was given, and `onHover` alone only fires over the
                        // content itself. In a 264 pt sidebar most of the row is
                        // that surrounding dead space, so the spotlight almost
                        // never lit and the feature read as broken.
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hovered = inside ? session.id : (hovered == session.id ? nil : hovered)
                        }
                }
            }
            Section("Pit lane") {
                ForEach(coordinator.parked) { session in
                    HStack(spacing: 6) {
                        AgentRow(model: AgentRowModel(parked: session,
                                                      workTokens: coordinator.workTokens[session.sessionID] ?? 0))
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
                    // The same dead space as on track. The dismiss button keeps
                    // its own hit test: a container's content shape decides
                    // where the container itself is hit, not its children.
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovered = inside ? session.id : (hovered == session.id ? nil : hovered)
                    }
                }
            }
        }
    }
}
