import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var selection: DashboardDestination? = .dashboard
    @State private var accountSummaries: [AccountUsageSummary] = []
    @State private var loadError: String?

    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var agentverse: AgentverseCoordinator

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
                        await agentverse.refresh()
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
        // Once per launch, alongside the quota collection and never from a
        // detail view's own appearance: the first scan reads gigabytes across
        // hundreds of project directories.
        .task { await coordinator.scanLocalUsageOnceAtLaunch() }
        // The header's call to action counts agents, so the dashboard needs a
        // sweep of its own — the map's window may never have been opened.
        .task { await agentverse.refresh() }
    }

    @ViewBuilder private var detailView: some View {
        switch DashboardDestination.resolved(selection?.rawValue) {
        case .dashboard:
            DashboardOverview(
                accountSummaries: accountSummaries,
                loadError: loadError,
                syncFailureMessage: coordinator.syncFailureMessage,
                openAgentverse: { AgentverseLauncher.open(using: openWindow) }
            )
        case .accounts:
            AccountsView(
                accounts: accountSummaries,
                ledgerStore: ledgerStore,
                onDeleted: loadDashboard,
                onAdded: loadDashboard
            )
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

/// The one way into the map from the main window.
///
/// The Agentverse is a window of its own — at the dashboard's minimum width less
/// the sidebar the scene would get about 740 points against the 1690 it was
/// designed at — so this opens that window rather than switching the detail pane.
/// Same three steps as `MenuBarView`: the app has to become a regular one before
/// a window of this kind is any use. Kept as one function so the header's call to
/// action and any later entry point cannot drift into two different sequences.
enum AgentverseLauncher {
    @MainActor static func open(using openWindow: OpenWindowAction) {
        AppActivationController.regulariseForWindow()
        openWindow(id: AppMode.agentverseWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The sidebar's places. Adding an account is not one of them — it is an action,
/// and it lives as a button in `AccountsView`.
enum DashboardDestination: String, CaseIterable, Identifiable {
    case dashboard
    case accounts
    case settings

    var id: String { rawValue }

    /// The destination for a raw value that no longer names a case.
    ///
    /// Cases do get removed — `overview`, `statistics` and `addAccount` just
    /// were — so a selection carried over from an older build has to resolve
    /// through the failable initialiser and land here. Forcing the unwrap
    /// instead is how an app traps at launch after an update, with nothing to do
    /// about it but delete preferences.
    static func resolved(_ rawValue: String?) -> DashboardDestination {
        rawValue.flatMap(DashboardDestination.init(rawValue:)) ?? .dashboard
    }

    var title: String {
        switch self {
        case .dashboard:
            "Dashboard"
        case .accounts:
            "Accounts"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "rectangle.grid.2x2"
        case .accounts:
            "person.2"
        case .settings:
            "gearshape"
        }
    }
}

// MARK: - The overview

private struct DashboardOverview: View {
    let accountSummaries: [AccountUsageSummary]
    let loadError: String?
    let syncFailureMessage: String?
    let openAgentverse: () -> Void

    /// Read here rather than passed down: `quotaStates` is the coordinator's own
    /// accessor, and routing it through an initialiser would let a caller
    /// substitute figures built against some other freshness bound.
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var agentverse: AgentverseCoordinator

    @State private var period: LocalUsagePeriod = .last30Days
    @State private var breakdown: LocalUsageBreakdown?
    @State private var selectedDay: Date?

    /// The cost tile's own period, deliberately independent of `period` above:
    /// the chart's picker says how far back the bars reach, this one says what
    /// the spend figure covers. One control driving both would force a reader
    /// who wants a year's spend to also throw 365 bars at a 190-point plot.
    @State private var spendPeriod: SpendPeriod = .day
    /// All of the scanned history, not just the chart's period — the tile can be
    /// switched to a year while the chart shows a week, and slicing one series is
    /// cheaper and more consistent than a second query per period change.
    @State private var spendSeries: DailyUsageSeries?

    /// How many days the "vs. median" figure on the Today card looks back over.
    private static let medianDays = 7
    /// How many models the chart's legend can carry before the tail is folded
    /// into one bucket.
    private static let legendLimit = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let syncFailureMessage {
                    Label(syncFailureMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                }

                quotaSection
                usageSection
                notes
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyed on the period and on the scan revision, so the aggregates are
        // recomputed when either changes and not on every render pass — the
        // computation reads the ledger.
        .task(id: ReloadKey(period: period, revision: coordinator.localUsageRevision)) {
            breakdown = coordinator.localUsageBreakdown(since: period.since(now: Date()))
        }
        // Keyed on the scan revision alone: the whole history is fetched once and
        // every spend period is a slice of it, so changing the tile's period
        // costs no read at all.
        .task(id: coordinator.localUsageRevision) {
            spendSeries = coordinator.localUsageBreakdown(since: nil)?.series
        }
    }

    private struct ReloadKey: Equatable {
        var period: LocalUsagePeriod
        var revision: Int
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.largeTitle.weight(.bold))
                Text(accountSummaries.isEmpty
                    ? "No accounts saved yet"
                    : "\(accountSummaries.count) account\(accountSummaries.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            AgentverseCallToActionButton(model: callToAction, action: openAgentverse)
        }
    }

    private var callToAction: DashboardPresentation.AgentverseCallToAction {
        let waiting = agentverse.onTrack.filter { $0.activity == .waitingForYou }.count
        return DashboardPresentation.callToAction(
            waiting: waiting,
            working: agentverse.onTrack.count - waiting,
            resting: agentverse.parked.count
        )
    }

    // MARK: Quotas

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Quotas")

            Text(DashboardPresentation.quotaNoCapNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            quotaBlocks
        }
    }

    /// Every account's windows at once, one block each.
    ///
    /// The account switcher that used to sit here has gone. A tab hid whichever
    /// subscription you were not looking at, which is precisely what somebody
    /// with two of them needs on screen together. There is still no "all
    /// accounts" total: two subscriptions with separate five-hour limits do not
    /// have a combined one.
    ///
    /// Blocks stack rather than tile. An account reports two or three windows and
    /// those have to stay on one row — a grid over the flattened cards would wrap
    /// mid-account and put one subscription's weekly card under another's. Five
    /// accounts is therefore five rows in a pane that already scrolls, which is
    /// the vertical cost the switcher was buying and is no longer worth it.
    @ViewBuilder private var quotaBlocks: some View {
        if accountSummaries.isEmpty {
            EmptyStateBox(
                loadError
                    ?? "No accounts saved yet, so there is no quota to show. Add one under Accounts."
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(accountSummaries) { summary in
                    quotaBlock(for: summary)
                }
            }
        }
    }

    @ViewBuilder private func quotaBlock(for summary: AccountUsageSummary) -> some View {
        let name = summary.account.displayName
        // Matched by account id, never by position: this list and the quota
        // states are ordered independently, and attributing one subscription's
        // quota to another is the failure this app works hardest to avoid.
        let state = coordinator.quotaStates.first { $0.accountID == summary.account.id }

        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if let state {
                let cards = state.windows.compactMap {
                    QuotaCardModel.make(for: $0.window, now: Date())
                }

                if let message = state.message {
                    EmptyStateBox(message)
                } else if cards.isEmpty {
                    EmptyStateBox(QuotaIndicator.noQuotaReportedMessage)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(cards) { card in
                            QuotaCardView(card: card, accountName: name)
                        }
                    }
                }
            } else {
                EmptyStateBox("This account has not reported a quota yet.")
            }
        }
    }

    // MARK: Usage on this Mac

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                SectionTitle("Usage on this Mac")
                Text("""
                    read from the local transcripts — machine-wide, \
                    because a transcript file carries no account
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if coordinator.isScanningLocalUsage, breakdown == nil {
                ScanningRow()
            }

            if let message = coordinator.localScanFailureMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 14) {
                chartCard
                    .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    spendCard
                    agentsCard
                    modelMixCard
                    accountRingsCard
                }
                .frame(width: 300)
            }
        }
    }

    private var entries: [DailyUsageEntry] {
        guard let breakdown else { return [] }
        return DashboardPresentation.entries(of: breakdown.series, over: period.days)
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CardTitle("Daily Usage")
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(LocalUsagePeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            DailyUsageChart(
                entries: entries,
                legendLimit: Self.legendLimit,
                mix: breakdown?.mix,
                selectedDay: $selectedDay
            )
            .padding(.top, 12)

            DayDetailPanel(
                entry: detailEntry,
                isToday: detailEntry?.day == breakdown?.series.referenceDay
            )
            .padding(.top, 12)
        }
        .padding(16)
        .glassCard()
    }

    /// Defaults to today, so the space below the legend is never blank and
    /// today's breakdown costs nothing to ask for. A selected day the series has
    /// no entry for resolves to a zero day rather than to nothing at all.
    private var detailEntry: DailyUsageEntry? {
        let days = entries
        guard !days.isEmpty else { return nil }
        guard let selectedDay else {
            return days.first { $0.day == breakdown?.series.referenceDay } ?? days.last
        }
        return days.first { $0.day == selectedDay } ?? DashboardPresentation.zeroDay(selectedDay)
    }

    // MARK: Spend

    private var spendCard: some View {
        let summary = spendSeries.map {
            SpendSummary.make(for: spendPeriod, series: $0, medianDays: Self.medianDays)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CardTitle("Spend · this Mac")
                Spacer(minLength: 0)
                // A menu rather than segments: five periods across a 300-point
                // column would truncate every label to a letter or two.
                Picker("Period", selection: $spendPeriod) {
                    ForEach(SpendPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if let summary, !summary.isEmpty {
                Text(DashboardPresentation.amount(
                    micros: summary.amountMicros,
                    currency: summary.currency
                ))
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()

                Text("\(summary.totalTokens.formatted()) tokens")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(summary.comparison.text)
                    .font(.caption)
                    .foregroundStyle(
                        summary.comparison.isAbove.map { $0 ? Color.orange : Color.green }
                            ?? Color.secondary
                    )

                // Said out loud whenever the scan reaches back less far than the
                // period does, so a fortnight on a fresh install cannot pass for
                // a year.
                if let coverageText = summary.coverageText {
                    Text(coverageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(summary?.emptyText ?? "Nothing recorded on this Mac \(spendPeriod.windowPhrase).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: Agents

    private var agentsCard: some View {
        let cta = callToAction

        return VStack(alignment: .leading, spacing: 8) {
            CardTitle("Agents")

            if cta.isEmpty {
                Text("No Claude Code sessions on this Mac in the last few days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    AgentCountBox(count: cta.waiting, label: "waiting on you", isHot: cta.isUrgent)
                    AgentCountBox(count: cta.working, label: "working", isHot: false)
                    AgentCountBox(count: cta.resting, label: "resting", isHot: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: Model mix

    private var modelMixCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("Model Mix · \(period.title)")

            if let mix = breakdown?.mix, !mix.isEmpty {
                ForEach(mix.entries.prefix(Self.legendLimit)) { entry in
                    HStack(spacing: 8) {
                        Text(entry.model ?? DashboardPresentation.unknownModelLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(DashboardPresentation.amount(
                            micros: entry.estimatedAmountMicros,
                            currency: entry.currency
                        ))
                        .monospacedDigit()
                        .foregroundStyle(
                            entry.isUnpriced ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                        )
                        Text(entry.sharePercent.map { "\(Int($0.rounded())) %" } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.caption)
                }

                // Said out loud rather than left implicit: with an unpriced
                // model in the period, every share above is a share of what
                // could be priced, not of the whole spend.
                if mix.hasUnpricedModels {
                    Text(DashboardPresentation.unpricedShareNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No local token usage recorded for this period.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: Account rings

    private var accountRingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle("Accounts")

            if accountSummaries.isEmpty {
                Text("No accounts saved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.quotaBars) { group in
                    HStack(spacing: 11) {
                        // The first window an account reports is its shortest,
                        // which is the one that runs out first and the only one
                        // worth a ring this size.
                        UsageRing(remaining: group.rows.first?.remainingFraction)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.displayName)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(group.rows.first?.label ?? QuotaIndicator.noQuotaReportedMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalUsageStatistics.estimateDisclaimer)
            Text(DashboardPresentation.subscriptionScopeNote)
            if breakdown?.mix.hasUnpricedModels == true {
                Text(DashboardPresentation.unpricedTotalNote)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The chart

private struct DailyUsageChart: View {
    let entries: [DailyUsageEntry]
    let legendLimit: Int
    let mix: ModelMix?
    @Binding var selectedDay: Date?

    private static let plotHeight: CGFloat = 190

    var body: some View {
        if entries.isEmpty {
            EmptyStateBox("No local token usage recorded for this period.")
                .frame(height: Self.plotHeight)
        } else if entries.count == 1 {
            // One day is not a trend, and a single bar on a 30-day axis invites
            // the reader to see one. Say what there is instead.
            EmptyStateBox("""
                Only one day of usage has been recorded so far. \
                The chart starts telling you something once there are a few.
                """)
                .frame(height: Self.plotHeight)
        } else {
            chart
        }
    }

    private var slices: [DashboardPresentation.DayModelSlice] {
        let models = mix.map { DashboardPresentation.chartModels(from: $0, limit: legendLimit) } ?? []
        return DashboardPresentation.slices(for: entries, keeping: models)
    }

    private var chart: some View {
        Chart(slices) { slice in
            BarMark(
                x: .value("Day", slice.day, unit: .day),
                y: .value("Tokens", slice.tokens)
            )
            .foregroundStyle(by: .value("Model", slice.model))
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                if let day = value.as(Date.self) {
                    AxisValueLabel(day.formatted(.dateTime.day().month(.abbreviated)))
                }
            }
        }
        .frame(height: Self.plotHeight)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                select(at: location.x - rect.minX, proxy: proxy)
                            }
                        selectionOutline(rect: rect, proxy: proxy)
                    }
                }
            }
        }
    }

    /// The selected bar is outlined rather than recoloured: the colours already
    /// name models, and a seventh colour would compete with them.
    @ViewBuilder private func selectionOutline(rect: CGRect, proxy: ChartProxy) -> some View {
        if let day = selectedDay ?? entries.last?.day,
           let start = proxy.position(forX: day),
           let end = proxy.position(forX: day.addingTimeInterval(24 * 60 * 60)) {
            let width = max(end - start, 3)
            RoundedRectangle(cornerRadius: 4)
                .stroke(.primary.opacity(0.55), lineWidth: 1.5)
                .frame(width: width + 2, height: rect.height + 4)
                .position(x: rect.minX + start + width / 2, y: rect.minY + rect.height / 2)
                .allowsHitTesting(false)
        }
    }

    /// Snaps to the nearest day the series actually has, so a tap in the gutter
    /// between two bars still selects one of them.
    private func select(at x: CGFloat, proxy: ChartProxy) {
        guard let tapped: Date = proxy.value(atX: x) else { return }
        let nearest = entries.min {
            abs($0.day.timeIntervalSince(tapped)) < abs($1.day.timeIntervalSince(tapped))
        }
        selectedDay = nearest?.day
    }
}

// MARK: - The day detail

/// The day beneath the legend.
///
/// It costs no height: the card was already this tall and the space under the
/// legend was empty. The frame is fixed for that reason — a day with more models
/// than fit has its list cut rather than the card grown.
private struct DayDetailPanel: View {
    let entry: DailyUsageEntry?
    let isToday: Bool

    /// As many rows as the space that was already there holds, in two columns.
    private static let rowLimit = 6
    private static let height: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if let entry {
                head(entry)
                rows(entry)
            } else {
                Text("Pick a day in the chart to see which models ran on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(height: Self.height, alignment: .top)
        .clipped()
    }

    private func head(_ entry: DailyUsageEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.callout.weight(.semibold))
            if isToday {
                Text("today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("""
                \(entry.totalTokens.formatted()) tokens · \
                \(DashboardPresentation.amount(
                    micros: entry.estimatedAmountMicros,
                    currency: entry.currency
                ))
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder private func rows(_ entry: DailyUsageEntry) -> some View {
        if entry.isEmpty {
            // A day with no rows is a zero day, not a missing one. Saying so is
            // the difference between "you did not work" and "we lost the data".
            Text("Nothing was recorded on this day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // Ranked by volume, as the reference has it: this panel answers
            // "what ran", where the mix card answers "what cost".
            let ranked = Array(
                entry.statistics.models
                    .sorted { $0.totalTokens > $1.totalTokens }
                    .prefix(Self.rowLimit)
            )
            let peak = ranked.first?.totalTokens ?? 0

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)],
                alignment: .leading,
                spacing: 5
            ) {
                ForEach(ranked) { model in
                    HStack(spacing: 8) {
                        Text(model.model ?? DashboardPresentation.unknownModelLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        ProportionBar(
                            fraction: peak > 0 ? Double(model.totalTokens) / Double(peak) : 0
                        )
                        Text(model.totalTokens.formatted())
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct ProportionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(width: 46, height: 4)
    }
}

// MARK: - The quota card

private struct QuotaCardView: View {
    let card: QuotaCardModel
    /// Which subscription this window belongs to. Not optional: with every
    /// account on screen at once there is no longer a tab making that obvious,
    /// so no card is allowed to render without saying whose it is.
    let accountName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(DashboardPresentation.quotaCardTitle(window: card.title, account: accountName))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(card.headroomPercent)")
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                Text("% free")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                // Percentages and nothing else: `RateWindow` reports a consumed
                // fraction and carries no token cap, so the reference's
                // "12.4M / 19.8M" would be a figure this app invented.
                Text(card.usageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.top, 8)

            QuotaBar(card: card)
                .padding(.vertical, 10)

            HStack(spacing: 7) {
                Circle()
                    .fill(card.state.tint)
                    .frame(width: 7, height: 7)
                Text(card.paceText ?? card.headroomText)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}

/// The bar and its pace marker. The marker is the point of the card: "63 % used"
/// says nothing on its own, "63 % used and an even burn would have you at 40 %"
/// says stop.
private struct QuotaBar: View {
    let card: QuotaCardModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(card.state.tint)
                    .frame(width: geometry.size.width * card.usedFraction)

                if let pace = card.pacePosition {
                    Capsule()
                        .fill(.primary.opacity(0.65))
                        .frame(width: 2, height: 15)
                        .offset(x: geometry.size.width * pace - 1, y: -3)
                }
            }
        }
        .frame(height: 9)
    }
}

private extension QuotaCardState {
    var tint: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .spent: .red
        }
    }
}

// MARK: - The call to action

/// Amber with a slow pulse when agents are waiting, matching the plumbob over a
/// waiting agent's head so both surfaces speak one language. Neutral, unlit and
/// still when nobody is: a dashboard that always looks urgent stops meaning
/// anything.
private struct AgentverseCallToActionButton: View {
    let model: DashboardPresentation.AgentverseCallToAction
    let action: () -> Void

    @State private var isPulsing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ring
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.headline)
                        .font(.callout.weight(.semibold))
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .glassCard(cornerRadius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(model.isUrgent ? Color.orange.opacity(0.55) : Color.clear)
            )
            .shadow(color: model.isUrgent ? .orange.opacity(0.28) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
        .help("Open the Agentverse in its own window")
        .accessibilityLabel("\(model.headline). \(model.detail)")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .fill(model.isUrgent ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.10))
            Circle()
                .strokeBorder(model.isUrgent ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.25))

            if model.isUrgent {
                Circle()
                    .strokeBorder(Color.orange.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(isPulsing ? 1.42 : 1)
                    .opacity(isPulsing ? 0 : 0.85)
                    // 2.2 s, the same unhurried period the plumbob keeps. A
                    // faster pulse reads as an alarm rather than as a nudge.
                    .animation(
                        .easeOut(duration: 2.2).repeatForever(autoreverses: false),
                        value: isPulsing
                    )
            }

            Text("\(model.waiting)")
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(model.isUrgent ? Color.orange : Color.secondary)
        }
        .frame(width: 38, height: 38)
        .onAppear { isPulsing = model.isUrgent }
        .onChange(of: model.isUrgent) { _, urgent in isPulsing = urgent }
    }
}

