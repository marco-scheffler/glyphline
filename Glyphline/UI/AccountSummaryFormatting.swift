import Foundation

enum AccountSummaryFormatting {
    static func status(_ summary: AccountUsageSummary) -> String {
        if !summary.account.isEnabled {
            return "Disabled"
        }

        guard let syncRun = summary.latestSyncRun else {
            return "Not synced yet"
        }

        switch syncRun.status {
        case .running:
            return "Sync running"
        case .succeeded:
            guard let finishedAt = syncRun.finishedAt else {
                return "Synced"
            }

            // Numerals and dates elsewhere follow the system locale on purpose, but
            // this style renders WORDS, and the app's own strings are English — the
            // system locale would produce "Synced vor 11 Minuten".
            return "Synced \(finishedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "en_US"))))"
        case .failed:
            return syncRun.message ?? "Sync failed"
        }
    }
}
