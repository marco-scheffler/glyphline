import Foundation

struct PlaceholderAccountSummary: Identifiable {
    let account: Account
    let dataQuality: DataQuality
    let statusSummary: String
    let monthlyCostSummary: String
    let requestSummary: String
    let tokenSummary: String
    let billingSummary: String
    let lastSyncSummary: String
    let costSourceSummary: String

    var id: UUID { account.id }
}

struct PlaceholderHistoryEntry: Identifiable {
    let id: UUID
    let title: String
    let accountName: String
    let occurredAtSummary: String
    let detailSummary: String
    let dataQuality: DataQuality
}

struct PlaceholderProviderOption: Identifiable {
    let providerID: ProviderID
    let credentialLabel: String
    let qualitySummary: String
    let setupSummary: String

    var id: ProviderID { providerID }
}

enum PlaceholderContent {
    static let accounts: [PlaceholderAccountSummary] = [
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                providerID: .openAI,
                displayName: "OpenAI Production",
                credentialReference: "keychain://openai-prod",
                createdAt: Date(timeIntervalSince1970: 1_720_000_000),
                isEnabled: true
            ),
            dataQuality: .exact,
            statusSummary: "Synced 12 minutes ago",
            monthlyCostSummary: "$4.82",
            requestSummary: "842 requests",
            tokenSummary: "96k tokens",
            billingSummary: "Renews on August 13",
            lastSyncSummary: "Latest sync returned usage and reset date.",
            costSourceSummary: "Exact invoice data"
        ),
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                providerID: .claude,
                displayName: "Claude Research",
                credentialReference: "keychain://claude-research",
                createdAt: Date(timeIntervalSince1970: 1_721_000_000),
                isEnabled: true
            ),
            dataQuality: .estimated,
            statusSummary: "Synced 41 minutes ago",
            monthlyCostSummary: "$3.51",
            requestSummary: "517 requests",
            tokenSummary: "71k tokens",
            billingSummary: "Estimate based on pricing catalog.",
            lastSyncSummary: "Usage returned without provider-side invoice totals.",
            costSourceSummary: "Estimated from usage"
        ),
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                providerID: .cursor,
                displayName: "Cursor Team",
                credentialReference: "keychain://cursor-team",
                createdAt: Date(timeIntervalSince1970: 1_722_000_000),
                isEnabled: true
            ),
            dataQuality: .partial,
            statusSummary: "Synced 2 hours ago",
            monthlyCostSummary: "$0.00",
            requestSummary: "548 requests",
            tokenSummary: "Unavailable",
            billingSummary: "Provider reported request counts only.",
            lastSyncSummary: "Token totals missing for shared-workspace activity.",
            costSourceSummary: "Partial provider response"
        ),
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                providerID: .openAI,
                displayName: "Sandbox Account",
                credentialReference: "keychain://openai-sandbox",
                createdAt: Date(timeIntervalSince1970: 1_723_000_000),
                isEnabled: false
            ),
            dataQuality: .unavailable,
            statusSummary: "Needs reconnect",
            monthlyCostSummary: "--",
            requestSummary: "No recent sync",
            tokenSummary: "--",
            billingSummary: "Disabled until credentials are refreshed.",
            lastSyncSummary: "Last sync failed with an authentication error.",
            costSourceSummary: "No current provider data"
        )
    ]

    static let history: [PlaceholderHistoryEntry] = [
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            title: "Usage sync completed",
            accountName: "OpenAI Production",
            occurredAtSummary: "Today at 09:42",
            detailSummary: "Captured usage, cost estimate, and reset date.",
            dataQuality: .exact
        ),
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "Estimate recalculated",
            accountName: "Claude Research",
            occurredAtSummary: "Today at 09:13",
            detailSummary: "Pricing catalog filled in missing provider totals.",
            dataQuality: .estimated
        ),
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            title: "Partial sync saved",
            accountName: "Cursor Team",
            occurredAtSummary: "Today at 07:58",
            detailSummary: "Request counts updated without token-level breakdown.",
            dataQuality: .partial
        ),
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            title: "Credential check failed",
            accountName: "Sandbox Account",
            occurredAtSummary: "Yesterday at 18:21",
            detailSummary: "Stored secret was rejected by the provider.",
            dataQuality: .unavailable
        )
    ]

    static let providerOptions: [PlaceholderProviderOption] = [
        PlaceholderProviderOption(
            providerID: .openAI,
            credentialLabel: "API key",
            qualitySummary: "Usage, estimates, and reset date",
            setupSummary: "Best for exact or near-exact spend visibility."
        ),
        PlaceholderProviderOption(
            providerID: .claude,
            credentialLabel: "Console key",
            qualitySummary: "Usage with estimated spend",
            setupSummary: "Good for tracking requests and modeled cost."
        ),
        PlaceholderProviderOption(
            providerID: .cursor,
            credentialLabel: "Session token",
            qualitySummary: "Request totals with partial quality",
            setupSummary: "Useful when you mainly need activity monitoring."
        )
    ]

    static let qualityLegend: [DataQuality] = [
        .exact,
        .estimated,
        .partial,
        .unavailable
    ]

    static var enabledAccounts: Int {
        accounts.filter(\.account.isEnabled).count
    }

    static var monthlyEstimateSummary: String {
        "$8.33"
    }

    static var requestVolumeSummary: String {
        "1,907 requests"
    }
}
