import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var accountSummaries: [AccountUsageSummary] = []
    @State private var loadError: String?

    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var agentverse: AgentverseCoordinator

    private let ledgerStore: LedgerStore?

    init(ledgerStore: LedgerStore? = LedgerStore.makeDefault()) {
        self.ledgerStore = ledgerStore
    }

    var body: some View {
        // No sidebar. It held two rows, both of which are configuration and now
        // live in the settings window, and it charged the dashboard about 214
        // points for them — width the three summary tiles, the row of quota
        // cards and the thirty-bar chart all actually use.
        DashboardOverview(
            accountSummaries: accountSummaries,
            loadError: loadError,
            syncFailureMessage: coordinator.syncFailureMessage,
            openAgentverse: { AgentverseLauncher.open(using: openWindow) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 640)
        // The surface the glass cards refract. Without it they sample the
        // system's neutral window background and the dashboard reads grey.
        //
        // Read from the settings store rather than fixed, and read here rather
        // than inside the background view: the store is `@Published`, so picking
        // a palette in the settings window redraws this body and the surface
        // changes under the open dashboard without it being reopened.
        .dashboardWindowBackground(palette: settings.dashboardPalette)
        // Every palette is a very dark surface, so the window has to be dark
        // whatever the system is set to: in light appearance the labels would
        // come out near-black on it. Pinned here rather than app-wide — the
        // settings and menu bar surfaces are ordinary system chrome and should
        // keep following the user's choice.
        .preferredColorScheme(.dark)
        .navigationTitle("Glyphline")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await coordinator.refreshRateWindowsOnDemand()
                        await agentverse.refresh()
                        loadDashboard()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            // `SettingsLink`, the same control the menu bar footer and the
            // attention banner use. The app has exactly one way of opening
            // settings; ⌘, and this button land on the same window.
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        .onAppear(perform: loadDashboard)
        // Attached to the window's root, not to a detail view, so it fires when
        // the window opens rather than on every sidebar navigation. The quota
        // figures were otherwise only refreshed by opening the menu bar panel.
        // `refreshRateWindowsOnDemand` guards per account against a concurrent
        // fetch, so overlapping with a scheduled tick is safe.
        .task { await coordinator.refreshRateWindowsOnDemand() }
        // Once per launch, alongside the quota collection and never from a
        // detail view's own appearance: the first scan reads gigabytes across
        // hundreds of project directories.
        .task { await coordinator.scanLocalUsageOnceAtLaunch() }
        // The Agents tile counts agents, so the dashboard needs a
        // sweep of its own — the map's window may never have been opened.
        .task { await agentverse.refresh() }
    }

    private func loadDashboard() {
        guard let ledgerStore else {
            loadError = "Ledger unavailable."
            accountSummaries = []
            return
        }

        do {
            accountSummaries = try ledgerStore.fetchAccountSummaries()
            loadError = nil
        } catch {
            accountSummaries = []
            loadError = "Could not load ledger data."
        }
    }
}
