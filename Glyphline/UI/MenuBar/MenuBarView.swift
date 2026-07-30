import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Glyphline")
                .font(.headline)

            Picker("Mode", selection: appModeBinding) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if !coordinator.quotaRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let nextFree = coordinator.nextFreeText {
                        Text("Next free: \(nextFree)")
                            .font(.caption.weight(.medium))
                    }

                    // Rows come pre-rendered from the coordinator, against the
                    // same freshness bound as the light and the header. The view
                    // has no bound of its own to get wrong.
                    ForEach(coordinator.quotaRows) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName)
                                .font(.caption)

                            // Message *and* rows. Accounts without a quota source
                            // appear with their reason, and that reason is not
                            // grounds to hide a billing cycle the cost path knows
                            // — which is the only real quota datum a user has
                            // until a provider route exists.
                            if let message = group.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                                Text(row)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()
            }

            // Whole-app failures only — the ledger being unavailable or
            // unreadable. Per-account conditions are already carried by the
            // quota groups above.
            if let syncFailureMessage = coordinator.syncFailureMessage {
                Text(syncFailureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if coordinator.quotaRows.isEmpty {
                // Without this a fresh install shows a title, a picker and three
                // buttons, with nothing saying why the popover is empty.
                Text("No accounts yet. Open the dashboard to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Open Dashboard", action: openDashboard)
                Button("Sync Now") {
                    Task {
                        await coordinator.syncAll()
                    }
                }
                .disabled(coordinator.activities.values.contains(where: \.isRunning))
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 320)
        .task {
            await coordinator.refreshRateWindowsOnDemand()
        }
    }

    private var appModeBinding: Binding<AppMode> {
        Binding(
            get: { settings.appMode },
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
