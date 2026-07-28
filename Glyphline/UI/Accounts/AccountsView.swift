import SwiftUI

struct AccountsView: View {
    let accounts: [AccountUsageSummary]
    var onSyncFinished: () -> Void = {}

    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        Group {
            if accounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts Yet",
                    systemImage: "person.badge.plus",
                    description: Text("Add an account to store credentials securely and start tracking usage.")
                )
            } else {
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

                                    // Phase one first, so the dashboard is usable within
                                    // seconds; phase two then walks back a year.
                                    Button("Sync Now") {
                                        Task {
                                            await coordinator.syncNow(account: summary.account)
                                            onSyncFinished()
                                            await coordinator.backfill(account: summary.account)
                                            onSyncFinished()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(coordinator.activities[summary.account.id]?.isRunning == true)
                                }

                                HStack(spacing: 16) {
                                    AccountMetric(
                                        title: "Status",
                                        value: AccountSummaryFormatting.status(summary)
                                    )
                                    AccountMetric(
                                        title: "Cost",
                                        value: AccountSummaryFormatting.money(
                                            summary.displayAmountMicros,
                                            currency: summary.displayCurrency
                                        )
                                    )
                                    AccountMetric(
                                        title: "Requests",
                                        value: AccountSummaryFormatting.requests(summary.requestCount)
                                    )
                                    AccountMetric(
                                        title: "Tokens",
                                        value: AccountSummaryFormatting.tokens(summary.totalTokens)
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if let activity = coordinator.activities[summary.account.id] {
                                    switch activity {
                                    case .idle:
                                        EmptyView()
                                    case let .running(phase):
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text(phase).font(.caption).foregroundStyle(.secondary)
                                        }
                                    case let .failed(message):
                                        Text(message).font(.caption).foregroundStyle(.red)
                                    }
                                }

                                if coordinator.activities[summary.account.id]?.isRunning == true {
                                    Button("Cancel") {
                                        coordinator.cancelBackfill(account: summary.account)
                                    }
                                    .buttonStyle(.link)
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(AccountSummaryFormatting.billing(summary))
                                    Text(AccountSummaryFormatting.costSource(summary))
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
            }
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
