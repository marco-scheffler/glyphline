import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Computed once per render pass — the accessor rebuilds its array on
            // every call, and the panel reads it more than once.
            let quotaBars = coordinator.quotaBars

            header

            if !quotaBars.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // Rows come from the coordinator, against the same freshness
                    // bound as the light and the header. The view has no bound of
                    // its own to get wrong.
                    ForEach(quotaBars) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            // A quiet section header rather than a second body
                            // line: the account name groups the bars, it is not
                            // one of the figures being read.
                            Text(group.displayName.uppercased())
                                .font(.caption2.weight(.semibold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)

                            // Message *and* rows. Accounts without a quota source
                            // appear with their reason, and that reason is not
                            // grounds to hide a billing cycle the cost path knows
                            // — which is the only real quota datum a user has
                            // until a provider route exists.
                            if let message = group.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if group.isSilent {
                                // No rows and no reason: the heading would
                                // otherwise stand over an empty frame and read as
                                // a broken row. Accounts with no quota source
                                // never reach here — they always carry a message.
                                Text(QuotaIndicator.noQuotaReportedMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Per group, never flattened: a row's id is its window
                            // kind, unique within a group but repeated across
                            // accounts, and one ForEach would silently drop the
                            // duplicates.
                            ForEach(group.rows) { row in
                                QuotaBarRowView(row: row, layout: .compact)
                            }
                        }
                    }
                }
            }

            // Whole-app failures only — the ledger being unavailable or
            // unreadable. Per-account conditions are already carried by the
            // quota groups above.
            if let syncFailureMessage = coordinator.syncFailureMessage {
                Text(syncFailureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if quotaBars.isEmpty {
                // Without this a fresh install shows a title and three buttons,
                // with nothing saying why the panel is empty.
                Text("No accounts yet. Open the dashboard to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // A compact footer row rather than three stacked full-width buttons:
            // these are the panel's exits, not its content.
            HStack(spacing: 6) {
                Button("Open Dashboard", action: openDashboard)
                Button("Sync Now") {
                    Task {
                        await coordinator.syncAll()
                    }
                }
                .disabled(coordinator.activities.values.contains(where: \.isRunning))

                Spacer(minLength: 0)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
        .task {
            await coordinator.refreshRateWindowsOnDemand()
        }
    }

    /// Title left, the light right. The dot is the *same* state the menu bar icon
    /// shows — read from `quotaLight`, never recomputed here — so the panel and
    /// the icon cannot disagree once the panel is open.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Glyphline")
                .font(.headline)

            Spacer(minLength: 8)

            Circle()
                .fill(lightColor(for: coordinator.quotaLight))
                .frame(width: 8, height: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(QuotaIndicator.accessibilityLabel(for: coordinator.quotaLight))
        }
    }

    private func lightColor(for state: QuotaLightState) -> Color {
        switch state {
        case .green: .green
        case .red: .red
        case .grey: .secondary
        }
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
