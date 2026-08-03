import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var updates: UpdateController
    @State private var latitudeInput = ""
    @State private var longitudeInput = ""

    var body: some View {
        Form {
            Section("App Mode") {
                Picker("Presentation", selection: appModeBinding) {
                    ForEach(AppMode.allCases) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeDescription)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                Toggle("Sync automatically", isOn: $settings.automaticSyncEnabled)

                Picker("Interval", selection: $settings.syncIntervalMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                .disabled(!settings.automaticSyncEnabled)

                Text("Glyphline also syncs after the Mac wakes from sleep.")
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)

                LabeledContent {
                    Button("Check Now") {
                        updates.checkForUpdates()
                    }
                    // Grey while a check is already running, rather than
                    // queueing a second one behind the first.
                    .disabled(!updates.canCheckForUpdates)
                } label: {
                    Text("Version \(Self.installedVersion)")
                }

                // Said plainly because it is the reassurance that matters: an
                // app that reads your quota data must not be one that swaps
                // itself out while you are not looking.
                Text("Glyphline checks once a day and always asks before installing anything.")
                    .foregroundStyle(.secondary)
            }

            Section("Location") {
                // Edited as text rather than bound straight to the numbers: a
                // half-typed "-" or "52." is not a coordinate yet, and a numeric
                // binding would fight the user for the field on every keystroke.
                TextField("Latitude", text: $latitudeInput, prompt: Text("From time zone"))
                    .onChange(of: latitudeInput) { _, new in
                        settings.manualLatitude = Self.coordinate(from: new, limit: 90)
                    }
                TextField("Longitude", text: $longitudeInput, prompt: Text("From time zone"))
                    .onChange(of: longitudeInput) { _, new in
                        settings.manualLongitude = Self.coordinate(from: new, limit: 180)
                    }

                Text(placeDescription)
                    .foregroundStyle(resolvedPlace.source == .offsetFallback ? .orange : .secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
        .onAppear {
            latitudeInput = Self.text(for: settings.manualLatitude)
            longitudeInput = Self.text(for: settings.manualLongitude)
        }
    }

    /// The version the user is actually running, read from the bundle rather
    /// than written down here — a number kept in two places is a number that
    /// eventually disagrees with itself, and this one is next to a button whose
    /// whole job is to compare versions.
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var resolvedPlace: UserPlace.Coordinates {
        UserPlace.current(override: settings.placeOverride)
    }

    /// What the app is actually lighting the office with, and where that came
    /// from. The fallback case is called out because a scene lit from the wrong
    /// hemisphere looks entirely plausible: nothing on screen gives it away, so
    /// the only way the user can know is to be told.
    private var placeDescription: String {
        let place = resolvedPlace
        let latitude = place.latitude.formatted(.number.precision(.fractionLength(0...2)))
        let longitude = place.longitude.formatted(.number.precision(.fractionLength(0...2)))
        let point = "\(latitude), \(longitude)"

        switch place.source {
        case .manual:
            return "Using the coordinates you entered: \(point)."
        case .table:
            return "From your time zone \(TimeZone.current.identifier): \(point)."
        case .offsetFallback:
            return """
            Your time zone \(TimeZone.current.identifier) is not in Glyphline's table. \
            The longitude \(longitude) comes from its GMT offset, and the latitude \
            \(latitude) is a guess — an offset says nothing about how far north or \
            south you are, not even which hemisphere. Enter your coordinates above \
            if the daylight looks wrong.
            """
        }
    }

    /// Nil for anything that is not a usable coordinate yet, which is what
    /// clears the override — so emptying the field returns to the time zone.
    private static func coordinate(from text: String, limit: Double) -> Double? {
        // A German keyboard's decimal separator is a comma; refusing it would
        // read as the field being broken.
        let normalised = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalised), value >= -limit, value <= limit else { return nil }
        return value
    }

    private static func text(for value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private var appModeBinding: Binding<AppMode> {
        Binding(
            get: { settings.appMode },
            set: { newMode in
                settings.appMode = newMode
                // Window mode carries no menu bar extra, so switching into it
                // with nothing on screen would leave the app with no surface
                // at all — the settings window the user is standing in is not
                // one, since closing it would strand them.
                //
                // The other direction closes nothing: an open dashboard stays
                // open, and the Dock icon with it, until the user closes it.
                if newMode.opensDashboardAtLaunch,
                   !AppActivationController.hasWindowNeedingRegularApp(
                       excluding: AppActivationController.claimedSettingsWindow
                   ) {
                    DashboardLauncher.open(using: openWindow)
                }
            }
        )
    }

    private var modeDescription: String {
        switch settings.appMode {
        case .menuBarOnly:
            return String(
                localized: "Glyphline lives in the menu bar. It appears in the Dock only while the dashboard or the Agentverse is open.",
                comment: "Settings, App Mode section: what the menu bar mode does. Shown under the picker."
            )
        case .windowOnly:
            return String(
                localized: "Glyphline behaves like a standard Mac app: always in the Dock, with no menu bar extra.",
                comment: "Settings, App Mode section: what the window mode does. Shown under the picker."
            )
        }
    }
}
