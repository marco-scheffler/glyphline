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
                // Tabs, not a menu: as a menu this collapsed into the toolbar's
                // overflow chevron and the five circuits became unreachable.
                // Tabs only fit on the short labels — the formal names run to
                // "Circuit de Spa-Francorchamps".
                Picker("Circuit", selection: $circuitKey) {
                    ForEach((try? catalogLoad?.get())?.entriesInPickerOrder ?? [], id: \.key) { entry in
                        Text(entry.short).tag(entry.key).help(entry.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .automatic) {
                Picker("Weather", selection: $weatherChoice) {
                    ForEach(WeatherChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .help("What the sky over the circuit is doing. Auto follows the "
                      + "weather on location.")
            }
            if let circuit = selectedCircuit {
                ToolbarItem(placement: .automatic) { timeControls(circuit) }
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

    /// The slider, the circuit's local time beside it, and the way back to now.
    ///
    /// The time is shown because the conversion behind it — slider position to
    /// local wall clock at the circuit to UTC — is exactly the kind that produces
    /// a plausibly lit scene when it runs the wrong way round. On screen it is
    /// obvious that switching to Suzuka moved the clock to Japan.
    @ViewBuilder private func timeControls(_ circuit: Circuit) -> some View {
        let minutes = Binding(
            get: { localMinutesOverride ?? CircuitClock.minutesOfLocalDay(for: circuit, at: now) },
            set: { localMinutesOverride = $0 }
        )
        HStack(spacing: 8) {
            Slider(value: minutes, in: 0...CircuitClock.minutesPerDay)
                // Narrower than it was: the circuit tabs have to come from
                // somewhere, and a day is still a day at 120 points.
                .frame(width: 120)
                .help("The time of day at the circuit")
            Text(CircuitClock.localTimeText(for: circuit, at: instant(for: circuit)))
                .font(.callout.monospacedDigit())
                // Wide enough for the longest form the locale can produce, so
                // the neighbouring button does not shuffle as the clock runs.
                .frame(minWidth: 62, alignment: .leading)
            Button("Now") { localMinutesOverride = nil }
                .disabled(localMinutesOverride == nil)
        }
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
        let instant = instant(for: circuit)
        let weather = weatherChoice.weather
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
                instant: instant,
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
        // One word: five circuit tabs now share the toolbar with these five, and
        // "On location" was the widest segment in either control.
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
