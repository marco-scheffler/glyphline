import SwiftUI

struct DashboardView: View {
    @State private var selection: DashboardDestination? = .overview
    @State private var accountSummaries: [AccountUsageSummary] = []
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
                        await coordinator.refreshRateWindowsOnDemand()
                        loadDashboard()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .onAppear(perform: loadDashboard)
        // Attached to the window's root, not to a detail view, so it fires when
        // the window opens rather than on every sidebar navigation. The quota
        // figures were otherwise only refreshed by opening the menu bar panel.
        // `refreshRateWindowsOnDemand` guards per account against a concurrent
        // fetch, so overlapping with a scheduled tick is safe.
        .task { await coordinator.refreshRateWindowsOnDemand() }
        // Once per launch, alongside the quota collection and never from the
        // statistics screen's own appearance: the first scan reads gigabytes
        // across hundreds of project directories.
        .task { await coordinator.scanLocalUsageOnceAtLaunch() }
    }

    @ViewBuilder private var detailView: some View {
        switch selection ?? .overview {
        case .overview:
            DashboardOverview(
                accountSummaries: accountSummaries,
                loadError: loadError,
                syncFailureMessage: coordinator.syncFailureMessage
            )
        case .accounts:
            AccountsView(
                accounts: accountSummaries,
                ledgerStore: ledgerStore,
                onDeleted: loadDashboard
            )
        case .statistics:
            StatisticsView()
        case .addAccount:
            AddAccountView(ledgerStore: ledgerStore, onSave: loadDashboard)
        case .settings:
            SettingsView()
        }
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

private enum DashboardDestination: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case statistics
    case addAccount
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .accounts:
            "Accounts"
        case .statistics:
            "Statistics"
        case .addAccount:
            "Add Account"
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
        case .statistics:
            "chart.bar"
        case .addAccount:
            "plus.circle"
        case .settings:
            "gearshape"
        }
    }
}

private struct DashboardOverview: View {
    let accountSummaries: [AccountUsageSummary]
    let loadError: String?
    let syncFailureMessage: String?

    /// Read here rather than passed down: `quotaBars` is the coordinator's own
    /// accessor, and routing it through an initialiser would let a caller
    /// substitute an array built against some other freshness bound.
    @EnvironmentObject private var coordinator: SyncCoordinator

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
                    Text("Remaining quota across your accounts at a glance.")
                        .foregroundStyle(.secondary)
                }

                if let syncFailureMessage {
                    Label(syncFailureMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    SummaryPanel(
                        title: "Enabled Accounts",
                        value: "\(accountSummaries.filter(\.account.isEnabled).count)",
                        note: "Saved providers ready to sync"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Account Health")
                        .font(.title3.weight(.semibold))

                    if let loadError, accountSummaries.isEmpty {
                        Text(loadError)
                            .foregroundStyle(.secondary)
                    } else if accountSummaries.isEmpty {
                        Text("No accounts saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Computed once per render pass. The accessor rebuilds the
                        // whole array on every call, so reading it inside the
                        // ForEach would cost one rebuild per card.
                        let quotaBars = coordinator.quotaBars

                        ForEach(accountSummaries) { summary in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(summary.account.displayName)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                // Matched by account id, never by position: this
                                // list and the quota groups are ordered
                                // independently, and attributing one
                                // subscription's quota to another is the failure
                                // this app works hardest to avoid.
                                if let quota = quotaBars.first(where: { $0.id == summary.account.id }) {
                                    if let message = quota.message {
                                        Text(message)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    } else if quota.isSilent {
                                        Text(QuotaIndicator.noQuotaReportedMessage)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        // Per group, never flattened: a row's id is
                                        // its window kind, unique within a group but
                                        // repeated across accounts.
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(quota.rows) { row in
                                                QuotaBarRowView(row: row)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(24)
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
