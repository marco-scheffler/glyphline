import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glyphline")
                    .font(.headline)
                Text(PlaceholderContent.monthlyEstimateSummary + " sample total")
                    .foregroundStyle(.secondary)
            }

            Picker("Mode", selection: appModeBinding) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(PlaceholderContent.accounts.prefix(3)) { summary in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.account.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(summary.statusSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                        DataQualityBadge(quality: summary.dataQuality)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Open Dashboard", action: openDashboard)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var appModeBinding: Binding<AppMode> {
        Binding(
            get: {
                settings.appMode
            },
            set: { newMode in
                let previousMode = settings.appMode
                settings.appMode = newMode

                if newMode.requiresDashboardOpen(afterTransitioningFrom: previousMode) {
                    openDashboard()
                }
            }
        )
    }

    private func openDashboard() {
        if !settings.appMode.showsDashboardWindow {
            settings.appMode = .menuBarAndWindow
        }

        AppActivationController.apply(mode: settings.appMode)
        openWindow(id: AppMode.dashboardWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
