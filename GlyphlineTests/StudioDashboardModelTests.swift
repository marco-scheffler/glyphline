import XCTest
@testable import Glyphline

/// The Studio's tile row: which figures it shows, where they come from, and
/// what it says when there is nothing to show.
final class StudioDashboardModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func weekly(_ used: Double, model: String? = nil) -> QuotaWindowState {
        QuotaWindowState(window: RateWindow(kind: .weekly, usedFraction: used,
                                            resetAt: now.addingTimeInterval(3 * 86_400),
                                            observedAt: now, model: model))
    }

    private func fiveHour(_ used: Double) -> QuotaWindowState {
        QuotaWindowState(window: RateWindow(kind: .rollingFiveHours, usedFraction: used,
                                            resetAt: now.addingTimeInterval(3_600),
                                            observedAt: now))
    }

    private func account(_ name: String, _ windows: [QuotaWindowState],
                         message: String? = nil) -> QuotaAccountState {
        QuotaAccountState(accountID: UUID(), displayName: name, windows: windows, message: message)
    }

    private func series(tokens: [Int64]) -> DailyUsageSeries {
        let end = calendar.startOfDay(for: now)
        let entries = tokens.enumerated().map { offset, count -> DailyUsageEntry in
            let date = calendar.date(byAdding: .day, value: -(tokens.count - 1 - offset), to: end)!
            return DailyUsageEntry(
                day: date,
                statistics: LocalUsageStatistics(
                    models: [LocalModelUsageStatistic(model: "claude-sonnet-5", inputTokens: count,
                                                      cacheCreationTokens: 0, cacheReadTokens: 0,
                                                      outputTokens: 0, estimatedAmountMicros: count * 3,
                                                      currency: "USD")],
                    estimatedAmountMicros: count * 3,
                    currency: "USD"
                )
            )
        }
        return DailyUsageSeries(entries: entries,
                                total: LocalUsageStatistics(models: [], estimatedAmountMicros: nil, currency: nil),
                                referenceDay: end)
    }

    private func session(_ id: String, subagents: Int) -> AgentSession {
        AgentSession(id: id, cwd: "/repo/\(id)", gitBranch: "main", activity: .working,
                     lastActivityAt: now, subagentCount: subagents)
    }

    func testTheTightestWeeklyWindowWins() throws {
        let states = [
            account("Work", [weekly(0.4), fiveHour(0.9)]),
            account("Home", [weekly(0.63, model: "Fable")]),
        ]
        let tightest = try XCTUnwrap(StudioDashboardModel.tightestWeekly(states, now: now))
        XCTAssertEqual(tightest.account, "Home")
        XCTAssertEqual(tightest.card.usedPercent, 63)

        let tile = try XCTUnwrap(StudioDashboardModel.tiles(onTrack: [], series: nil,
                                                            quotaStates: states, now: now).last)
        let caption = try XCTUnwrap(tile.caption)
        XCTAssertTrue(caption.contains("Home"))
        XCTAssertTrue(caption.contains(RateWindowID(kind: .weekly, model: "Fable").longName))
        XCTAssertEqual(tile.bar ?? .nan, 0.63, accuracy: 0.000_001)
    }

    /// Its windows are not shown on the dashboard either.
    func testAnAccountWithAMessageIsSkipped() throws {
        let states = [
            account("Broken", [weekly(0.95)], message: "Sign in again"),
            account("Fine", [weekly(0.2)]),
        ]
        let tightest = try XCTUnwrap(StudioDashboardModel.tightestWeekly(states, now: now))
        XCTAssertEqual(tightest.account, "Fine")
    }

    func testNoWeeklyWindowDropsTheTile() {
        let tiles = StudioDashboardModel.tiles(onTrack: [], series: series(tokens: [1, 2]),
                                               quotaStates: [account("Work", [fiveHour(0.5)])], now: now)
        XCTAssertEqual(tiles.count, 3)
    }

    func testMissingDataIsADashNeverZero() {
        let tiles = StudioDashboardModel.tiles(onTrack: [], series: nil, quotaStates: [], now: now)
        XCTAssertEqual(tiles[0].value, "—")
        XCTAssertEqual(tiles[1].value, "—")
    }

    func testCostTodayMatchesTheDashboard() {
        let s = series(tokens: [10, 20, 30, 40, 50, 60, 70, 80_000])
        let summary = SpendSummary.make(for: .day, series: s)
        let tiles = StudioDashboardModel.tiles(onTrack: [], series: s, quotaStates: [], now: now)
        XCTAssertEqual(tiles[1].value,
                       DashboardPresentation.amount(micros: summary.amountMicros, currency: summary.currency))
        XCTAssertEqual(tiles[0].value, Int64(80_000).formatted(.number.notation(.compactName)))
        XCTAssertEqual(tiles[0].sparkline, [20, 30, 40, 50, 60, 70, 80_000])
    }

    func testSubagentsSumAcrossSessions() {
        let tiles = StudioDashboardModel.tiles(
            onTrack: [session("a", subagents: 2), session("b", subagents: 0), session("c", subagents: 3)],
            series: nil, quotaStates: [], now: now
        )
        XCTAssertEqual(tiles[2].value, 5.formatted())
        XCTAssertEqual(tiles[2].caption, String(localized: "in \(2) sessions",
                                                comment: "Subagents tile caption."))
    }
}
