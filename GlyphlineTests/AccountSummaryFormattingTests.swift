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

    private let period = BillingPeriod(
        startsAt: Date(timeIntervalSince1970: 1_798_761_600),
        endsAt: nil,
        resetAt: Date(timeIntervalSince1970: 1_801_440_000)
    )

    private func summary(
        capabilities: ProviderCapabilities?,
        billingPeriod: BillingPeriod?
    ) -> AccountUsageSummary {
        AccountUsageSummary(
            account: account,
            capabilities: capabilities,
            billingPeriod: billingPeriod,
            latestSyncRun: nil,
            inputTokens: 0,
            outputTokens: 0,
            requestCount: nil,
            actualAmountMicros: nil,
            estimatedAmountMicros: nil,
            displayCurrency: nil,
            dataQuality: .exact
        )
    }

    private func capabilities(supportsResetDate: Bool, message: String? = nil) -> ProviderCapabilities {
        ProviderCapabilities(
            supportsUsage: true,
            supportsActualCost: true,
            supportsResetDate: supportsResetDate,
            supportsModelBreakdown: true,
            dataQuality: .exact,
            message: message
        )
    }

    func testAReportedResetDateIsShown() {
        let rendered = AccountSummaryFormatting.billing(
            summary(capabilities: capabilities(supportsResetDate: true), billingPeriod: period)
        )

        XCTAssertTrue(rendered.hasPrefix("Resets "), "got \(rendered)")
    }

    /// The defect: `upsertAccountSyncState` COALESCEs the billing columns, so a
    /// stored period outlives the sync that reported it. Only the capability flag
    /// says whether it is still current, so the flag must be what the UI reads.
    func testAStoredPeriodIsNotShownOnceTheProviderStopsReportingOne() {
        let rendered = AccountSummaryFormatting.billing(
            summary(
                capabilities: capabilities(
                    supportsResetDate: false,
                    message: "Usage and cost are exact. Cursor did not return a billing cycle start, so there is no reset date."
                ),
                billingPeriod: period
            )
        )

        XCTAssertEqual(
            rendered,
            "Reset date unavailable",
            "a preserved period must not be rendered as the current reset date"
        )
    }

    func testANeverSyncedAccountSaysTheResetDateIsUnavailable() {
        XCTAssertEqual(
            AccountSummaryFormatting.billing(summary(capabilities: nil, billingPeriod: nil)),
            "Reset date unavailable"
        )
    }
}

/// The same defect asserted through the ledger rather than through a hand-built
/// summary, because a hand-built summary is exactly what would let it back in:
/// only a real round trip shows the COALESCE preserving the period.
final class StaleBillingPeriodLedgerTests: XCTestCase {
    func testCursorsDegradedSyncStopsRenderingTheOldResetDate() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let ledger = LedgerStore(dbQueue: dbQueue)

        let account = Account(
            id: UUID(),
            providerID: .cursor,
            displayName: "Cursor",
            credentialReference: "keychain://glyphline/cursor",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: true
        )
        try ledger.saveAccount(account)

        let period = BillingPeriod(
            startsAt: Date(timeIntervalSince1970: 1_798_761_600),
            endsAt: nil,
            resetAt: Date(timeIntervalSince1970: 1_801_440_000)
        )

        func result(billingPeriod: BillingPeriod?) -> ProviderSyncResult {
            ProviderSyncResult(
                providerID: .cursor,
                accountID: account.id,
                capabilities: ProviderCapabilities(
                    supportsUsage: true,
                    supportsActualCost: true,
                    supportsResetDate: billingPeriod != nil,
                    supportsModelBreakdown: true,
                    dataQuality: .exact,
                    message: billingPeriod == nil
                        ? "Usage and cost are exact. Cursor did not return a billing cycle start, so there is no reset date."
                        : nil
                ),
                billingPeriod: billingPeriod,
                usageSnapshots: [],
                costSnapshots: [],
                estimateSnapshots: [],
                syncedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }

        func persist(_ result: ProviderSyncResult, at finishedAt: Date) throws {
            let runID = try ledger.startSyncRun(
                accountID: account.id,
                providerID: .cursor,
                startedAt: finishedAt
            )
            try ledger.applySuccessfulSyncResult(result, syncRunID: runID, finishedAt: finishedAt)
        }

        try persist(result(billingPeriod: period), at: Date(timeIntervalSince1970: 1_800_000_000))
        // The spend endpoint fails: usage survives, the cycle start does not.
        try persist(result(billingPeriod: nil), at: Date(timeIntervalSince1970: 1_800_000_060))

        let summary = try XCTUnwrap(
            try ledger.fetchAccountSummaries().first { $0.account.id == account.id }
        )

        XCTAssertEqual(
            summary.billingPeriod,
            period,
            "the COALESCE deliberately keeps the period; that is the setup, not the bug"
        )
        XCTAssertEqual(
            AccountSummaryFormatting.billing(summary),
            "Reset date unavailable",
            "the UI must not contradict the capability message on the same screen"
        )
    }
}
