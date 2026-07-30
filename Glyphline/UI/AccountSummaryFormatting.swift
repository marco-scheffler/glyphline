import Foundation

enum AccountSummaryFormatting {
    static func money(_ micros: Int64?, currency: String?) -> String {
        guard let micros, let currency else {
            return "No cost yet"
        }

        let amount = Decimal(micros) / Decimal(1_000_000)
        return amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }

    /// Nil means the provider does not expose a request count at all, which is
    /// shown as an em dash rather than a misleading zero.
    static func requests(_ count: Int64?) -> String {
        guard let count else {
            return "—"
        }

        return "\(count.formatted(.number)) requests"
    }

    static func tokens(_ total: Int64) -> String {
        "\(total.formatted(.number)) tokens"
    }

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

    static func billing(_ summary: AccountUsageSummary) -> String {
        // The capability flag decides, not the stored period. `upsertAccountSyncState`
        // COALESCEs the three billing columns so a backfill slice cannot NULL out the
        // real period, which means a period outlives the sync that reported it. A
        // provider that has stopped reporting a cycle — Cursor when its spend endpoint
        // fails — would otherwise keep rendering the last date it ever sent, right
        // beside a capability message saying there is no reset date.
        guard summary.capabilities?.supportsResetDate != false else {
            return "Reset date unavailable"
        }

        guard let billingPeriod = summary.billingPeriod else {
            return "Reset date unavailable"
        }

        if let resetAt = billingPeriod.resetAt {
            return "Resets \(resetAt.formatted(date: .abbreviated, time: .omitted))"
        }

        if let endsAt = billingPeriod.endsAt {
            return "Billing period ends \(endsAt.formatted(date: .abbreviated, time: .omitted))"
        }

        return "Billing period started \(billingPeriod.startsAt.formatted(date: .abbreviated, time: .omitted))"
    }

    static func costSource(_ summary: AccountUsageSummary) -> String {
        if summary.usesActualCost {
            return "Provider-reported API cost"
        }

        if summary.estimatedAmountMicros != nil {
            return "Estimated API-equivalent cost"
        }

        return summary.capabilities?.message ?? "No usage data synced"
    }
}
