import SwiftUI

struct AccountsView: View {
    let accounts: [AccountUsageSummary]
    var ledgerStore: LedgerStore? = LedgerStore.makeDefault()
    var credentialStore: any CredentialStore = KeychainStore()
    var webSessions: any WebSessionRemoving = ClaudeWebSessionStore()
    var onDeleted: () -> Void = {}
    var onAdded: () -> Void = {}
    /// Reloads the list after a rename. The row renders from `accounts`, which
    /// the parent owns, so without this the new name is invisible until
    /// something else refetches.
    var onRenamed: () -> Void = {}

    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var isPresentingAddAccount = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionError: String?
    /// The account whose delete is in flight. Nothing else marks an account busy,
    /// so without this a second press starts a second deletion.
    @State private var deletingAccountID: UUID?
    /// The account whose name is being edited, and the text being typed. Nil
    /// means no editor is open.
    @State private var renamingAccount: Account?
    @State private var renameDraft = ""

    /// How much room the header claims above the list, beyond the row itself.
    /// Named so the probe test can subtract it rather than assume it.
    static let headerTopPadding: CGFloat = 20

    /// The gap between the header row and the first card — and, crucially, one
    /// that is applied to the header rather than to the scroll view's content.
    ///
    /// The list used to buy its breathing room with `.padding(.vertical, 16)` on
    /// the `LazyVStack` inside the `ScrollView`. That padding is part of the
    /// scrolled document: at any scroll offset above zero it has moved out of
    /// sight and the first visible card sits flush against the header, which is
    /// what read as the cards running underneath it. A gap that must survive
    /// scrolling has to live outside the scroll view.
    static let headerBottomPadding: CGFloat = 16

    /// Carries the counts alongside the account so the alert renders from the
    /// figures read when the button was pressed, not from a second query while
    /// the alert is already on screen.
    private struct PendingDeletion: Identifiable {
        let account: Account
        let summary: AccountDeletionSummary
        var id: UUID { account.id }
    }

    /// The list on its own, so the header above it and the sheets and alerts
    /// around it stay legible as separate pieces.
    @ViewBuilder private var list: some View {
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
                        // Computed once per render pass. Evaluated inside the
                        // ForEach it rebuilt the whole array once per card.
                        let quotaBars = coordinator.quotaBars

                        ForEach(accounts) { summary in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(summary.account.resolvedName)
                                            .font(.headline)
                                        Text(summary.account.providerID.displayName)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 12)

                                    Button {
                                        // Seeded with the current custom name, not
                                        // the resolved one: opening the editor must
                                        // not silently turn the derived name into a
                                        // chosen one on the next save.
                                        renameDraft = summary.account.customName ?? ""
                                        renamingAccount = summary.account
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Rename account")
                                    .help("Rename account")

                                    // Disabled only while this account's own delete
                                    // is in flight.
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
                                    .disabled(deletingAccountID == summary.account.id)
                                }

                                HStack(spacing: 16) {
                                    AccountMetric(
                                        title: "Status",
                                        value: AccountSummaryFormatting.status(summary)
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if let quota = quotaBars.first(where: { $0.id == summary.account.id }) {
                                    if let message = quota.message {
                                        // The reason, in place of the bars. More useful than an empty frame.
                                        Text(message)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    } else if quota.isSilent {
                                        // Never a heading over an empty frame. The
                                        // source answered and had no active window;
                                        // accounts with no source carry a message
                                        // and take the branch above.
                                        Text(QuotaIndicator.noQuotaReportedMessage)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(quota.rows) { row in
                                                QuotaBarRowView(row: row)
                                            }
                                        }
                                    }
                                }

                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 24)
                    // Bottom only. The gap above the first card is the header's
                    // now, so that it cannot scroll away; keeping it here too
                    // would double it while the list sits at the top.
                    .padding(.bottom, 16)
                }
            }
        }
    }

    /// The title and the one action the list has.
    ///
    /// A header row rather than a toolbar item. As a tab in the settings window
    /// this view has no toolbar to put anything in, so a toolbar item there
    /// renders nowhere at all — and the place it is indispensable is the empty
    /// state, where adding an account is the only thing to do.
    /// Not private, and deliberately without the gap below it: the probe test
    /// hosts this row on its own to measure how far the scroll view starts below
    /// it. Folding the gap in here would make that distance unmeasurable.
    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Accounts")
                .font(.title2.weight(.semibold))

            Spacer(minLength: 12)

            Button {
                isPresentingAddAccount = true
            } label: {
                Label("Add account", systemImage: "person.badge.plus")
            }
            .help("Add an account")
        }
        .padding(.horizontal, 24)
        .padding(.top, Self.headerTopPadding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Self.headerBottomPadding)
            list
        }
        .sheet(isPresented: $isPresentingAddAccount) {
            VStack(spacing: 0) {
                AddAccountView(
                    ledgerStore: ledgerStore,
                    credentialStore: credentialStore,
                    webSessions: webSessions,
                    onSave: accountSaved
                )
                Divider()
                HStack {
                    Spacer()
                    // The form has no way out of its own — as a destination it
                    // never needed one.
                    Button("Close") { isPresentingAddAccount = false }
                }
                .padding(16)
            }
            .frame(minWidth: 520, minHeight: 480)
        }
        .sheet(item: $renamingAccount) { account in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Account")
                    .font(.headline)
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                // Says what an empty field does, rather than leaving the user to
                // find out by clearing it.
                Text("Leave empty to use \(account.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { renamingAccount = nil }
                    Button("Save") { commitRename(accountID: account.id, name: renameDraft) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(minWidth: 360)
        }
        .alert(
            Text(pendingDeletion.map { AccountDeletionFormatting.title(displayName: $0.account.resolvedName) } ?? ""),
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

    /// A named method rather than an inline closure, so the reload after a save
    /// can be exercised without driving the sheet. The list is rendered from
    /// `accounts`, which the parent owns; without this the newly saved account
    /// stays invisible until something else reloads the ledger.
    func accountSaved() {
        isPresentingAddAccount = false
        onAdded()
    }

    /// Writes the new name and reloads. A named method rather than an inline
    /// closure so the write and the reload can be exercised without driving the
    /// sheet — the same reason `accountSaved()` exists.
    ///
    /// The editor closes either way: the only failure here is the ledger being
    /// unavailable, which is the same condition that already leaves the whole
    /// tab read-only, and leaving the sheet open with no explanation would be
    /// worse than closing it.
    func commitRename(accountID: UUID, name: String) {
        defer { renamingAccount = nil }
        guard let ledgerStore else { return }
        try? ledgerStore.renameAccount(accountID: accountID, to: name)
        onRenamed()
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
            // The coordinator owns delete-then-forget, so the in-memory state a
            // deleted account leaves behind is dropped where a test can see it.
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