// MARK: - Small parts

private struct AgentCountBox: View {
    let count: Int
    let label: String
    let isHot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)")
                .font(.system(size: 23, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isHot ? Color.orange : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            isHot
                ? AnyShapeStyle(Color.orange.opacity(0.16))
                : AnyShapeStyle(.quaternary.opacity(0.4)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }
}

private struct UsageRing: View {
    /// Nil when the provider reported no consumed fraction. The ring then shows
    /// no arc at all rather than a full or an empty one, both of which would be
    /// confident and wrong.
    let remaining: Double?

    var body: some View {
        ZStack {
            Circle().strokeBorder(.quaternary, lineWidth: 4)
            if let used {
                Circle()
                    .trim(from: 0, to: used)
                    .stroke(
                        used > 0.6 ? Color.orange : Color.green,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            Text(used.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .frame(width: 36, height: 36)
    }

    private var used: Double? {
        remaining.map { min(max(1 - $0, 0), 1) }
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}

private struct CardTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.7)
            .foregroundStyle(.secondary)
    }
}

private struct ScanningRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning local transcripts…")
                .foregroundStyle(.secondary)
        }
    }
}

/// An empty state that reads as a sentence rather than as an empty box. Every one
/// of them says what is missing, because a blank panel only ever says "broken".
private struct EmptyStateBox: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .glassCard()
    }
}

private extension View {
    /// The reference's glass, taken from the system rather than rebuilt out of
    /// gradients. A material tracks the desktop behind the window, follows the
    /// appearance and honours Reduce Transparency; a hand-mixed white-on-white
    /// gradient does none of those and reads as a web page in a window.
    func glassCard(cornerRadius: CGFloat = 15) -> some View {
        background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6))
        )
    }
}
