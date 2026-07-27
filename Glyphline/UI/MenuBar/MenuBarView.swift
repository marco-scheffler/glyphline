import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glyphline")
                    .font(.headline)
                Text(PlaceholderContent.monthlyEstimateSummary + " this cycle")
                    .foregroundStyle(.secondary)
            }

            Picker("Mode", selection: $settings.appMode) {
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

    private func openDashboard() {
        AppActivationController.apply(mode: settings.appMode)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: \.canBecomeMain) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
