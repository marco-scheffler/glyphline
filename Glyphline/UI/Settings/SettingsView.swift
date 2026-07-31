import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore

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

            Section("Data Sources") {
                ForEach(CircuitAttribution.lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
    }

    private var appModeBinding: Binding<AppMode> {
        Binding(
            get: { settings.appMode },
            set: { newMode in
                let previousMode = settings.appMode
                settings.appMode = newMode
                if newMode.requiresDashboardOpen(afterTransitioningFrom: previousMode) {
                    openWindow(id: AppMode.dashboardWindowID)
                }
            }
        )
    }

    private var modeDescription: String {
        switch settings.appMode {
        case .menuBarOnly:
            return "Glyphline stays in the menu bar and closes the dashboard window."
        case .windowOnly:
            return "Glyphline behaves like a standard macOS app without a menu bar extra."
        case .menuBarAndWindow:
            return "Glyphline keeps both the dashboard window and menu bar extra available."
        }
    }
}
