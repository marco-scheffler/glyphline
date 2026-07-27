import SwiftUI

struct DashboardView: View {
    @State private var selection: DashboardDestination? = .overview
    @State private var accountSummaries: [AccountUsageSummary] = []
    @State private var historyEntries: [HistorySummaryEntry] = []
    @State private var loadError: String?

    @EnvironmentObject private var coordinator: SyncCoordinator

    private let ledgerStore: LedgerStore?

    init(ledgerStore: LedgerStore? = LedgerStore.makeDefault()) {
        self.ledgerStore = ledgerStore
    }

    var body: some View {
        NavigationSplitView {
            List(DashboardDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Glyphline")
            .frame(minWidth: 220, idealWidth: 240)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await coordinator.syncAll()
                        loadDashboard()
                    }
                } label: {
                    Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(coordinator.activities.values.contains(where: \.isRunning))
            }
        }
        .onAppear(perform: loadDashboard)
    }

    @ViewBuilder private var detailView: some View {
        switch selection ?? .overview {
        case .overview:
            DashboardOverview(
                accountSummaries: accountSummaries,
                historyEntries: historyEntries,
                loadError: loadError
            )
        case .accounts:
            AccountsView(accounts: accountSummaries, onSyncFinished: loadDashboard)
        case .addAccount:
            AddAccountView(ledgerStore: ledgerStore, onSave: loadDashboard)
        case .history:
            HistoryView(entries: historyEntries)
        case .settings:
            SettingsView()
        }
    }

    private func loadDashboard() {
        guard let ledgerStore else {
            loadError = "Ledger unavailable."
            accountSummaries = []
            historyEntries = []
            return
        }

        do {
            accountSummaries = try ledgerStore.fetchAccountSummaries()
            historyEntries = try accountSummaries
                .flatMap { summary in
                    try ledgerStore.fetchDailySummaries(accountID: summary.account.id).map { dailySummary in
                        HistorySummaryEntry(
                            accountName: summary.account.displayName,
                            summary: dailySummary
                        )
                    }
                }
                .sorted { lhs, rhs in
                    if lhs.summary.dayStart == rhs.summary.dayStart {
                        let lhsName = lhs.accountName ?? ""
                        let rhsName = rhs.accountName ?? ""
                        if lhsName == rhsName {
                            return lhs.summary.accountID.uuidString < rhs.summary.accountID.uuidString
                        }

                        return lhsName < rhsName
                    }

                    return lhs.summary.dayStart > rhs.summary.dayStart
                }
            loadError = nil
        } catch {
            accountSummaries = []
            historyEntries = []
            loadError = "Could not load ledger data."
        }
    }
}

private enum DashboardDestination: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case addAccount
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .accounts:
            "Accounts"
        case .addAccount:
            "Add Account"
        case .history:
            "History"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "rectangle.grid.2x2"
        case .accounts:
            "person.2"
        case .addAccount:
            "plus.circle"
        case .history:
            "clock.arrow.circlepath"
        case .settings:
            "gearshape"
        }
    }
}

private struct DashboardOverview: View {
    let accountSummaries: [AccountUsageSummary]
    let historyEntries: [HistorySummaryEntry]
    let loadError: String?

    private let columns = [
        GridItem(.flexible(minimum: 160), spacing: 16),
        GridItem(.flexible(minimum: 160), spacing: 16),
        GridItem(.flexible(minimum: 160), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dashboard")
                        .font(.largeTitle.weight(.bold))
                    Text("Usage snapshots, estimates, data quality at a glance.")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    SummaryPanel(
                        title: "Enabled Accounts",
                        value: "\(accountSummaries.filter(\.account.isEnabled).count)",
                        note: "Saved providers ready to sync"
                    )
                    SummaryPanel(
                        title: "API Cost",
                        value: totalCostSummary,
                        note: "Actual cost preferred over estimates"
                    )
                    SummaryPanel(
                        title: "Request Volume",
                        value: AccountSummaryFormatting.requests(totalRequests),
                        note: "Persisted usage snapshots"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent History")
                        .font(.title3.weight(.semibold))

                    if let loadError, historyEntries.isEmpty {
                        Text(loadError)
                            .foregroundStyle(.secondary)
                    } else if historyEntries.isEmpty {
                        Text("No synced usage history yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(historyEntries.prefix(5)), id: \.id) { entry in
                            HistorySummaryRow(entry: entry, compact: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Account Health")
                        .font(.title3.weight(.semibold))

                    if accountSummaries.isEmpty {
                        Text("No accounts saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(accountSummaries) { summary in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(summary.account.displayName)
                                        .font(.headline)
                                    Text(AccountSummaryFormatting.costSource(summary))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                VStack(alignment: .trailing, spacing: 6) {
                                    DataQualityBadge(quality: summary.dataQuality)
                                    Text(AccountSummaryFormatting.money(
                                        summary.displayAmountMicros,
                                        currency: summary.displayCurrency
                                    ))
                                    .font(.headline)
                                    Text(AccountSummaryFormatting.billing(summary))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Data Quality")
                        .font(.title3.weight(.semibold))

                    ForEach(DataQuality.allCases, id: \.rawValue) { quality in
                        HStack(spacing: 12) {
                            DataQualityBadge(quality: quality)
                            Text(qualityDescription(for: quality))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    /// Nil while no account exposes a request count, so the panel shows an em
    /// dash instead of claiming a measured zero.
    private var totalRequests: Int64? {
        accountSummaries.reduce(nil) { partial, summary -> Int64? in
            guard let requestCount = summary.requestCount else {
                return partial
            }

            return (partial ?? 0) + requestCount
        }
    }

    private var totalCostSummary: String {
        let costRows = accountSummaries.compactMap { summary -> (Int64, String)? in
            guard let amount = summary.displayAmountMicros, let currency = summary.displayCurrency else {
                return nil
            }

            return (amount, currency)
        }

        guard let currency = costRows.first?.1, costRows.allSatisfy({ $0.1 == currency }) else {
            return costRows.isEmpty ? "No cost yet" : "Mixed currencies"
        }

        let total = costRows.reduce(Int64(0)) { $0 + $1.0 }
        return AccountSummaryFormatting.money(total, currency: currency)
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

private struct SummaryPanel: View {
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
