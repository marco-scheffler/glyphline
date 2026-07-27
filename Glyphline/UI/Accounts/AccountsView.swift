import SwiftUI

struct AccountsView: View {
    let accounts: [PlaceholderAccountSummary]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Accounts")
                    .font(.title2.weight(.semibold))

                ForEach(accounts) { summary in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.account.displayName)
                                    .font(.headline)

                                Text(summary.account.providerID.displayName)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)
                            DataQualityBadge(quality: summary.dataQuality)
                        }

                        HStack(spacing: 16) {
                            AccountMetric(title: "Status", value: summary.statusSummary)
                            AccountMetric(title: "Monthly", value: summary.monthlyCostSummary)
                            AccountMetric(title: "Requests", value: summary.requestSummary)
                            AccountMetric(title: "Tokens", value: summary.tokenSummary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.billingSummary)
                            Text(summary.lastSyncSummary)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
        }
        .navigationTitle("Accounts")
    }
}

private struct AccountMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
    }
}
