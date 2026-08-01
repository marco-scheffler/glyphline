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

    /// How often the sun is re-solved. It moves a quarter of a degree a minute,
    /// so a minute is under the resolution of anything the windows can show —
    /// and the solve walks a `Calendar`, which has no business running per frame.
    static let sunInterval: TimeInterval = 60

    /// How often the weather is asked for.
    ///
    /// `WeatherService` throttles to one request an hour, but a *failed* request
    /// deliberately does not advance its stored timestamp, so it will try again
    /// on every call. That is right for an offline machine that comes back — and
    /// it is why this interval, and not the sweep's fifteen seconds, is what the
    /// call sits on. Anything faster would hammer the network from a machine
    /// that has none.
    static let weatherInterval: TimeInterval = WeatherService.minimumInterval
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
    /// Where the last weather reading lives, and its timestamp — the throttle
    /// has to survive a window being closed and reopened.
    @EnvironmentObject private var settings: AppSettingsStore
    /// Starts false and is corrected by the probe as soon as the view has a
    /// window: a true default would run one sweep for a window that turns out to
    /// be opening behind something else.
    @State private var isOnScreen = false
    @State private var isRefreshing = false
    /// One id for both sections: hovering a parked row must fade the field on
    /// track exactly as hovering an on-track row fades the pit lane.
    @State private var hoveredSessionID: String?
    /// The office's daylight. Held as state and refreshed on a slow clock of its
    /// own, so that the drawing is handed a sun rather than an instant.
    @State private var lighting = OfficeLighting.at(date: Date(),
                                                    place: UserPlace.current(),
                                                    weather: .clear)

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
        // The weather lives on the window's lifetime, gated by the same
        // occlusion as the sweep — never on the draw loop. A closed or hidden
        // window asks for nothing at all.
        .task(id: isOnScreen) {
            guard AgentverseRefreshSchedule.shouldRun(onScreen: isOnScreen) else { return }
            let place = UserPlace.current()
            let service = WeatherService()
            while !Task.isCancelled {
                _ = await service.refreshIfNeeded(settings: settings,
                                                  latitude: place.latitude,
                                                  longitude: place.longitude)
                try? await Task.sleep(
                    nanoseconds: UInt64(AgentverseRefreshSchedule.weatherInterval
                                        * Double(NSEC_PER_SEC))
                )
            }
        }
        // The sun, on its own clock and touching no network: it only reads the
        // weather the loop above has already stored.
        .task(id: isOnScreen) {
            guard AgentverseRefreshSchedule.shouldRun(onScreen: isOnScreen) else { return }
            let place = UserPlace.current()
            while !Task.isCancelled {
                lighting = OfficeLighting.at(date: Date(),
                                             place: place,
                                             weather: settings.currentWeather)
                try? await Task.sleep(
                    nanoseconds: UInt64(AgentverseRefreshSchedule.sunInterval
                                        * Double(NSEC_PER_SEC))
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
        let lighting = lighting
        TimelineView(.animation) { timeline in
            AgentverseScene(
                sessions: coordinator.onTrack,
                parked: coordinator.parked,
                workTokens: coordinator.workTokens,
                hovered: hovered,
                // The clock enters here and nowhere below: the scene itself is
                // a pure function of its inputs, so a test can pin the frame.
                frame: Int(timeline.date.timeIntervalSinceReferenceDate * 60),
                lighting: lighting
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
