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
                displayName: "Sample Workspace Alpha",
                credentialReference: "demo-reference-openai-alpha",
                createdAt: Date(timeIntervalSince1970: 1_704_067_200),
                isEnabled: true
            ),
            dataQuality: .exact,
            statusSummary: "Demo fixture: provider-reported sample",
            monthlyCostSummary: "$4.82",
            requestSummary: "842 sample requests",
            tokenSummary: "96k sample tokens",
            billingSummary: "Example billing window: Aug 1-Aug 31",
            lastSyncSummary: "Demo timeline entry for a provider-reported sample.",
            costSourceSummary: "Sample provider-reported total"
        ),
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                providerID: .claude,
                displayName: "Sample Workspace Beta",
                credentialReference: "demo-reference-claude-beta",
                createdAt: Date(timeIntervalSince1970: 1_706_745_600),
                isEnabled: true
            ),
            dataQuality: .estimated,
            statusSummary: "Demo fixture: estimated sample",
            monthlyCostSummary: "$3.51",
            requestSummary: "517 sample requests",
            tokenSummary: "71k sample tokens",
            billingSummary: "Example total derived from a sample price sheet",
            lastSyncSummary: "Demo timeline entry showing an estimated sample calculation.",
            costSourceSummary: "Sample estimated total"
        ),
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                providerID: .cursor,
                displayName: "Sample Workspace Gamma",
                credentialReference: "demo-reference-cursor-gamma",
                createdAt: Date(timeIntervalSince1970: 1_709_164_800),
                isEnabled: true
            ),
            dataQuality: .partial,
            statusSummary: "Demo fixture: partial sample",
            monthlyCostSummary: "$0.00",
            requestSummary: "548 sample requests",
            tokenSummary: "Token detail omitted in sample",
            billingSummary: "Example row with partial fields only",
            lastSyncSummary: "Demo timeline entry with intentionally missing detail.",
            costSourceSummary: "Sample partial total"
        ),
        PlaceholderAccountSummary(
            account: Account(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                providerID: .openAI,
                displayName: "Sample Workspace Delta",
                credentialReference: "demo-reference-openai-delta",
                createdAt: Date(timeIntervalSince1970: 1_711_843_200),
                isEnabled: false
            ),
            dataQuality: .unavailable,
            statusSummary: "Demo fixture: unavailable sample",
            monthlyCostSummary: "--",
            requestSummary: "No sample requests loaded",
            tokenSummary: "No sample tokens loaded",
            billingSummary: "Example empty state for unavailable data",
            lastSyncSummary: "Demo timeline entry for missing usage values.",
            costSourceSummary: "Sample unavailable total"
        )
    ]

    static let history: [PlaceholderHistoryEntry] = [
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            title: "Sample provider snapshot loaded",
            accountName: "Sample Workspace Alpha",
            occurredAtSummary: "Example event A",
            detailSummary: "Loaded a demo fixture with provider-reported values.",
            dataQuality: .exact
        ),
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "Sample estimate recalculated",
            accountName: "Sample Workspace Beta",
            occurredAtSummary: "Example event B",
            detailSummary: "Recomputed a demo estimate from placeholder pricing.",
            dataQuality: .estimated
        ),
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            title: "Sample partial data saved",
            accountName: "Sample Workspace Gamma",
            occurredAtSummary: "Example event C",
            detailSummary: "Stored a demo row with only request counts filled in.",
            dataQuality: .partial
        ),
        PlaceholderHistoryEntry(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            title: "Sample unavailable state shown",
            accountName: "Sample Workspace Delta",
            occurredAtSummary: "Example event D",
            detailSummary: "Presented a demo unavailable state without any live credential check.",
            dataQuality: .unavailable
        )
    ]

    static let providerOptions: [PlaceholderProviderOption] = [
        PlaceholderProviderOption(
            providerID: .openAI,
            credentialLabel: "Sample credential",
            qualitySummary: "Demo UI: provider-reported or estimated samples",
            setupSummary: "Example provider option for previewing the add-account form."
        ),
        PlaceholderProviderOption(
            providerID: .claude,
            credentialLabel: "Sample credential",
            qualitySummary: "Demo UI: estimated usage samples",
            setupSummary: "Example provider option for previewing placeholder setup copy."
        ),
        PlaceholderProviderOption(
            providerID: .cursor,
            credentialLabel: "Sample credential",
            qualitySummary: "Demo UI: partial usage samples",
            setupSummary: "Example provider option for previewing partial-data states."
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
        "1,907 sample requests"
    }
}
