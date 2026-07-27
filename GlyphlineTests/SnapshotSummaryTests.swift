import XCTest
@testable import Glyphline

final class SnapshotSummaryTests: XCTestCase {
    func testDailySummariesAggregateUsageAndEstimateSnapshotsByUTCDay() throws {
        let store = try makeStore()
        let account = makeAccount()
        let day = makeUTCDate(year: 2026, month: 7, day: 24, hour: 8)

        try store.upsertUsageSnapshots([
            UsageSnapshot(
                id: UUID(),
                accountID: account.id,
                providerID: .openAI,
                bucketStart: day,
                bucketEnd: day.addingTimeInterval(3_600),
                model: "gpt-5.4",
                inputTokens: 10,
                outputTokens: 20,
                requests: 1,
                quality: .exact
            ),
            UsageSnapshot(
                id: UUID(),
                accountID: account.id,
                providerID: .openAI,
                bucketStart: day.addingTimeInterval(11 * 3_600),
                bucketEnd: day.addingTimeInterval(12 * 3_600),
                model: "gpt-5.4-mini",
                inputTokens: 30,
                outputTokens: 40,
                requests: 2,
                quality: .exact
            ),
        ])
        try store.upsertEstimateSnapshots([
            EstimateSnapshot(
                id: UUID(),
                accountID: account.id,
                providerID: .openAI,
                bucketStart: day,
                bucketEnd: day.addingTimeInterval(3_600),
                estimatedAmountMicros: 110_000,
                currency: "USD",
                quality: .exact
            ),
            EstimateSnapshot(
                id: UUID(),
                accountID: account.id,
                providerID: .openAI,
                bucketStart: day.addingTimeInterval(11 * 3_600),
                bucketEnd: day.addingTimeInterval(12 * 3_600),
                estimatedAmountMicros: 220_000,
                currency: "USD",
                quality: .estimated
            ),
        ])

        let summaries = try store.fetchDailySummaries(accountID: account.id)

        XCTAssertEqual(
            summaries,
            [
                DailyUsageSummary(
                    dayStart: makeUTCDate(year: 2026, month: 7, day: 24, hour: 0),
                    inputTokens: 40,
                    outputTokens: 60,
                    requests: 3,
                    estimatedAmountMicros: 330_000,
                    currency: "USD",
                    quality: .estimated
                ),
            ]
        )
    }

    func testDailySummariesIncludeEstimateOnlyDaysAndSortNewestFirst() throws {
        let store = try makeStore()
        let account = makeAccount()
        let earlierDay = makeUTCDate(year: 2026, month: 7, day: 23, hour: 9)
        let laterDay = makeUTCDate(year: 2026, month: 7, day: 25, hour: 6)

        try store.upsertUsageSnapshots([
            UsageSnapshot(
                id: UUID(),
                accountID: account.id,
                providerID: .claude,
                bucketStart: earlierDay,
                bucketEnd: earlierDay.addingTimeInterval(3_600),
                model: nil,
                inputTokens: 8,
                outputTokens: 13,
                requests: 1,
                quality: .exact
            ),
        ])
        try store.upsertEstimateSnapshots([
            EstimateSnapshot(
                id: UUID(),
                accountID: account.id,
                providerID: .claude,
                bucketStart: laterDay,
                bucketEnd: laterDay.addingTimeInterval(3_600),
                estimatedAmountMicros: 95_000,
                currency: "USD",
                quality: .partial
            ),
        ])

        let summaries = try store.fetchDailySummaries(accountID: account.id)

        XCTAssertEqual(
            summaries,
            [
                DailyUsageSummary(
                    dayStart: makeUTCDate(year: 2026, month: 7, day: 25, hour: 0),
                    inputTokens: 0,
                    outputTokens: 0,
                    requests: 0,
                    estimatedAmountMicros: 95_000,
                    currency: "USD",
                    quality: .partial
                ),
                DailyUsageSummary(
                    dayStart: makeUTCDate(year: 2026, month: 7, day: 23, hour: 0),
                    inputTokens: 8,
                    outputTokens: 13,
                    requests: 1,
                    estimatedAmountMicros: nil,
                    currency: nil,
                    quality: .exact
                ),
            ]
        )
    }

    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private func makeAccount(providerID: ProviderID = .openAI) -> Account {
        Account(
            id: UUID(),
            providerID: providerID,
            displayName: "History Test",
            credentialReference: "keychain://glyphline/\(UUID().uuidString)",
            createdAt: makeUTCDate(year: 2026, month: 7, day: 20, hour: 0),
            isEnabled: true
        )
    }

    private func makeUTCDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
