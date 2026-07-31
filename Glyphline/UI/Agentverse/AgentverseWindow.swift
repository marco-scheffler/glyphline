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
    /// Three states in one value: nil is still loading, and only `.failure` is a
    /// failure. A plain optional made the first frames of every opening show the
    /// pane a corrupt bundle shows.
    @State private var catalogLoad: Result<CircuitCatalog, Error>?
    @State private var circuitKey = "monaco"
    /// One id for both sections: hovering a parked row must fade the field on
    /// track exactly as hovering an on-track row fades the pit lane.
    @State private var hoveredSessionID: String?
    /// Both overrides are plain `@State` and nothing else: the ask was that they
    /// reset when the window closes, and anything persisted would outlive it.
    @State private var weatherChoice: WeatherChoice = .onLocation
    /// Minutes past local midnight *at the circuit*, or nil while the scene is
    /// simply following the clock there. Nil rather than a flag beside a value:
    /// with a value there is always a second copy of "now" to keep current.
    @State private var localMinutesOverride: Double?
    /// The window's own coarse clock, so the toolbar's time and an un-overridden
    /// scene keep up without a per-frame date. Half a minute of sun is an eighth
    /// of a degree — far below the two degrees the static picture buckets by, so
    /// this costs no extra rebuilds.
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            // Above the split view and across the whole window: the strip is
            // about the scene as a whole, and it is the only place these six
            // controls all fit on one row.
            AgentverseControlStrip(
                // Deliberately not persisted: whether the choice should survive
                // a reopening is still open, and storing it would settle it.
                circuits: (try? catalogLoad?.get())?.entriesInPickerOrder ?? [],
                circuitKey: $circuitKey,
                weatherChoice: $weatherChoice,
                localMinutesOverride: $localMinutesOverride,
                localMinutesNow: selectedCircuit.map {
                    CircuitClock.minutesOfLocalDay(for: $0, at: now)
                } ?? 0,
                clockText: selectedCircuit.map {
                    CircuitClock.localTimeText(for: $0, at: instant(for: $0))
                } ?? "",
                hasCircuit: selectedCircuit != nil
            )
            HSplitView {
                AgentverseSidebar(hovered: $hoveredSessionID)
                    .frame(minWidth: 240, idealWidth: 264, maxWidth: 340)
                scene
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .task {
            // Ticks for as long as the window is open and stops with it.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        .task {
            // Decoded once per window rather than at launch: 683 KB of JSON is
            // not worth paying for on a launch that may never open this window.
            catalogLoad = Result { try CircuitCatalog.bundled() }
        }
    }

    private var selectedCircuit: Circuit? {
        (try? catalogLoad?.get())?.circuit(circuitKey)
    }

    /// The UTC instant the scene is lit at: the override read as a wall-clock
    /// time at the circuit, or simply now.
    private func instant(for circuit: Circuit) -> Date {
        guard let localMinutesOverride else { return now }
        return CircuitClock.instant(for: circuit, minutesOfLocalDay: localMinutesOverride, on: now)
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
        let weather = weatherChoice.weather
        // Solved here and not below: this body runs when the coarse clock ticks
        // or the user moves something, while the `TimelineView` under it rebuilds
        // its content sixty times a second. The solve walks a `Calendar`, and the
        // sun moves an eighth of a degree between two ticks.
        let sun = SunPosition.at(latitude: circuit.lat, longitude: circuit.lon,
                                 date: instant(for: circuit))
        TimelineView(.animation) { timeline in
            AgentverseScene(
                circuit: circuit,
                sessions: coordinator.onTrack,
                parked: coordinator.parked,
                workTokens: coordinator.workTokens,
                hovered: hovered,
                // The clock enters here and nowhere below: the scene itself is
                // a pure function of its inputs, so a test can pin the frame.
                frame: Int(timeline.date.timeIntervalSinceReferenceDate * 60),
                sun: sun,
                weather: weather
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

/// What the weather control offers: the four skies `SceneLight` models, plus the
/// one that is not an override at all.
///
/// `onLocation` means "whatever it is actually doing over the circuit". Nothing
/// reports that yet, so today it resolves to clear — but it is a named case
/// rather than a fifth spelling of clear, so that wiring a real report in later
/// changes one line here and nothing the user has to relearn.
enum WeatherChoice: Hashable, CaseIterable {
    case onLocation
    case fixed(Weather)

    static var allCases: [WeatherChoice] { [.onLocation] + Weather.allCases.map(WeatherChoice.fixed) }

    var weather: Weather {
        switch self {
        case .onLocation: return .clear
        case .fixed(let weather): return weather
        }
    }

    var label: String {
        switch self {
        // One word: five circuit tabs share the control strip's row with these
        // five, and "On location" was the widest segment in either control.
        case .onLocation: return "Auto"
        case .fixed(.clear): return "Clear"
        case .fixed(.cloud): return "Cloud"
        case .fixed(.rain): return "Rain"
        case .fixed(.fog): return "Fog"
        }
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
