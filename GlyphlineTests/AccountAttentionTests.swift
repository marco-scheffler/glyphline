import XCTest

@testable import Glyphline

/// The dashboard's failure state.
///
/// Accounts is a settings tab now, so the reason to go there — an expired
/// sign-in, a rejected token, a failing sync — has to reach the dashboard on its
/// own. Which conditions count is the part that can be quietly wrong: too few
/// and the banner never appears for the case it exists for, too many and it sits
/// there permanently over "quota reporting is not available for this
/// subscription", which is true of every account today.
final class AccountAttentionTests: XCTestCase {
    private func account(_ name: String, isEnabled: Bool = true) -> Account {
        Account(
            id: UUID(),
            providerID: .claude,
            displayName: name,
            credentialReference: "keychain://glyphline/\(name)",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEnabled: isEnabled
        )
    }

    private func summary(
        _ account: Account,
        syncStatus: SyncRun.Status? = nil,
        syncMessage: String? = nil
    ) -> AccountUsageSummary {
        AccountUsageSummary(
            account: account,
            capabilities: nil,
            billingPeriod: nil,
            latestSyncRun: syncStatus.map { status in
                SyncRun(
                    id: UUID(),
                    accountID: account.id,
                    providerID: account.providerID,
                    startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    finishedAt: Date(timeIntervalSince1970: 1_800_000_060),
                    status: status,
                    message: syncMessage
                )
            },
            inputTokens: 0,
            outputTokens: 0,
            requestCount: nil,
            actualAmountMicros: nil,
            estimatedAmountMicros: nil,
            displayCurrency: nil,
            dataQuality: .exact
        )
    }

    private func group(_ account: Account, message: String?) -> QuotaBarGroup {
        QuotaBarGroup(id: account.id, displayName: account.displayName, message: message, rows: [])
    }

    /// The two cases the user can act on, named with the provider's own words.
    func testAnExpiredSignInAndARejectedTokenBothAskForAttention() {
        let expired = account("Expired")
        let rejected = account("Rejected")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(expired), summary(rejected)],
            quotaGroups: [
                group(expired, message: RateWindowSourceError.sessionExpired.message),
                group(rejected, message: RateWindowSourceError.credentialRejected(statusCode: 403).message),
            ]
        )

        XCTAssertEqual(attention.map(\.accountName), ["Expired", "Rejected"])
        XCTAssertEqual(attention.first?.reason, RateWindowSourceError.sessionExpired.message)
        XCTAssertEqual(
            attention.last?.reason,
            RateWindowSourceError.credentialRejected(statusCode: 403).message
        )
    }

    /// No account resolves to a quota source today, so every one of them carries
    /// `notAvailable`. A banner that fired on it would be permanent, which is how
    /// a warning becomes wallpaper.
    func testTheReasonsNobodyCanActOnDoNotAskForAttention() {
        let quiet = account("Quiet")

        for message in [
            RateWindowSourceError.notAvailable.message,
            RateWindowSourceError.notConfigured.message,
            RateWindowSourceError.transportFailure.message,
            RateWindowSourceError.unreadablePage.message,
            RateWindowSourceError.unexpectedResponseShape.message,
            QuotaIndicator.noQuotaReportedMessage,
        ] {
            XCTAssertEqual(
                DashboardPresentation.accountsNeedingAttention(
                    summaries: [summary(quiet)],
                    quotaGroups: [group(quiet, message: message)]
                ).count,
                0,
                "\(message) is not something the user is being asked to fix"
            )
        }
    }

    /// A failed sync run is the other way an account is broken, and it is the one
    /// the quota path knows nothing about.
    func testAFailedSyncRunAsksForAttentionWithItsOwnMessage() {
        let failing = account("Failing")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(failing, syncStatus: .failed, syncMessage: "Ledger write refused.")],
            quotaGroups: [group(failing, message: nil)]
        )

        XCTAssertEqual(attention.map(\.reason), ["Ledger write refused."])
    }

    /// A run that failed without saying why still has to say something.
    func testASilentFailedRunFallsBackToTheAppsOwnWords() {
        let failing = account("Failing")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(failing, syncStatus: .failed)],
            quotaGroups: []
        )

        XCTAssertEqual(attention.map(\.reason), [DashboardPresentation.syncFailedReason])
    }

    /// A healthy account is not in the banner, whichever way it is healthy.
    func testSucceededAndRunningAccountsAreLeftAlone() {
        let fine = account("Fine")

        XCTAssertTrue(
            DashboardPresentation.accountsNeedingAttention(
                summaries: [
                    summary(fine, syncStatus: .succeeded),
                    summary(fine, syncStatus: .running),
                    summary(fine),
                ],
                quotaGroups: [group(fine, message: nil)]
            ).isEmpty
        )
    }

    /// The expired sign-in is *why* the run failed. Naming the symptom over the
    /// cause would send the user looking in the wrong place.
    func testTheQuotaReasonWinsOverTheFailedRunForTheSameAccount() {
        let broken = account("Broken")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(broken, syncStatus: .failed, syncMessage: "Sync failed.")],
            quotaGroups: [group(broken, message: RateWindowSourceError.sessionExpired.message)]
        )

        XCTAssertEqual(attention.map(\.reason), [RateWindowSourceError.sessionExpired.message])
    }

    /// Nothing is syncing a disabled account, so an old failure on one is not a
    /// task the user has been left with.
    func testADisabledAccountIsNotAnOutstandingTask() {
        let off = account("Off", isEnabled: false)

        XCTAssertTrue(
            DashboardPresentation.accountsNeedingAttention(
                summaries: [summary(off, syncStatus: .failed, syncMessage: "Sync failed.")],
                quotaGroups: [group(off, message: RateWindowSourceError.sessionExpired.message)]
            ).isEmpty
        )
    }

    /// The headline is a count, and one account is not "1 accounts".
    func testTheHeadlineCountsAndAgrees() {
        XCTAssertEqual(DashboardPresentation.attentionHeadline(count: 1), "1 account needs attention")
        XCTAssertEqual(DashboardPresentation.attentionHeadline(count: 3), "3 accounts need attention")
    }
}
