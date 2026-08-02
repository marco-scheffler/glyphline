import Foundation

enum AccountSummaryFormatting {
    static func status(_ summary: AccountUsageSummary) -> String {
        if !summary.account.isEnabled {
            return String(localized: "Disabled", comment: "Account status: the account is switched off and nothing syncs it.")
        }

        guard let syncRun = summary.latestSyncRun else {
            return String(localized: "Not synced yet", comment: "Account status: no sync run has ever been recorded.")
        }

        switch syncRun.status {
        case .running:
            return String(localized: "Sync running", comment: "Account status: a sync run is in flight.")
        case .succeeded:
            guard let finishedAt = syncRun.finishedAt else {
                return String(localized: "Synced", comment: "Account status: the last sync succeeded but carries no finish time.")
            }

            // Numerals and dates elsewhere follow the system locale on purpose,
            // and this style renders WORDS — so it has to follow the language the
            // app's own words are being rendered in, not the system's. Those two
            // are the same on most Macs and deliberately are not on one whose
            // language is set to something this app does not carry: pairing a
            // German "vor 11 Minuten" with an English "Synced" would be worse
            // than either alone.
            let relative = finishedAt.formatted(
                .relative(presentation: .named).locale(AppLocalization.locale)
            )
            return String(
                localized: "Synced \(relative)",
                comment: "Account status. The placeholder is a worded relative time such as '11 minutes ago'."
            )
        case .failed:
            return syncRun.message
                ?? String(localized: "Sync failed", comment: "Account status: the last sync run failed without a message of its own.")
        }
    }
}
