import SwiftUI

struct AccountsView: View {
    let accounts: [AccountUsageSummary]
    var ledgerStore: LedgerStore? = LedgerStore.makeDefault()
    var credentialStore: any CredentialStore = KeychainStore()
    var webSessions: any WebSessionRemoving = ClaudeWebSessionStore()
    var onSyncFinished: () -> Void = {}
    var onDeleted: () -> Void = {}

    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionError: String?
    /// The account whose delete is in flight. `activities` stays idle across the
    /// await, so without this a second press starts a second deletion.
    @State private var deletingAccountID: UUID?

    /// Carries the counts alongside the account so the alert renders from the
    /// figures read when the button was pressed, not from a second query while
    /// the alert is already on screen.
    private struct PendingDeletion: Identifiable {
        let account: Account
        let summary: AccountDeletionSummary
        var id: UUID { account.id }
    }

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

                                    // Disabled while a sync or backfill is running:
                                    // deleting mid-run races the very task
                                    // `deleteAccount` cancels.
                                    Button {
                                        guard let ledgerStore else { return }
                                        let counts = (try? ledgerStore.deletionSummary(
                                            accountID: summary.account.id
                                        )) ?? .empty
                                        pendingDeletion = PendingDeletion(
                                            account: summary.account,
                                            summary: counts
                                        )
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    // An image-only control has no accessible name
                                    // of its own, and `.help` is a tooltip rather
                                    // than a label. This is the only irreversible
                                    // action in the app; it may not be nameless.
                                    .accessibilityLabel("Delete account")
                                    .help("Delete account")
                                    .disabled(
                                        coordinator.activities[summary.account.id]?.isRunning == true
                                            || deletingAccountID == summary.account.id
                                    )
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
        .alert(
            Text(pendingDeletion.map { AccountDeletionFormatting.title(displayName: $0.account.displayName) } ?? ""),
            isPresented: isShowingPendingDeletion,
            presenting: pendingDeletion
        ) { pending in
            Button("Delete", role: .destructive) { delete(pending.account) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                AccountDeletionFormatting.body(
                    summary: pending.summary,
                    source: AccountCredentialReference.source(of: pending.account.credentialReference)
                )
            )
        }
        // On a distinct view, deliberately. The error alert is triggered by the
        // dismissal of the confirm alert — the user taps Delete, the confirm
        // alert tears down, the async flow then fails. Two alerts on the same
        // view means the second presentation is swallowed while the first is
        // still dismissing, and a failed deletion would be silent: the account
        // is still in the list with nothing said about why.
        .background {
            Color.clear
                .alert("Could not delete account", isPresented: isShowingDeletionError) {
                    Button("OK") { deletionError = nil }
                } message: {
                    Text(deletionError ?? "")
                }
        }
    }

    /// Real bindings rather than `.constant(…)`: SwiftUI writes `false` back when
    /// the alert dismisses, and a constant binding would leave the state set.
    private var isShowingPendingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var isShowingDeletionError: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    private func delete(_ account: Account) {
        guard let ledgerStore, deletingAccountID != account.id else { return }
        deletingAccountID = account.id
        let flow = DeleteAccountFlow(
            ledgerStore: ledgerStore,
            credentialStore: credentialStore,
            webSessions: webSessions
        )
        Task {
            // The coordinator owns the ordering — cancel, then delete, then forget.
            // Doing it here would put an ordering guarantee somewhere no test can
            // reach it, and this view got it wrong: it deleted first and cancelled
            // after, which is no guarantee at all.
            let outcome = await coordinator.deleteAccount(account, using: flow)
            deletingAccountID = nil
            switch outcome {
            case .deleted:
                onDeleted()
            case let .failed(message):
                deletionError = message
            }
        }
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
