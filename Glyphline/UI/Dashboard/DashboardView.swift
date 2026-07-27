import SwiftUI

struct DashboardView: View {
    @State private var selection: DashboardDestination? = .overview
    @State private var historyEntries: [HistorySummaryEntry] = []
    @State private var historyLoadError: String?

    private let ledgerStore: LedgerStore?

    init(ledgerStore: LedgerStore? = DashboardView.makeDefaultLedgerStore()) {
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
        .onAppear(perform: loadHistory)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .overview {
        case .overview:
            DashboardOverview(historyEntries: historyEntries, historyLoadError: historyLoadError)
        case .accounts:
            AccountsView(accounts: PlaceholderContent.accounts)
        case .addAccount:
            AddAccountView(providers: PlaceholderContent.providerOptions)
        case .history:
            HistoryView(entries: historyEntries)
        case .settings:
            SettingsView()
        }
    }

    private func loadHistory() {
        guard let ledgerStore else {
            historyLoadError = "Ledger unavailable."
            historyEntries = []
            return
        }

        do {
            let accounts = try ledgerStore.fetchAccounts()
            historyEntries = try accounts
                .flatMap { account in
                    try ledgerStore.fetchDailySummaries(accountID: account.id).map { summary in
                        HistorySummaryEntry(accountName: account.displayName, summary: summary)
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
            historyLoadError = nil
        } catch {
            historyEntries = []
            historyLoadError = "Unable to load history."
        }
    }

    private static func makeDefaultLedgerStore() -> LedgerStore? {
        guard let dbQueue = try? DatabaseQueueFactory.makeDefault() else {
            return nil
        }

        try? Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
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
            "Dashboard"
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
    let historyEntries: [HistorySummaryEntry]
    let historyLoadError: String?

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
                    Text("Usage snapshots, estimates, and data quality at a glance.")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    SummaryPanel(
                        title: "Enabled Accounts",
                        value: "\(PlaceholderContent.enabledAccounts)",
                        note: "Saved providers ready for sync"
                    )
                    SummaryPanel(
                        title: "Monthly Estimate",
                        value: PlaceholderContent.monthlyEstimateSummary,
                        note: "Mixed exact and estimated totals"
                    )
                    SummaryPanel(
                        title: "Request Volume",
                        value: PlaceholderContent.requestVolumeSummary,
                        note: "Latest sync window"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent History")
                        .font(.title3.weight(.semibold))

                    if let historyLoadError, historyEntries.isEmpty {
                        Text(historyLoadError)
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

                    ForEach(PlaceholderContent.accounts) { summary in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.account.displayName)
                                    .font(.headline)
                                Text(summary.costSourceSummary)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            VStack(alignment: .trailing, spacing: 6) {
                                DataQualityBadge(quality: summary.dataQuality)
                                Text(summary.monthlyCostSummary)
                                    .font(.headline)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Data Quality")
                        .font(.title3.weight(.semibold))

                    ForEach(PlaceholderContent.qualityLegend, id: \.rawValue) { quality in
                        HStack(spacing: 12) {
                            DataQualityBadge(quality: quality)
                            Text(qualitySummary(for: quality))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func qualitySummary(for quality: DataQuality) -> String {
        switch quality {
        case .exact:
            "The provider delivered the usage value directly."
        case .estimated:
            "Glyphline derived the number from usage and known pricing."
        case .partial:
            "Some provider fields were present, but the full picture was not."
        case .unavailable:
            "No reliable usage data could be shown."
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
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
