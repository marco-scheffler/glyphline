import SwiftUI

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
            SectionTitle(String(localized: "Quotas", comment: "Section heading over the per-account quota cards. Drawn in capitals; keep it to one short word."))

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
                SectionTitle(String(localized: "Usage on this Mac", comment: "Section heading over the local-transcript figures, as opposed to the figures the provider reports. Drawn in capitals; keep it short."))
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
                CardTitle(String(localized: "Daily Usage", comment: "Card heading over the per-day usage chart. Drawn in capitals; keep it to two short words."))
                Spacer()
                ChartPeriodPicker(period: $period)
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
                CardTitle(String(localized: "Spend · this Mac", comment: "Card heading over the money figure, which counts only what was run on this computer. Drawn in capitals; keep it short. The · is a separator and stays."))
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
                Text(summary?.emptyText ?? spendPeriod.emptySpendText)
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
                    CardTitle(String(localized: "Agents", comment: "Card heading over the count of coding agents running on this Mac. Drawn in capitals; keep it to one short word."))
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
                        AgentCountBox(count: cta.waiting, label: String(localized: "waiting on you", comment: "Caption under a count of coding agents that have stopped and need the user to answer them. Lower case, and narrow — three small boxes share one row."), isHot: cta.isUrgent)
                        AgentCountBox(count: cta.working, label: String(localized: "working", comment: "Agent state: this coding agent is busy running. Shown both as a small pill beside a row and as the caption under a count. Lower case, one short word — the space is narrow in both places."), isHot: false)
                        AgentCountBox(count: cta.resting, label: String(localized: "resting", comment: "Caption under a count of coding agents whose sessions are idle — open, but neither running nor asking anything of the user. Lower case, and narrow — three small boxes share one row."), isHot: false)
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
            CardTitle(String(localized: "Model Mix · \(period.title)", comment: "Card heading over the share each model took of the spend. Drawn in capitals. The placeholder is the selected period, e.g. 'Week'. The · is a separator and stays."))

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
