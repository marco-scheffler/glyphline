import AppKit
import SwiftUI

struct MenuBarView: View {
    /// The panel's fixed width and the inset its content sits in. Named because
    /// the footer row has to fit inside them, and a menu bar panel that outgrows
    /// its width clips its trailing control without saying anything.
    static let panelWidth: CGFloat = 320
    static let panelPadding: CGFloat = 12

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

            MenuBarFooter(
                openDashboard: openDashboard,
                openAgentverse: {
                    AppActivationController.regulariseForWindow()
                    openWindow(id: AppMode.agentverseWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                },
                refresh: {
                    Task {
                        await coordinator.refreshRateWindowsOnDemand()
                    }
                }
            )
        }
        .padding(Self.panelPadding)
        .frame(width: Self.panelWidth)
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

/// The panel's exits: a compact row rather than stacked full-width buttons,
/// because these are not the panel's content.
///
/// Its own view for two reasons. The row now carries four controls plus Quit
/// inside 320 points, which is where it starts clipping — and a clipped menu bar
/// panel says nothing about it. And a `SettingsLink` needs no environment, so
/// the row can be hosted off screen and measured.
struct MenuBarFooter: View {
    let openDashboard: () -> Void
    let openAgentverse: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Two rows, not one. Five controls in 320 points overflow by about
            // 58 of them, and a menu bar panel clips what does not fit from the
            // trailing edge without a word — which is where Quit sits.
            //
            // Split by kind rather than to even the rows out: the top row opens
            // something, the bottom row acts on the app.
            HStack(spacing: 6) {
                Button("Dashboard", action: openDashboard)
                Button("Agentverse", action: openAgentverse)

                // `SettingsLink`, not the `openSettings` environment action. In
                // `.menuBarOnly` the app runs as an accessory: it has no app
                // menu, so ⌘, has nothing to hang off and this row is the only
                // way into settings at all. `SettingsLink` is the control that
                // is handed the settings window directly and works from a menu
                // bar extra, which is the part the environment action has
                // historically not.
                SettingsLink {
                    Text("Settings")
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Button("Refresh", action: refresh)

                Spacer(minLength: 0)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
