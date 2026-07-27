import Foundation

enum AccountSummaryFormatting {
    static func money(_ micros: Int64?, currency: String?) -> String {
        guard let micros, let currency else {
            return "No cost yet"
        }

        let amount = Decimal(micros) / Decimal(1_000_000)
        return amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }

    static func requests(_ count: Int64) -> String {
        "\(count.formatted(.number)) requests"
    }

    static func tokens(input: Int64, output: Int64) -> String {
        let total = input + output
        return "\(total.formatted(.number)) tokens"
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

            return "Synced \(finishedAt.formatted(.relative(presentation: .named)))"
        case .failed:
            return syncRun.message ?? "Sync failed"
        }
    }

    static func billing(_ summary: AccountUsageSummary) -> String {
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
