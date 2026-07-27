import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var accountSummaries: [AccountUsageSummary] = []
    @State private var loadError: String?

    private let ledgerStore: LedgerStore?

    init(ledgerStore: LedgerStore? = LedgerStore.makeDefault()) {
        self.ledgerStore = ledgerStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glyphline")
                    .font(.headline)
                Text(totalCostSummary)
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
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if accountSummaries.isEmpty {
                    Text("No accounts saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accountSummaries.prefix(3)) { summary in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.account.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(AccountSummaryFormatting.status(summary))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            DataQualityBadge(quality: summary.dataQuality)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Open Dashboard", action: openDashboard)
                Button("Refresh", action: loadSummaries)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear(perform: loadSummaries)
    }

    private var totalCostSummary: String {
        let costRows = accountSummaries.compactMap { summary -> (Int64, String)? in
            guard let amount = summary.displayAmountMicros, let currency = summary.displayCurrency else {
                return nil
            }

            return (amount, currency)
        }

        guard let currency = costRows.first?.1, costRows.allSatisfy({ $0.1 == currency }) else {
            return costRows.isEmpty ? "No API cost yet" : "Mixed currency total"
        }

        let total = costRows.reduce(Int64(0)) { $0 + $1.0 }
        return "\(AccountSummaryFormatting.money(total, currency: currency)) API cost"
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

    private func loadSummaries() {
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

    private func openDashboard() {
        if !settings.appMode.showsDashboardWindow {
            settings.appMode = .menuBarAndWindow
        }

        AppActivationController.apply(mode: settings.appMode)
        openWindow(id: AppMode.dashboardWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
