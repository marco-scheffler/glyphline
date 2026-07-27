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

            Section("Data Quality Legend") {
                ForEach(DataQuality.allCases, id: \.rawValue) { quality in
                    HStack {
                        DataQualityBadge(quality: quality)
                        Text(qualityDescription(for: quality))
                            .foregroundStyle(.secondary)
                    }
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

    private func qualityDescription(for quality: DataQuality) -> String {
        switch quality {
        case .exact:
            return "Provider-reported usage or cost."
        case .estimated:
            return "Derived from local pricing rules."
        case .partial:
            return "Some provider fields are unavailable."
        case .unavailable:
            return "No dependable usage value yet."
        }
    }
}
