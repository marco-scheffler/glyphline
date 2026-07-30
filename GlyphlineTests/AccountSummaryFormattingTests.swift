import XCTest
@testable import Glyphline

final class AccountSummaryFormattingTests: XCTestCase {
    private let account = Account(
        id: UUID(),
        providerID: .cursor,
        displayName: "Cursor",
        credentialReference: "keychain://glyphline/cursor",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        isEnabled: true
    )

    private func summary(lastSyncFinishedAt: Date) -> AccountUsageSummary {
        AccountUsageSummary(
            account: account,
            capabilities: nil,
            billingPeriod: nil,
            latestSyncRun: SyncRun(
                id: UUID(),
                accountID: account.id,
                providerID: .cursor,
                startedAt: lastSyncFinishedAt.addingTimeInterval(-5),
                finishedAt: lastSyncFinishedAt,
                status: .succeeded,
                message: nil
            ),
            inputTokens: 0,
            outputTokens: 0,
            requestCount: nil,
            actualAmountMicros: nil,
            estimatedAmountMicros: nil,
            displayCurrency: nil,
            dataQuality: .exact
        )
    }

    /// The app's strings are English, so a worded relative time must be English too
    /// — otherwise it renders "Synced vor 11 Minuten" on a German system. Numerals
    /// and dates deliberately keep the system locale; only WORDS follow the app.
    func testTheRelativeSyncTimeIsEnglish() {
        let now = Date()
        let summary = summary(lastSyncFinishedAt: now.addingTimeInterval(-11 * 60))
        let status = AccountSummaryFormatting.status(summary)

        XCTAssertTrue(status.contains("ago"), "expected an English relative time, got: \(status)")
        XCTAssertFalse(status.contains("vor "), "German relative time leaked in: \(status)")
    }
}
