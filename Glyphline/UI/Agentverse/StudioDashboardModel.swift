import Foundation

/// One tile in the Studio's top row.
struct StudioTile: Equatable, Sendable {
    let title: String
    let value: String
    let caption: String?
    let sparkline: [Double]
    let bar: Double?
}

/// What the Studio's tiles and feed say.
///
/// Every figure is one the dashboard already computes, read through the
/// dashboard's own models: the Studio frames numbers, it does not invent them.
enum StudioDashboardModel {
    static let medianDays = 7
    static let noData = "—"

    /// How far back the tiles read the ledger: the median's completed days,
    /// the sparkline's week and today, with room to spare.
    static func seriesStart(now: Date = Date(), calendar: Calendar = LocalUsageDay.calendar) -> Date? {
        calendar.date(byAdding: .day, value: -(medianDays + 7), to: calendar.startOfDay(for: now))
    }

    static func tiles(onTrack: [AgentSession], series: DailyUsageSeries?,
                      quotaStates: [QuotaAccountState], now: Date) -> [StudioTile] {
        var tiles = [tokensToday(series), costToday(series), subagents(onTrack)]
        if let weekly = tightestWeekly(quotaStates, now: now) {
            let name = "\(weekly.account) · \(weekly.card.window.longName)"
            tiles.append(StudioTile(
                title: String(localized: "Weekly limit",
                              comment: "Studio tile title over the weekly quota window closest to its limit. Drawn in capitals; keep it short."),
                value: (Double(weekly.card.usedPercent) / 100).formatted(.percent),
                caption: weekly.card.resetText.map { "\(name) · \($0)" } ?? name,
                sparkline: [],
                bar: weekly.card.usedFraction
            ))
        }
        return tiles
    }

    /// Of every weekly window on an account the dashboard shows windows for,
    /// the one closest to its limit. Ties go to the first in account order.
    static func tightestWeekly(_ states: [QuotaAccountState],
                               now: Date) -> (account: String, card: QuotaCardModel)? {
        var best: (account: String, card: QuotaCardModel)?
        for state in states where state.message == nil {
            for windowState in state.windows where windowState.window.kind == .weekly {
                guard let card = QuotaCardModel.make(for: windowState.window, now: now) else { continue }
                if best == nil || card.usedFraction > best!.card.usedFraction {
                    best = (state.displayName, card)
                }
            }
        }
        return best
    }

    /// The feed's words for what changed.
    static func changeText(_ change: StudioActivityLog.Change) -> String {
        switch change {
        case .action(let action):
            action.text
        case .startedWaiting:
            String(localized: "Started waiting for you",
                   comment: "Studio feed line: a session stopped and now waits for the user's answer. Keep it short.")
        case .resumed:
            String(localized: "Back at work",
                   comment: "Studio feed line: a session that was waiting for the user is working again. Keep it short.")
        }
    }

    private static func tokensToday(_ series: DailyUsageSeries?) -> StudioTile {
        let title = String(localized: "Tokens today",
                           comment: "Studio tile title over today's token count. Drawn in capitals; keep it short.")
        guard let series else {
            return StudioTile(title: title, value: noData, caption: nil, sparkline: [], bar: nil)
        }
        let today = series.today?.totalTokens ?? 0
        let comparison = DashboardPresentation.todayVersusMedian(
            todayTokens: today, median: series.median(days: medianDays), days: medianDays
        )
        let recent = series.entries.filter { $0.day <= series.referenceDay }.suffix(7)
        return StudioTile(title: title,
                          value: today.formatted(.number.notation(.compactName)),
                          caption: comparison.text,
                          sparkline: recent.map { Double($0.totalTokens) },
                          bar: nil)
    }

    private static func costToday(_ series: DailyUsageSeries?) -> StudioTile {
        let title = String(localized: "Cost today",
                           comment: "Studio tile title over today's estimated spend. Drawn in capitals; keep it short.")
        guard let series else {
            return StudioTile(title: title, value: noData, caption: nil, sparkline: [], bar: nil)
        }
        let summary = SpendSummary.make(for: .day, series: series, medianDays: medianDays)
        guard !summary.isEmpty, summary.amountMicros != nil else {
            return StudioTile(title: title, value: noData, caption: summary.emptyText, sparkline: [], bar: nil)
        }
        return StudioTile(title: title,
                          value: DashboardPresentation.amount(micros: summary.amountMicros,
                                                              currency: summary.currency),
                          caption: summary.coverageText,
                          sparkline: [],
                          bar: nil)
    }

    private static func subagents(_ sessions: [AgentSession]) -> StudioTile {
        let total = sessions.reduce(0) { $0 + $1.subagentCount }
        let carrying = sessions.filter { $0.subagentCount > 0 }.count
        return StudioTile(
            title: String(localized: "Subagents",
                          comment: "Studio tile title over the number of subagents the running sessions have started. Drawn in capitals; keep it short."),
            value: total.formatted(),
            caption: carrying > 0
                ? String(localized: "in \(carrying) sessions",
                         comment: "Subagents tile caption. The placeholder is how many running sessions have subagents.")
                : nil,
            sparkline: [],
            bar: nil
        )
    }
}
