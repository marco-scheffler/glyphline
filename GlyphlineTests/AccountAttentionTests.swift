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

    /// A quota group as the coordinator builds one: a failure carries both its
    /// code and its message, and a non-failure carries neither.
    private func group(
        _ account: Account,
        failure: RateWindowSourceError?
    ) -> QuotaBarGroup {
        QuotaBarGroup(
            id: account.id,
            displayName: account.displayName,
            message: failure?.message,
            failureCode: failure?.code,
            rows: []
        )
    }

    /// A group whose message is not one of the app's failures — the panel's own
    /// "No quota reported yet.", say. No code, so nothing to act on.
    private func codelessGroup(_ account: Account, message: String?) -> QuotaBarGroup {
        QuotaBarGroup(id: account.id, displayName: account.displayName, message: message, rows: [])
    }

    /// The two cases the user can act on, named with the provider's own words.
    func testAnExpiredSignInAndARejectedTokenBothAskForAttention() {
        let expired = account("Expired")
        let rejected = account("Rejected")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(expired), summary(rejected)],
            quotaGroups: [
                group(expired, failure: .sessionExpired),
                group(rejected, failure: .credentialRejected(statusCode: 403)),
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

        for failure: RateWindowSourceError in [
            .notAvailable,
            .notConfigured,
            .transportFailure,
            .unreadablePage,
            .unexpectedResponseShape,
        ] {
            XCTAssertEqual(
                DashboardPresentation.accountsNeedingAttention(
                    summaries: [summary(quiet)],
                    quotaGroups: [group(quiet, failure: failure)]
                ).count,
                0,
                "\(failure.code) is not something the user is being asked to fix"
            )
        }

        // A message that is not a failure at all reaches the same place.
        XCTAssertEqual(
            DashboardPresentation.accountsNeedingAttention(
                summaries: [summary(quiet)],
                quotaGroups: [codelessGroup(quiet, message: QuotaIndicator.noQuotaReportedMessage)]
            ).count,
            0
        )
    }

    /// A failed sync run is the other way an account is broken, and it is the one
    /// the quota path knows nothing about.
    func testAFailedSyncRunAsksForAttentionWithItsOwnMessage() {
        let failing = account("Failing")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(failing, syncStatus: .failed, syncMessage: "Ledger write refused.")],
            quotaGroups: [group(failing, failure: nil)]
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
                quotaGroups: [group(fine, failure: nil)]
            ).isEmpty
        )
    }

    /// The expired sign-in is *why* the run failed. Naming the symptom over the
    /// cause would send the user looking in the wrong place.
    func testTheQuotaReasonWinsOverTheFailedRunForTheSameAccount() {
        let broken = account("Broken")

        let attention = DashboardPresentation.accountsNeedingAttention(
            summaries: [summary(broken, syncStatus: .failed, syncMessage: "Sync failed.")],
            quotaGroups: [group(broken, failure: .sessionExpired)]
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
                quotaGroups: [group(off, failure: .sessionExpired)]
            ).isEmpty
        )
    }

    /// The banner is keyed on identity, not on wording.
    ///
    /// Localising the reason changes every one of these strings. If the
    /// membership test read the message, this is where the banner would go
    /// silent in every language but English — so the assertion is run against a
    /// message that is deliberately not the app's own.
    func testTranslatingTheReasonDoesNotChangeWhoNeedsAttention() {
        for failure: RateWindowSourceError in [.sessionExpired, .credentialRejected(statusCode: 401)] {
            let broken = account("Broken")
            let translated = "Deine Claude-Anmeldung ist abgelaufen."
            let attention = DashboardPresentation.accountsNeedingAttention(
                summaries: [summary(broken)],
                quotaGroups: [
                    QuotaBarGroup(
                        id: broken.id,
                        displayName: broken.displayName,
                        message: translated,
                        failureCode: failure.code,
                        rows: []
                    ),
                ]
            )

            XCTAssertEqual(
                attention.map(\.reason),
                [translated],
                "\(failure.code) must reach the banner whatever language its message is in"
            )
        }
    }

    /// Every failure the app can produce is classified one way or the other, and
    /// exactly the two actionable ones reach the banner. A case added later
    /// without a decision about it fails here rather than defaulting silently.
    func testEveryFailureCodeIsClassifiedAndOnlyTwoAreActionable() {
        let errors: [RateWindowSourceError] = [
            .notConfigured,
            .notAvailable,
            .credentialRejected(statusCode: 403),
            .transportFailure,
            .unreadablePage,
            .unexpectedResponseShape,
            .sessionExpired,
        ]

        XCTAssertEqual(Set(errors.map(\.code)), Set(RateWindowFailureCode.allCases))

        for error in errors {
            let one = account("One")
            let asked = !DashboardPresentation.accountsNeedingAttention(
                summaries: [summary(one)],
                quotaGroups: [group(one, failure: error)]
            ).isEmpty

            XCTAssertEqual(
                asked,
                error.code.isUserActionable,
                "\(error.code) reaches the banner exactly when it is actionable"
            )
        }

        XCTAssertEqual(RateWindowFailureCode.userActionable, [.sessionExpired, .credentialRejected])
    }

    /// The status code is not part of the identity: 401 and 403 mean the same
    /// thing to the user, and both have to reach the banner.
    func testEveryRejectionStatusCodeReachesTheBanner() {
        for status in [401, 403] {
            let rejected = account("Rejected")
            XCTAssertEqual(
                DashboardPresentation.accountsNeedingAttention(
                    summaries: [summary(rejected)],
                    quotaGroups: [group(rejected, failure: .credentialRejected(statusCode: status))]
                ).count,
                1,
                "\(status) is a rejected credential"
            )
        }
    }

    /// The headline is a count, and one account is not "1 accounts".
    func testTheHeadlineCountsAndAgrees() {
        XCTAssertEqual(DashboardPresentation.attentionHeadline(count: 1), "1 account needs attention")
        XCTAssertEqual(DashboardPresentation.attentionHeadline(count: 3), "3 accounts need attention")
    }
}
