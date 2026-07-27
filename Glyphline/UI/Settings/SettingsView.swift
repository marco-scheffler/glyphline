import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("App Mode") {
                Picker("Presentation", selection: $settings.appMode) {
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
                ForEach(PlaceholderContent.qualityLegend, id: \.rawValue) { quality in
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

    private var modeDescription: String {
        switch settings.appMode {
        case .menuBarOnly:
            "Glyphline stays in the menu bar and keeps the main app hidden until you change modes."
        case .windowOnly:
            "Glyphline behaves like a standard macOS app without a menu bar extra."
        case .menuBarAndWindow:
            "Glyphline keeps both the dashboard window and the menu bar extra available."
        }
    }

    private func qualityDescription(for quality: DataQuality) -> String {
        switch quality {
        case .exact:
            "Reported directly by the provider."
        case .estimated:
            "Calculated from usage using the local pricing catalog."
        case .partial:
            "Only some provider fields were available."
        case .unavailable:
            "No trustworthy usage data is currently available."
        }
    }
}
