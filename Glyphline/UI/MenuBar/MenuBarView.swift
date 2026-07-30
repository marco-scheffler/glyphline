import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Computed once per render pass — the accessor rebuilds its array on
            // every call, and the panel reads it three times.
            let quotaBars = coordinator.quotaBars

            Text("Glyphline")
                .font(.headline)

            Picker("Mode", selection: appModeBinding) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if !quotaBars.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let nextFree = coordinator.nextFreeText {
                        Text("Next free: \(nextFree)")
                            .font(.caption.weight(.medium))
                    }

                    // Rows come from the coordinator, against the same freshness
                    // bound as the light and the header. The view has no bound of
                    // its own to get wrong.
                    ForEach(quotaBars) { group in
                        VStack(alignment: .leading, spacing: 4) {
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

                            // Per group, never flattened: a row's id is its window
                            // kind, unique within a group but repeated across
                            // accounts, and one ForEach would silently drop the
                            // duplicates.
                            ForEach(group.rows) { row in
                                QuotaBarRowView(row: row, barWidth: 110)
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
            } else if quotaBars.isEmpty {
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
