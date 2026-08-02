import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var accountSummaries: [AccountUsageSummary] = []
    @State private var loadError: String?

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

/// What the dashboard says when an account is failing or signed out.
///
/// The condition for moving Accounts into settings at all. Accounts is where you
/// go when something is broken — an expired token, a failing sync — and burying
/// that a level deeper without saying anything here would have made the app
/// worse, not tidier.
///
/// `SettingsLink` opens the settings window; it cannot pre-select the Accounts
/// tab, so the user still picks it. That is one click, against no signal at all.
private struct AccountAttentionBanner: View {
    let items: [DashboardPresentation.AccountAttention]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(
                    DashboardPresentation.attentionHeadline(count: items.count),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Spacer(minLength: 12)

                SettingsLink {
                    Text("Open Settings")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Every account named, not just a count. Two subscriptions and one
            // expired sign-in is a different situation from two expired ones,
            // and a headline alone cannot tell them apart.
            ForEach(items) { item in
                Text("\(item.accountName) — \(item.reason)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - The overview

/// How a summary tile says what height it was given, for the one caller that
/// needs to know: the height probe.
///
/// It has to be reported from inside the row and cannot be measured from
/// outside. The tiles read the coordinators out of the environment, so they only
/// exist once the overview is in a hierarchy, and SwiftUI gives a laid-out
/// subview no `NSView` of its own to measure — two of the three glass cards
/// happen to get a backing view and the third does not.
///
/// Nil everywhere but in the probe, and the row adds nothing at all when it is
/// nil.
private struct SummaryTileHeightReportKey: EnvironmentKey {
    static let defaultValue: (@Sendable (Int, CGFloat) -> Void)? = nil
}

extension EnvironmentValues {
    var summaryTileHeightReport: (@Sendable (Int, CGFloat) -> Void)? {
        get { self[SummaryTileHeightReportKey.self] }
        set { self[SummaryTileHeightReportKey.self] = newValue }
    }
}

private struct SummaryTileHeightReporter: ViewModifier {
    let index: Int
    @Environment(\.summaryTileHeightReport) private var report

    func body(content: Content) -> some View {
        if let report {
            content.background(
                GeometryReader { proxy in
                    // Reported from the reader's own body rather than through a
                    // preference: the probe lays the row out with
                    // `layoutSubtreeIfNeeded` and never runs a render loop, so
                    // there is no later pass in which a preference would arrive.
                    report(index, proxy.size.height)
                    return Color.clear
                }
            )
        } else {
            content
        }
    }
}

/// Not private, so the height probe can measure the real tiles rather than a
/// rebuilt likeness of them.
struct DashboardOverview: View {
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

                // Above the sync failure and above everything else. Accounts is
                // a level deeper now that it is a settings tab, and the reason
                // to go there is urgent and rare — the worst combination to
                // bury. So the dashboard says it, and offers the way.
                if !attention.isEmpty {
                    AccountAttentionBanner(items: attention)
                }

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
                // The plural is two whole keys rather than an interpolated "s".
                // As one key it extracts as "%lld account%@" — a translator is
                // handed an English suffix in a placeholder and can do nothing
                // useful with it, and no language that inflects the noun could
                // be served by it at all.
                Text(accountSummaries.isEmpty
                    ? "No accounts saved yet"
                    : (accountSummaries.count == 1
                        ? "1 account"
                        : "\(accountSummaries.count) accounts"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
    }

    /// Built from the coordinator's per-account quota reasons and each account's
    /// own last sync run — no new state, and no threshold decided in the view.
    private var attention: [DashboardPresentation.AccountAttention] {
        DashboardPresentation.accountsNeedingAttention(
            summaries: accountSummaries,
            quotaGroups: coordinator.quotaBars
        )
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

    /// Every account's windows at once, one card each.
    ///
    /// The account switcher that used to sit here has gone. A tab hid whichever
    /// subscription you were not looking at, which is precisely what somebody
    /// with two of them needs on screen together. There is still no "all
    /// accounts" total: two subscriptions with separate five-hour limits do not
    /// have a combined one.
    ///
    /// One card per account with its windows stacked inside, rather than a card
    /// per window: an account reporting a five-hour and a weekly window used to
    /// cost two cards, so five accounts meant ten. Halving that is the whole
    /// point of the shape.
    ///
    /// The cards tile into a grid that fills the row rather than a single
    /// column. Two accounts sit side by side in the pane's width and five wrap
    /// to as many rows as the width allows, so growing the account count costs
    /// height only once the horizontal room is actually used up.
    @ViewBuilder private var quotaBlocks: some View {
        if accountSummaries.isEmpty {
            EmptyStateBox(
                loadError
                    ?? "No accounts saved yet, so there is no quota to show. Add one in Settings."
            )
        } else {
            AccountQuotaGrid(accounts: accountSummaries.map(quotaBlock(for:)))
        }
    }

    private func quotaBlock(for summary: AccountUsageSummary) -> AccountQuotaCardModel {
        // Matched by account id, never by position: this list and the quota
        // states are ordered independently, and attributing one subscription's
        // quota to another is the failure this app works hardest to avoid.
        let state = coordinator.quotaStates.first { $0.accountID == summary.account.id }

        return DashboardPresentation.accountQuotaCard(
            summary: summary,
            state: state,
            now: Date()
        )
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

            // The chart is the only element here that gains anything from
            // width — thirty stacked bars and a day detail beneath them — so it
            // gets the whole row. The three summary tiles read the same at a
            // third of the width as they did in a 300-point column.
            // `fixedSize` is load-bearing, not redundant: this row lives in a
            // ScrollView, which proposes nil height, so the cards'
            // `maxHeight: .infinity` would have nothing finite to fill and the
            // row would keep its ragged bottom edge. Fixing the vertical axis
            // makes the stack take its own ideal height — the tallest card —
            // and the others then stretch to it. It also stops the row from
            // claiming the chart's vertical space.
            HStack(alignment: .top, spacing: 14) {
                spendCard.modifier(SummaryTileHeightReporter(index: 0))
                agentsCard.modifier(SummaryTileHeightReporter(index: 1))
                modelMixCard.modifier(SummaryTileHeightReporter(index: 2))
            }
            .fixedSize(horizontal: false, vertical: true)

            chartCard
                .frame(maxWidth: .infinity)
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
        // The slack from equalising goes below the content, not around it:
        // top-leading keeps the big spend figure on the same line as the other
        // cards' first row instead of floating it mid-card.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .glassCard()
    }

    // MARK: Agents

    /// The whole tile is the way into the Agentverse.
    ///
    /// The header used to carry a separate call to action counting the same
    /// three numbers this tile boxes up; one fact on two surfaces is one too
    /// many, so the tile took the click and the header went back to its title.
    /// The call to action's plain-language line came with it: three numbered
    /// boxes do not read at a glance the way "1 agent is waiting on you" does.
    ///
    /// Amber and outlined only while somebody is waiting, matching the waiting
    /// box and the plumbob over a waiting agent's head. Quiet otherwise: a
    /// dashboard that always looks urgent stops meaning anything.
    private var agentsCard: some View {
        let cta = callToAction

        return Button(action: openAgentverse) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CardTitle("Agents")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                if cta.isEmpty {
                    Text("No Claude Code sessions on this Mac in the last few days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(cta.headline)
                        .font(.callout.weight(cta.isUrgent ? .semibold : .regular))
                        .foregroundStyle(cta.isUrgent ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        AgentCountBox(count: cta.waiting, label: "waiting on you", isHot: cta.isUrgent)
                        AgentCountBox(count: cta.working, label: "working", isHot: false)
                        AgentCountBox(count: cta.resting, label: "resting", isHot: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .glassCard()
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(cta.isUrgent ? Color.orange.opacity(0.55) : Color.clear)
            )
            .shadow(color: cta.isUrgent ? .orange.opacity(0.28) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
        .help("Open the Agentverse in its own window")
        .accessibilityLabel("Agents. \(cta.headline)")
    }

    // MARK: Model mix

    private var modelMixCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("Model Mix · \(period.title)")

            if let mix = breakdown?.mix, !mix.isEmpty {
                ForEach(mix.entries.prefix(Self.legendLimit)) { entry in
                    HStack(spacing: 8) {
                        ModelSwatch(identifier: entry.model)
                        Text(entry.model.map(DashboardPresentation.modelDisplayName)
                            ?? DashboardPresentation.unknownModelLabel)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// The day the detail panel is describing: the tapped one, or the last day
    /// when nothing has been tapped yet.
    private var highlightedDay: Date? {
        selectedDay ?? entries.last?.day
    }

    private var chart: some View {
        let slices = self.slices
        let scale = DashboardPresentation.chartStyleScale(for: slices)
        let highlighted = highlightedDay

        return Chart(slices) { slice in
            BarMark(
                x: .value("Day", slice.day, unit: .day),
                y: .value("Tokens", slice.tokens)
            )
            // The series key is the legend's text, so it is the model's name and
            // not its identifier. Nobody reads a bill in `claude-opus-4-8`.
            .foregroundStyle(by: .value("Model", DashboardPresentation.modelDisplayName(slice.model)))
            // The unselected days are dimmed rather than the selected one
            // brightened: the palette is already saturated, and lightening a
            // pink or a purple towards white costs exactly the generation
            // difference the scheme encodes. Opacity only — a bar's geometry
            // must not move when the selection does.
            .opacity(highlighted == nil || slice.day == highlighted ? 1 : 0.55)
        }
        // The chart's colours are the app's, not Swift Charts' defaults: the
        // hue names the model family everywhere it appears.
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        // Marked at bar centres, not at bar starts. A `unit: .day` bar is drawn
        // forward from its own date, so a mark at that date labels the bar's
        // leading edge and the reader reads every label one half-bar too far
        // left. The centre is noon of the same day, so it still formats as that
        // day.
        .chartXAxis {
            AxisMarks(values: Self.axisMarks(for: entries)) { value in
                AxisGridLine()
                if let day = value.as(Date.self) {
                    AxisValueLabel(DashboardPresentation.axisDayLabel(of: day))
                }
            }
        }
        // The days are UTC day starts (see `DailyUsageSeries`). Charts would bin
        // them by the local calendar instead, putting every bar a timezone
        // offset away from the day it stands for — and away from the marks and
        // the hit test below, which reason in the same UTC days the data has.
        .environment(\.calendar, LocalUsagePeriod.utcCalendar)
        .frame(height: Self.plotHeight)
        // The band is drawn in the chart's *background*, so it sits behind the
        // bars instead of veiling them. The tap target stays an overlay,
        // because a background cannot receive the gesture.
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    selectionBand(rect: geometry[plotFrame], proxy: proxy)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            select(at: location.x - rect.minX, proxy: proxy)
                        }
                }
            }
        }
    }

    /// The selected column's soft, borderless band, full plot height.
    ///
    /// The stroked box this replaces was taller than its bar and so framed a
    /// column of empty air, with a corner radius that matched nothing else on
    /// the page — it read as a stray container rather than as a selection. A
    /// band behind the column is the bar chart's own idiom: it says "this
    /// column" without drawing an edge anywhere the data has none.
    ///
    /// It is laid out from the plot rect and the day's own x positions, so
    /// moving the selection changes neither the bars' widths nor anything's
    /// position.
    @ViewBuilder private func selectionBand(rect: CGRect, proxy: ChartProxy) -> some View {
        if let day = highlightedDay,
           let start = proxy.position(forX: day),
           let end = proxy.position(forX: DashboardPresentation.barEnd(of: day)) {
            let width = max(end - start, 3)
            Rectangle()
                .fill(.primary.opacity(0.09))
                .frame(width: width, height: rect.height)
                .position(x: rect.minX + start + width / 2, y: rect.minY + rect.height / 2)
                .allowsHitTesting(false)
        }
    }

    /// Where the axis is labelled: at most six of the series' own days, each
    /// moved to its bar's centre.
    private static func axisMarks(for entries: [DailyUsageEntry]) -> [Date] {
        DashboardPresentation
            .axisDays(for: entries.map(\.day), desiredCount: 6)
            .map { DashboardPresentation.barCentre(of: $0) }
    }

    /// Selects the bar the tap landed in, snapping to the nearest bar when it
    /// landed in a gutter. The mapping lives in `DashboardPresentation` because
    /// it is the half-bar offset this chart used to get wrong, and it is worth a
    /// test that a closure in here cannot have.
    private func select(at x: CGFloat, proxy: ChartProxy) {
        guard let tapped: Date = proxy.value(atX: x) else { return }
        if let day = DashboardPresentation.day(atChartValue: tapped, among: entries.map(\.day)) {
            selectedDay = day
        }
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
            Text(DashboardPresentation.dayTitle(of: entry.day))
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
                        ModelSwatch(identifier: model.model)
                        Text(model.model.map(DashboardPresentation.modelDisplayName)
                            ?? DashboardPresentation.unknownModelLabel)
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

/// A model's colour, beside its name. The same colour the chart draws it in —
/// that is the whole point of the swatch: it is what lets a reader carry a hue
/// from a bar down to the row that names it.
private struct ModelSwatch: View {
    let identifier: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            // A nil identifier is the same unknown the label calls "Unknown
            // model", and gets the same grey.
            .fill(DashboardPresentation.modelColor(identifier ?? ""))
            .frame(width: 8, height: 8)
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

/// One account's quota: its name at the top, every window it reports stacked
/// beneath.
///
/// The name is a stored property with no default and no optional, so this card
/// cannot be built without it. That is what keeps an account unambiguous now
/// that the window rows no longer repeat it — the compiler, rather than a
/// convention each call site has to remember.
struct AccountQuotaCardModel: Identifiable, Equatable {
    var id: UUID
    var accountName: String
    var providerName: String
    var cards: [QuotaCardModel]
    /// Why there are no windows to draw, when there are none. Rendered inside
    /// the card rather than in place of it: an account that reports nothing is
    /// still an account, and dropping its card would make it look unconfigured.
    var message: String?
}

/// The account cards, filling the row and sharing its width evenly.
///
/// A `LazyVGrid` of adaptive columns stood here. It reflows, but its cells size
/// themselves, so three accounts with unequal amounts to say came out ragged —
/// and a spent weekly window renders a different number of lines from one at
/// 100 %, so ragged was the normal case rather than the unlucky one.
///
/// This is instead the same shape the summary tiles use: a row is an `HStack` of
/// cards that each claim `maxWidth: .infinity` (even widths) and
/// `maxHeight: .infinity` (the row's height, so the shortest card's glass still
/// reaches the bottom edge), fixed on the vertical axis because the enclosing
/// `ScrollView` proposes nil height and an unbounded `maxHeight` would otherwise
/// have nothing finite to fill.
///
/// `ViewThatFits` picks how many columns the pane can carry: each candidate row
/// is as many cards wide as it says, and a card will not go below
/// `minimumCardWidth`, so the widest candidate that still fits wins. That is
/// what makes the layout answer both questions at once — a narrower window and
/// a fourth account reflow by the same rule.
struct AccountQuotaGrid: View {
    let accounts: [AccountQuotaCardModel]

    /// Below this a card's headroom figure and its pace sentence stop fitting on
    /// their own lines. It is the same 300 the adaptive grid used.
    static let minimumCardWidth: CGFloat = 300
    static let spacing: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.columnCandidates(accountCount: accounts.count), id: \.self) { columns in
                grid(columns: columns)
            }
        }
    }

    /// The column counts to try, widest first: never more columns than there are
    /// accounts, and never fewer than one — a single column always "fits",
    /// because `ViewThatFits` falls back to its last candidate regardless.
    static func columnCandidates(accountCount: Int) -> [Int] {
        guard accountCount > 1 else { return [1] }
        return Array((1...accountCount).reversed())
    }

    /// The accounts split into rows of at most `columns`.
    static func rows(of accounts: [AccountQuotaCardModel], columns: Int) -> [[AccountQuotaCardModel]] {
        let width = max(columns, 1)
        return stride(from: 0, to: accounts.count, by: width).map {
            Array(accounts[$0..<min($0 + width, accounts.count)])
        }
    }

    private func grid(columns: Int) -> some View {
        VStack(spacing: Self.spacing) {
            ForEach(Self.rows(of: accounts, columns: columns), id: \.first?.id) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row) { account in
                        AccountQuotaCard(model: account)
                    }
                    // A short last row keeps the column widths of the rows above
                    // it instead of stretching two cards across three columns.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AccountQuotaCard: View {
    let model: AccountQuotaCardModel

    private var accountName: String { model.accountName }
    private var providerName: String { model.providerName }
    private var cards: [QuotaCardModel] { model.cards }
    private var message: String? { model.message }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(accountName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(cards) { card in
                    QuotaWindowRow(card: card)
                }
            }

            // The slack from equalising a row's heights goes below the content,
            // as it does in the summary tiles: an account with one window keeps
            // its figures on the same lines as the account beside it with two.
            Spacer(minLength: 0)
        }
        .frame(
            minWidth: AccountQuotaGrid.minimumCardWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(16)
        .glassCard()
    }
}

/// One window inside its account's card: headroom, bar with pace marker, pace
/// sentence.
private struct QuotaWindowRow: View {
    let card: QuotaCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(DashboardPresentation.quotaWindowLabel(for: card.kind))
                .lineLimit(1)

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
    /// Liquid Glass itself, not an approximation of it. A material plus a
    /// drawn separator stroke is flat: it blurs but does not refract, it does
    /// not react to the window moving, and its edge is a line we chose rather
    /// than the one the system lights. `glassEffect` brings all three, and it
    /// draws its own border — hence no `strokeBorder` here any more.
    ///
    /// This is why the deployment target is macOS 26: the effect has no
    /// back-deployment and the layered-gradient stand-in it replaces looked
    /// wrong next to the system chrome that now uses the real thing.
    func glassCard(cornerRadius: CGFloat = 15) -> some View {
        glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
